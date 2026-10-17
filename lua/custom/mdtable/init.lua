-- custom.mdtable: in-place editable, wrapped Markdown pipe-table renderer.
--
-- Pipeline per render(win): visible range -> scan.tables (cached rows) ->
-- per table layout.cached -> project (anchors, cursor row / covered header,
-- virtual blocks) -> draw.apply (diff against the drawn marks). See
-- project.lua for the rendering model and the anchor rule, draw.lua for the
-- diff strategy.
--
-- Events render synchronously inside the autocmd callback (CursorMoved/I,
-- TextChanged/I, InsertLeave, BufWinEnter, WinResized), so the marks are in
-- place before Neovim redraws: no stale frame, one redraw per key.
-- WinScrolled renders only when the view left the scanned range, or re-clips
-- (draw only) when a table is taller than the window.
-- Viewport clipping: no virt_lines block is taller than the window minus 2
-- (with more filler than the window is tall, Neovim moves a cursor that
-- targets a concealed table line off it, for every motion: :N, 8j, <C-d>,
-- }, marks, ...). A clipped block keeps the rows nearest the anchor and ends
-- in a `… N more rows …` marker (project.clip); a block below the anchor
-- stops at the window bottom so the marker is on screen.
-- Sticky header (header.lua): while the cursor is in a body row and the
-- table's header is scrolled off, a float pinned at the window top shows it.
-- The float and scroll-to-fit follow one viewport plan (plan()), evaluated
-- the same way on every render path.
-- Assumes 'wrap' on, 'linebreak', 'showbreak' and 'breakindent' off,
-- conceallevel=3 and concealcursor=nvic (render-markdown win_options).
local api, uv = vim.api, vim.uv or vim.loop
local scan = require("custom.mdtable.scan")
local layout = require("custom.mdtable.layout")
local project = require("custom.mdtable.project")
local draw = require("custom.mdtable.draw")
local header = require("custom.mdtable.header")

local M = {}
draw.on_namespace(scan.ignore_ns)

local state = {} -- buf -> { wins = { [win] = wstate } }
local enabled = true
local rendering = false
local warned, err_shown = false, {}
local stats = { n = 0, last = 0, max = 0, times = {}, marks = nil, tables = 0, hits = 0, misses = 0, parse = 0 }
M.stats = stats

local function set_hl()
  local function pick(name, fallback)
    return vim.fn.hlexists(name) == 1 and name or fallback
  end
  api.nvim_set_hl(0, "MdTableHead", { link = pick("RenderMarkdownTableHead", "@markup.heading"), default = true })
  api.nvim_set_hl(0, "MdTableRow", { link = pick("RenderMarkdownTableRow", "Normal"), default = true })
  api.nvim_set_hl(0, "MdTableFill", { link = pick("RenderMarkdownTableFill", "Normal"), default = true })
  api.nvim_set_hl(0, "MdTableMore", { link = "Comment", default = true })
end

local function seps_for(buf)
  local s = vim.b[buf].mdtable_row_separators
  if s == nil then s = vim.g.mdtable_row_separators ~= false end
  return s and true or false
end

local function check_options(win)
  if warned then return end
  warned = true
  local cl, cc = vim.wo[win].conceallevel, vim.wo[win].concealcursor
  if cl ~= 3 or not (cc:find("n") and cc:find("i")) then
    vim.notify(("mdtable: expects conceallevel=3 concealcursor=nvic (render-markdown win_options), got %d/%q"):format(cl, cc), vim.log.levels.WARN)
  end
end

local th = api.nvim_win_text_height

-- Number of virt_text marks of other plugins in rows [lo, hi): inline icons
-- (render-markdown link icons) arrive after our render without a text
-- change, and the scan models them, so a change forces a rescan.
local function foreign_sig(buf, lo, hi)
  local n = 0
  for name, id in pairs(api.nvim_get_namespaces()) do
    if name:sub(1, 8) ~= "mdtable." then
      n = n + #api.nvim_buf_get_extmarks(buf, id, { lo, 0 }, { math.max(hi - 1, lo), -1 }, { type = "virt_text" })
    end
  end
  return n
end

-- Keep the view steady when a table's anchor moves while the window top is
-- that anchor line (the old anchor becomes a concealed line): keep the same
-- offset into the table's grid.
local function reanchor(win, ws, moved, view)
  if not moved then return false end
  local top = view.topline - 1
  local m = moved[top]
  if not m then return false end
  local p = m.old_above - view.topfill
  local f = math.max(0, math.min(m.new_above, m.new_above - p))
  api.nvim_win_call(win, function() vim.fn.winrestview({ topline = m.new + 1, topfill = f, skipcol = 0 }) end)
  return true
end

-- Scroll-to-fit from the model: if the cursor row's grid is clipped at the
-- window bottom, the view scrolled by the minimum (hide filler above topline
-- first, then whole lines), or nil when the grid is fully visible. reserve:
-- rows at the window top taken by the sticky header float (the grid's top
-- stays below), from the viewport plan. Pure: plan() applies the view.
local function fit(win, crow, cr, h, view, reserve)
  local top, tf = view.topline - 1, view.topfill
  if crow < top then return nil end
  local pre
  if crow == top then
    pre = tf
  else
    pre = tf + th(win, { start_row = top, end_row = crow - 1, start_vcol = 0 }).all
      + th(win, { start_row = crow, end_row = crow }).fill
  end
  local grid_top = pre - cr.sep_above
  local bottom = grid_top + cr.height
  local d = math.min(bottom - h, grid_top - (reserve or 0))
  M.last_fit = { top = top, topfill = tf, pre = pre, height = cr.height, h = h, d = d }
  if d <= 0 then return nil end
  local ntop, nfill
  if d <= tf then
    ntop, nfill = top, tf - d
  else
    local need = d - tf
    if crow == top then return nil end
    local r = th(win, { start_row = top, end_row = crow - 1, start_vcol = 0, max_height = need })
    local e = r.end_row
    if r.all < need then e = crow end
    local before = e > top and th(win, { start_row = top, end_row = e - 1, start_vcol = 0 }).all or 0
    local fe = e > top and th(win, { start_row = e, end_row = e }).fill or 0
    if e > top and before + fe >= need then
      ntop, nfill = e, fe - (need - before)
    elseif e < crow then
      ntop = e + 1
      local hid = before + fe + th(win, { start_row = e, end_row = e, start_vcol = 0 }).all
      local fn = th(win, { start_row = ntop, end_row = ntop }).fill
      nfill = math.max(0, math.min(fn, fn - (need - hid)))
    else
      ntop, nfill = crow, math.max(0, math.min(th(win, { start_row = crow, end_row = crow }).fill, cr.sep_above))
    end
  end
  M.last_fit.new = { ntop, nfill }
  return { topline = ntop + 1, topfill = nfill }
end

-- Viewport plan: the one rule for the sticky header float and scroll-to-fit,
-- evaluated the same way on every render path (pre-render of a jump, cursor
-- move, the early return after a pre-render, scroll re-clip, WinScrolled).
-- show_header and float_height come from header.rule, independent of the
-- view: the float shows only when the cursor row's grid fits in the window
-- below it. With scroll (render paths that may move the view), the target
-- view is scroll-to-fit with float_height rows reserved (once per row and
-- cell: ws.fitted), then the float's seat (header.scroll_view). A cursor
-- line above the view (a jump up; the render undid Neovim's scroll) starts
-- from the view with that line at the top and its whole above block shown,
-- so Neovim does not scroll again after the render. Without scroll the
-- target is the current view. Returns { show_header, float_height,
-- topline, topfill }.
local function plan(win, ws, h, view, scroll)
  local ctx, f = ws.hctx, ws.fit
  local p = ctx and header.rule(win, api.nvim_win_get_buf(win), ctx, f and f.cr, h)
    or { show_header = false, float_height = 0 }
  local v = view
  if scroll then
    local A = ws.crow
    if (ctx or f) and A and A < v.topline - 1 then
      v = { topline = A + 1, topfill = th(win, { start_row = A, end_row = A }).fill }
    end
    if f and ws.fitted ~= f.key then v = fit(win, f.crow, f.cr, h, v, p.float_height) or v end
    if p.show_header then v = header.scroll_view(win, ctx, h, v) end
  end
  p.topline, p.topfill = v.topline, v.topfill
  return p
end

-- Apply the plan: move the view to its target (scroll) and show or hide the
-- float for the resulting view. Returns the view.
local function settle(win, ws, h, view, scroll)
  view = view or api.nvim_win_call(win, vim.fn.winsaveview)
  local p = plan(win, ws, h, view, scroll)
  if scroll and ws.fit then ws.fitted = ws.fit.key end
  if p.topline ~= view.topline or p.topfill ~= view.topfill then
    api.nvim_win_call(win, function() vim.fn.winrestview({ topline = p.topline, topfill = p.topfill, skipcol = 0 }) end)
    view = api.nvim_win_call(win, vim.fn.winsaveview)
  end
  ws.plan = p
  header.sync(win, ws.hctx, h, view, p)
  return view
end

-- Lines the below block of anchor A may take, measured on the marks just
-- drawn: when A is on screen, down to one row above the window bottom, so
-- the first line after the table (X) stays on screen: Neovim places a cursor
-- on a concealed line at the next visible line, and for a target between A
-- and an off-screen X it scrolls and moves the cursor off the target (near
-- EOF, review-wpB-work/probe_reloc2.lua at 100x30). Else m. At least
-- min_keep (the cursor row's own extra lines and the marker).
local function budget(win, view, A, h, m, min_keep)
  local top, tf = view.topline - 1, view.topfill
  if A < top then return m end
  local rows
  if A == top then
    rows = math.min(tf, th(win, { start_row = A, end_row = A }).fill) + th(win, { start_row = A, end_row = A, start_vcol = 0 }).all
  else
    rows = tf + th(win, { start_row = top, end_row = A, start_vcol = 0, max_height = h }).all
  end
  if rows >= h then return m end
  return math.min(m, math.max(h - rows - 1, min_keep))
end

-- The hint line above a row drawn raw (one table per indent: stable block
-- signatures, draw.lua diffs by them).
local hints = {}
local function tall_hint(indent)
  if not hints[indent] then
    local ce = package.loaded["custom.mdtable.celledit"]
    local key = ce and ce.key_label() or "<leader>te"
    hints[indent] = { { string.rep(" ", indent) .. "row too tall to render here — i or " .. key .. " opens the cell editor",
      "Comment" } }
  end
  return hints[indent]
end

local function do_render(win, opts)
  local buf = api.nvim_win_get_buf(win)
  local st = state[buf]
  if not st or not enabled then return end
  local ws = st.wins[win]
  if not ws then ws = { anchors = {} }; st.wins[win] = ws end
  local info = vim.fn.getwininfo(win)[1]
  if not info then return end
  local W = info.width - info.textoff
  local h = info.height
  -- what this render used (:MdTable stats)
  ws.dims = { width = W, height = h, textoff = info.textoff, winwidth = info.width, columns = vim.o.columns,
    lines = vim.o.lines }
  local cur = opts.cursor or api.nvim_win_get_cursor(win)
  local crow, ccol = cur[1] - 1, cur[2]
  local tick = api.nvim_buf_get_changedtick(buf)
  -- Landing correction. Neovim validates the cursor before CursorMoved with
  -- the previous marks; when the target line was concealed and the filler
  -- around it is about 1-2 window heights, it moves the cursor off the
  -- target (often to the line after the table). Jumps whose target we can
  -- compute (:N, :$, /, ?, n, N, G, gg) leave an intent; if the cursor did
  -- not land on that target and the target was a concealed line of our last
  -- render, put the cursor there and render it as the cursor row.
  local reclip = opts.reclip -- WinScrolled: same model, new view (draw only)
  local it = not opts.cursor and not reclip and ws.intent
  if it then
    ws.intent = nil
    local target = M._intent_target(win, it)
    if target and target[1] ~= crow and it.tick == tick and ws.concealed and ws.concealed[target[1]] then
      api.nvim_win_call(win, function() vim.fn.cursor(target[1] + 1, target[2] + 1) end)
      cur = api.nvim_win_get_cursor(win)
      crow, ccol = cur[1] - 1, cur[2]
      stats.corrected = (stats.corrected or 0) + 1
    end
  end
  local seps = seps_for(buf)
  local top, bot = info.topline - 1, info.botline
  local nlines = api.nvim_buf_line_count(buf)
  local key = table.concat({ tick, crow, ccol, W, h, tostring(seps) }, ":")
  local sc = ws.scan
  local in_range = sc and sc.tick == tick and sc.lo <= math.min(top, crow) and sc.hi >= math.min(math.max(bot, crow + 1), nlines)
  local fsig = in_range and foreign_sig(buf, sc.lo, sc.hi)
  if in_range and fsig ~= sc.fsig then in_range = false; key = key .. ":f" .. fsig end
  if not opts.force and not reclip and ws.key == key and in_range then
    -- same model: a pre-render (nofit) of a jump (G, :N, n) drew it without
    -- moving the view; apply the viewport plan here as any render does
    if not opts.nofit then ws.view = settle(win, ws, h, nil, true) end
    return
  end
  local t0 = uv.hrtime()
  ws.key = key
  if not in_range then
    -- at least the visible range (the highlighter parses it too: one parse per key)
    local lo = math.max(0, math.min(top, crow) - h)
    local hi = math.min(nlines, math.max(bot, crow + 1) + h)
    sc = { tick = tick, lo = lo, hi = hi, tables = scan.tables(buf, lo, hi), fsig = foreign_sig(buf, lo, hi) }
    ws.scan = sc
    local s = scan.stats(buf)
    stats.hits, stats.misses, stats.parse = s.hits, s.misses, s.parse_ms_last
  end
  -- Neovim validates the cursor's visibility before CursorMoved, i.e. with
  -- the previous marks: a cursor moved onto a line that was concealed makes
  -- it scroll for the wrong layout. Undo that scroll; the redraw that follows
  -- scrolls again (if needed) with the new marks, and fit() below applies.
  local prev = ws.view
  if not reclip and prev and ws.crow ~= crow and ws.concealed and ws.concealed[crow] then
    local v = api.nvim_win_call(win, vim.fn.winsaveview)
    if v.topline ~= prev.topline or v.topfill ~= prev.topfill then
      api.nvim_win_call(win, function() vim.fn.winrestview({ topline = prev.topline, topfill = prev.topfill }) end)
    end
  end
  local concealed = {}
  local lopts = { width = W, separators = seps }
  local popts = { width = W, separators = seps, tabstop = vim.bo[buf].tabstop }
  local marks, cursor = {}, nil
  local model = { tick = tick, tables = {}, cursor = nil }
  local anchors, moved = {}, nil
  local fitme
  local m = math.max(h - 2, 1) -- the tallest block allowed
  local bfix, clipdep = {}, false
  local bkeep = ws.bkeep or {}
  local hctx -- sticky header context: the cursor's table, cursor in a body row
  for _, tbl in ipairs(sc.tables) do
    local lay = layout.cached(tbl, lopts)
    local anc = project.anchors(tbl, crow)
    local r = anc.row
    local row = tbl.rows[r]
    local above, below
    local entry = { tbl = tbl, lay = lay }
    model.tables[#model.tables + 1] = entry
    local g = project.grid(tbl, lay, popts)
    local min_keep, arows = 1, 1 -- arows: screen rows of the anchor line
    if anc.inside then
      if row.kind == "delim" then
        local cov = project.covered_row(tbl, lay, r, popts)
        above, below, arows = cov.above, cov.below, cov.rows
        cursor = { row = crow, sig = tostring(cov), marks = cov.marks }
      elseif row.ragged then
        above = project.slice(g, 1, g.first[r] - 1)
        below = project.slice(g, g.first[r] + g.count[r], #g.lines)
      else
        local k = project.cell_at(row, ccol)
        local cr = project.cursor_row(tbl, lay, r, k, popts)
        -- once raw, the line stays raw while the cursor stays on it at this
        -- window size (review WP-E F2: gj/gk walk its screen rows into
        -- shorter cells without flipping back to a grid mid-walk)
        local wt = ws.tall
        local tall = cr.rows > h or (wt ~= nil and wt.lnum == crow and wt.W == W and wt.h == h)
        if tall then
          -- the row's line is taller than the window: Neovim would show its
          -- lower part with w_skipcol (drawn with the overlays of the
          -- skipped screen rows on top) and "@@@" on the last row. Show the
          -- line raw instead (a few rows: the cells are not padded), the
          -- other rows stay virtual. Small windows only (review WP-E, E2).
          above = project.slice(g, 1, g.first[r] - 1)
          below = project.slice(g, g.first[r] + g.count[r], #g.lines)
          arows = math.ceil(math.max(vim.fn.strdisplaywidth(row.line), 1) / W)
          model.tall = { lnum = crow, rows = cr.rows }
        else
          above, below = cr.above, cr.below
          cursor = { row = crow, sig = tostring(cr), marks = cr.marks }
          model.cursor = { tbl = tbl, lay = lay, r = r, k = k, lnum = crow, proj = cr }
          fitme = cr
          min_keep, arows = #cr.extra + 1, cr.rows
        end
      end
      entry.cursor = true
    else
      local cov = anc.below and project.covered_tail(tbl, lay, popts) or project.covered_row(tbl, lay, 1, popts)
      above, below, arows = cov.above, cov.below, cov.rows
      if cov.rows > h then
        -- the anchor line drawn as its row is taller than the window (very
        -- narrow windows): raw, as a tall cursor row (Neovim's "@@@")
        local x = anc.below and #tbl.rows or 1
        above = project.slice(g, 1, g.first[x] - 1)
        below = project.slice(g, g.first[x] + g.count[x], #g.lines)
        arows = math.ceil(math.max(vim.fn.strdisplaywidth(tbl.rows[x].line), 1) / W)
        model.tall = model.tall or { lnum = anc.anchor, rows = cov.rows, anchor = true }
      else
        for i, m in ipairs(cov.marks) do
          marks[#marks + 1] = { key = "h" .. tbl.start_row .. ":" .. i, row = anc.anchor, kind = "raw",
            col = m[1], o = m[2], sig = tostring(cov) .. i }
        end
      end
    end
    for l = tbl.start_row, tbl.end_row - 1 do
      marks[#marks + 1] = { key = "c" .. l, row = l, kind = l == anc.anchor and "place" or "conceal" }
      if l ~= anc.anchor then concealed[l] = true end
    end
    local full_below = below
    -- the above block leaves room for the anchor line, one line and the
    -- marker below it and the line after the table: scrolled up to its top
    -- marker, the markers above and below the cursor row are both on screen
    local cap_a = math.max(1, math.min(m, h - arows - 3))
    local clip_a = #above > cap_a
    if clip_a then above = project.clip(g, tbl, above, cap_a, "above") end
    local guess
    if #below > min_keep then -- measured after drawing: it may reach past the window bottom
      guess = math.min(m, math.max(bkeep[tbl.start_row] or m, min_keep))
      below = project.clip(g, tbl, full_below, guess, "below")
    end
    clipdep = clipdep or clip_a or guess ~= nil
    if anc.inside and row.kind == "body" then
      hctx = { g = g, tbl = tbl, A = anc.anchor, r = r, above = above, clipped = clip_a }
    end
    if anc.inside and model.tall and model.tall.lnum == crow and not model.tall.anchor
        and vim.g.mdtable_cell_editor ~= false and vim.g.mdtable_tall_hint ~= false then
      -- the raw row: a one-line hint above it (a copy: blocks are memoized;
      -- vim.g.mdtable_tall_hint = false turns it off). Added after hctx: the
      -- sticky header's room is the grid lines. Known: a pinned header float
      -- can cover the hint (header.lua seats the float over all the filler).
      local hint = tall_hint(tbl.indent)
      above = vim.list_extend(vim.list_slice(above), { hint })
    end
    if #above > 0 then
      marks[#marks + 1] = { key = "a" .. tbl.start_row, row = anc.anchor, kind = "vl", above = true, lines = above,
        sig = project.block_sig(above) }
    end
    if #below > 0 then
      marks[#marks + 1] = { key = "b" .. tbl.start_row, row = anc.anchor, kind = "vl", lines = below,
        sig = project.block_sig(below) }
      if guess then
        bfix[#bfix + 1] = { d = marks[#marks], g = g, tbl = tbl, full = full_below, keep = guess, A = anc.anchor, min = min_keep }
      end
    end
    anchors[tbl.start_row] = { anchor = anc.anchor, above = #above }
    local old = ws.anchors[tbl.start_row]
    if old and old.anchor ~= anc.anchor and ws.tick == tick then
      moved = moved or {}
      moved[old.anchor] = { new = anc.anchor, old_above = old.above, new_above = #above }
    end
  end
  ws.anchors = anchors
  ws.tall = (model.tall and not model.tall.anchor) and { lnum = model.tall.lnum, W = W, h = h } or nil
  local C = draw.apply(buf, win, { marks = marks, cursor = cursor }, tick)
  ws.tick = tick
  ws.model = model
  local view = api.nvim_win_call(win, vim.fn.winsaveview)
  -- below blocks taller than the window: end them at the window bottom (in
  -- table order: a block that reaches the bottom puts later tables off screen)
  local nkeep = {}
  for _, f in ipairs(bfix) do
    local k = budget(win, view, f.A, h, m, f.min)
    nkeep[f.tbl.start_row] = k
    if k ~= f.keep then
      local lines = project.clip(f.g, f.tbl, f.full, k, "below")
      f.d.lines, f.d.sig = lines, project.block_sig(lines)
      draw.update(buf, win, f.d)
    end
  end
  ws.bkeep, ws.clipdep = nkeep, clipdep
  if C.set + C.updated + C.deleted + C.cursor > 0 then
    -- the marks changed line heights: drop Neovim's cached botline (it would
    -- otherwise scroll for the old layout when the cursor moved below it)
    api.nvim_win_call(win, function() vim.fn.winrestview({ topline = view.topline, topfill = view.topfill }) end)
  end
  ws.hctx = hctx
  ws.fit = fitme and { crow = crow, cr = fitme, key = tick .. ":" .. crow .. ":" .. W .. ":" .. model.cursor.k } or nil
  if not opts.nofit and reanchor(win, ws, moved, view) then view = api.nvim_win_call(win, vim.fn.winsaveview) end
  ws.concealed, ws.crow = concealed, crow
  ws.view = settle(win, ws, h, view, not opts.nofit)
  local ms = (uv.hrtime() - t0) / 1e6
  if reclip then -- not a render of the key: a draw-only update for the new view
    stats.reclips = (stats.reclips or 0) + 1
    stats.rtimes = stats.rtimes or {}
    stats.rtimes[#stats.rtimes + 1] = ms
    if #stats.rtimes > 200 then table.remove(stats.rtimes, 1) end
  else
    stats.n, stats.last, stats.max = stats.n + 1, ms, math.max(stats.max, ms)
    stats.times[#stats.times + 1] = ms
    if #stats.times > 200 then table.remove(stats.times, 1) end
  end
  stats.tables = #sc.tables
  stats.marks = { set = C.set, updated = C.updated, deleted = C.deleted, cursor = C.cursor, untouched = C.untouched,
    deleted_conceal = C.deleted_conceal }
end

function M.render(win, opts)
  win = (win == nil or win == 0) and api.nvim_get_current_win() or win
  if rendering or not api.nvim_win_is_valid(win) then return end
  rendering = true
  local ok, err = pcall(do_render, win, opts or {})
  rendering = false
  if not ok then
    local msg = tostring(err)
    if not err_shown[msg] then
      err_shown[msg] = true
      vim.notify("mdtable: " .. msg, vim.log.levels.ERROR)
    end
  end
end

local function render_buf(buf, opts)
  if not api.nvim_buf_is_valid(buf) then return end
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then M.render(win, opts) end
  end
end

-- Model of the last render of a window (nav.lua), refreshed when stale.
function M.model(win)
  win = (win == nil or win == 0) and api.nvim_get_current_win() or win
  if not api.nvim_win_is_valid(win) then return nil end
  local buf = api.nvim_win_get_buf(win)
  local st = state[buf]
  if not st or not enabled then return nil end
  M.render(win)
  local ws = st.wins[win]
  if ws and ws.model and ws.model.tick == api.nvim_buf_get_changedtick(buf) then return ws.model end
  return nil
end

-- The full grid of a table entry of the last model (nav.lua: moves by
-- rendered screen lines); memoized on the layout.
function M.grid(entry) return project.grid(entry.tbl, entry.lay) end

-- Re-apply the viewport plan to the current view of win (after nav.lua set
-- a view of its own): scroll-to-fit runs again, then the float's seat.
function M.resettle(win)
  win = (win == nil or win == 0) and api.nvim_get_current_win() or win
  local st = state[api.nvim_win_get_buf(win)]
  local ws = st and st.wins[win]
  if not (ws and ws.dims) then return end
  ws.fitted = nil
  ws.view = settle(win, ws, ws.dims.height, nil, true)
end

-- The viewport plan of the last render (tests).
function M._plan(win)
  win = (win == nil or win == 0) and api.nvim_get_current_win() or win
  if not api.nvim_win_is_valid(win) then return nil end
  local st = state[api.nvim_win_get_buf(win)]
  local ws = st and st.wins[win]
  return ws and ws.plan
end

function M._last_model(win)
  win = (win == nil or win == 0) and api.nvim_get_current_win() or win
  if not api.nvim_win_is_valid(win) then return nil end
  local st = state[api.nvim_win_get_buf(win)]
  local ws = st and st.wins[win]
  return ws and ws.model
end

-- Intents (see the landing correction in do_render). kind "line": lnum, col
-- (nil: first non-blank); kind "search": pattern, backward, origin.
-- An optimisation since the viewport clipping (it saves a correction frame);
-- vim.g.mdtable_intent = false turns it off (tests prove landing without).
function M.set_intent(win, it)
  if vim.g.mdtable_intent == false then return end
  win = (win == nil or win == 0) and api.nvim_get_current_win() or win
  local st = state[api.nvim_win_get_buf(win)]
  if not st or not enabled then return end
  local ws = st.wins[win]
  if not ws then ws = { anchors = {} }; st.wins[win] = ws end
  it.tick = api.nvim_buf_get_changedtick(api.nvim_win_get_buf(win))
  it.time = uv.now()
  ws.intent = it
end

function M._intent_target(win, it)
  if uv.now() - it.time > 1000 then return nil end -- the jump did not move the cursor; stale
  local buf = api.nvim_win_get_buf(win)
  local n = api.nvim_buf_line_count(buf)
  if it.kind == "line" then
    local l = math.max(0, math.min(it.lnum, n - 1))
    local line = api.nvim_buf_get_lines(buf, l, l + 1, false)[1] or ""
    return { l, it.col or #(line:match("^%s*")) }
  end
  -- next match from the jump's origin (incsearch has moved the cursor by
  -- CmdlineLeave) with the search's own rules ('ignorecase', 'smartcase',
  -- 'magic', 'wrapscan'): searchpos() from the origin, view restored
  return api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    vim.fn.cursor(it.origin[1] + 1, it.origin[2] + 1)
    local ok, pos = pcall(vim.fn.searchpos, it.pattern, "n" .. (it.backward and "b" or "") .. (vim.o.wrapscan and "w" or "W"))
    vim.fn.winrestview(view)
    if not ok or type(pos) ~= "table" or pos[1] == 0 then return nil end
    return { pos[1] - 1, pos[2] - 1 }
  end)
end

-- Render with the jump's target as the cursor row before the jump runs, so
-- the target is the table's visible anchor when Neovim validates the cursor.
-- A stale pre-render is harmless: a cursor row looks like its virtual row.
function M.prerender(win)
  win = (win == nil or win == 0) and api.nvim_get_current_win() or win
  local st = state[api.nvim_win_get_buf(win)]
  local ws = st and st.wins[win]
  local it = ws and ws.intent
  if not it then return end
  local target = M._intent_target(win, it)
  if target then M.render(win, { cursor = { target[1] + 1, target[2] }, nofit = true }) end
end

-- Move the cursor of win to (lnum, col) (0-based) and render right away.
function M.goto(win, lnum, col)
  api.nvim_win_call(win, function() vim.fn.cursor(lnum + 1, col + 1) end)
  M.render(win)
end

function M.attached(buf) return state[buf] ~= nil and enabled end

local nav = require("custom.mdtable.nav")
nav.setup(M)

function M.attach(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  if state[buf] then return end
  state[buf] = { wins = {} }
  scan.attach(buf)
  local g = api.nvim_create_augroup("mdtable_" .. buf, { clear = true })
  api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = g, buffer = buf, callback = function() M.render(api.nvim_get_current_win()) end,
  })
  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave", "BufWinEnter" }, {
    group = g, buffer = buf, callback = function() render_buf(buf) end,
  })
  api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, { group = g, buffer = buf, callback = function() M.detach(buf) end })
  api.nvim_create_autocmd("BufWinLeave", { group = g, buffer = buf, callback = function() vim.schedule(header.prune) end })
  -- option check once the user is idle: render-markdown sets its window
  -- options after the first render, so checking at attach warns falsely
  api.nvim_create_autocmd("CursorHold", { group = g, buffer = buf, once = true, callback = function()
    local win = api.nvim_get_current_win()
    if api.nvim_win_get_buf(win) == buf then check_options(win) end
  end })
  if enabled then nav.map(buf) end
  render_buf(buf)
end

function M.detach(buf)
  buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
  if not state[buf] then return end
  state[buf] = nil
  local ce = package.loaded["custom.mdtable.celledit"]
  if ce then ce.close_buf(buf) end -- an editor open on this buffer
  pcall(api.nvim_del_augroup_by_name, "mdtable_" .. buf)
  if api.nvim_buf_is_valid(buf) then nav.unmap(buf) end
  header.close_buf(buf)
  draw.clear(buf)
  scan.detach(buf)
end

local function rerender_all()
  for buf, st in pairs(state) do
    st.wins = {}
    if enabled then
      nav.map(buf); render_buf(buf, { force = true })
    else
      header.close_buf(buf)
      if api.nvim_buf_is_valid(buf) then draw.clear(buf); nav.unmap(buf) end
    end
  end
end

function M.toggle(on)
  if on == nil then on = not enabled end
  enabled = on
  local ce = package.loaded["custom.mdtable.celledit"]
  if not on and ce then ce.close_all() end
  rerender_all()
end

function M.is_enabled() return enabled end

local function median(t)
  if #t == 0 then return 0 end
  local s = vim.list_extend({}, t)
  table.sort(s)
  return s[math.floor((#s + 1) / 2)]
end

function M.stats_line()
  local m = stats.marks or {}
  return ("MdTable: %d renders, last %.2fms, median %.2fms, max %.2fms, %d tables; marks last render: set %d, updated %d, deleted %d, cursor-row %d, untouched %d; cache hits %d, misses %d; parse %.2fms; re-clips %d (median %.2fms); corrected %d")
    :format(stats.n, stats.last, median(stats.times), stats.max, stats.tables, m.set or 0, m.updated or 0, m.deleted or 0,
      m.cursor or 0, m.untouched or 0, stats.hits, stats.misses, stats.parse or 0, stats.reclips or 0,
      median(stats.rtimes or {}), stats.corrected or 0)
end

-- Per window: the sizes the last render used, and the current ones when
-- they differ (a render that missed a resize).
function M.dims_lines()
  local out = {}
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    local st = state[api.nvim_win_get_buf(win)]
    local d = st and st.wins[win] and st.wins[win].dims
    if d then
      local info = vim.fn.getwininfo(win)[1]
      local now = { width = info.width - info.textoff, height = info.height, textoff = info.textoff, winwidth = info.width,
        columns = vim.o.columns, lines = vim.o.lines }
      local stale = {}
      for _, k in ipairs({ "width", "height", "textoff", "winwidth", "columns", "lines" }) do
        if now[k] ~= d[k] then stale[#stale + 1] = ("%s now %d"):format(k, now[k]) end
      end
      out[#out + 1] = ("MdTable win %d: width %d, height %d, textoff %d, winwidth %d, columns %d, lines %d%s"):format(win,
        d.width, d.height, d.textoff, d.winwidth, d.columns, d.lines, #stale > 0 and (" (STALE: " .. table.concat(stale, ", ") .. ")") or "")
    end
  end
  return out
end

set_hl()
local ag = api.nvim_create_augroup("mdtable", { clear = true })
api.nvim_create_autocmd("ColorScheme", { group = ag, callback = set_hl })
api.nvim_create_autocmd("WinResized", {
  group = ag,
  callback = function()
    for _, win in ipairs(vim.v.event.windows or {}) do
      if api.nvim_win_is_valid(win) and state[api.nvim_win_get_buf(win)] then M.render(win) end
    end
  end,
})
-- WinScrolled: no relayout; render only when the view left the scanned range.
api.nvim_create_autocmd("WinScrolled", {
  group = ag,
  callback = function()
    if rendering then return end
    for w in pairs(vim.v.event) do
      local win = tonumber(w)
      if win and api.nvim_win_is_valid(win) then
        local buf = api.nvim_win_get_buf(win)
        local st = state[buf]
        local ws = st and st.wins[win]
        if ws and ws.scan then
          ws.view = api.nvim_win_call(win, vim.fn.winsaveview)
          local info = vim.fn.getwininfo(win)[1]
          if info and (info.topline - 1 < ws.scan.lo or info.botline > ws.scan.hi) then
            M.render(win, { nofit = true })
          elseif ws.clipdep then
            M.render(win, { nofit = true, reclip = true })
          end
          -- sticky header for the new view, from the same viewport plan (no
          -- scroll: the float hides rather than fight <C-e>; header.sync
          -- caches by view)
          if info and enabled and api.nvim_win_is_valid(win) then
            local t0 = uv.hrtime()
            settle(win, ws, info.height, ws.view, false)
            stats.htimes = stats.htimes or {}
            stats.htimes[#stats.htimes + 1] = (uv.hrtime() - t0) / 1e6
            if #stats.htimes > 200 then table.remove(stats.htimes, 1) end
          end
        end
      end
    end
  end,
})
-- :N, :$, /pat, ?pat: record the jump's target as an intent.
local cmd_origin
api.nvim_create_autocmd("CmdlineEnter", { group = ag, callback = function()
  local c = api.nvim_win_get_cursor(0)
  cmd_origin = { c[1] - 1, c[2] }
end })
api.nvim_create_autocmd("CmdlineLeave", { group = ag, callback = function()
  if vim.v.event.abort or not cmd_origin then return end
  if not state[api.nvim_get_current_buf()] then return end
  local t, text = vim.fn.getcmdtype(), vim.fn.getcmdline()
  if t == ":" then
    local num = text:match("^%s*(%d+)%s*$")
    if num then M.set_intent(0, { kind = "line", lnum = tonumber(num) - 1 })
    elseif text:match("^%s*%$%s*$") then M.set_intent(0, { kind = "line", lnum = math.huge }) end
  elseif (t == "/" or t == "?") and text ~= "" then
    -- drop a search offset (/pat/e, ?pat?b): the target is the match itself
    local pat = text
    local i = 1
    while i <= #pat do
      local ch = pat:sub(i, i)
      if ch == "\\" then i = i + 2 elseif ch == t then pat = pat:sub(1, i - 1); break else i = i + 1 end
    end
    M.set_intent(0, { kind = "search", pattern = pat, backward = t == "?", origin = cmd_origin })
  end
  M.prerender(0)
end })

api.nvim_create_autocmd("WinClosed", {
  group = ag,
  callback = function(ev)
    local win = tonumber(ev.match)
    if win then
      draw.forget_win(win)
      if header._floats[win] then
        local ok = pcall(header.close, win)
        if not ok then vim.schedule(header.prune) end
      end
    end
  end,
})
api.nvim_create_autocmd("BufWinEnter", { group = ag, callback = function() header.prune() end })

api.nvim_create_user_command("MdTable", function(o)
  local a = o.fargs[1] or "toggle"
  if a == "toggle" then M.toggle()
  elseif a == "enable" then M.toggle(true)
  elseif a == "disable" then M.toggle(false)
  elseif a == "separators" then
    local b = api.nvim_get_current_buf()
    vim.b[b].mdtable_row_separators = not seps_for(b)
    if state[b] then render_buf(b, { force = true }) end
  elseif a == "header" then
    local b = api.nvim_get_current_buf()
    vim.b[b].mdtable_sticky_header = not header.enabled(b)
    if state[b] then render_buf(b, { force = true }) end
  elseif a == "edit" then
    require("custom.mdtable.celledit").open_at_cursor()
  elseif a == "stats" then
    if o.fargs[2] == "render" then M.render(0, { force = true }) end
    print(table.concat(vim.list_extend({ M.stats_line() }, M.dims_lines()), "\n"))
  else
    vim.notify("MdTable: toggle|enable|disable|separators|header|edit|stats", vim.log.levels.ERROR)
  end
end, { nargs = "*", complete = function() return { "toggle", "enable", "disable", "separators", "header", "edit", "stats" } end })

return M
