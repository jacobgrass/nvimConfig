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
-- Assumes 'wrap' on, 'linebreak', 'showbreak' and 'breakindent' off,
-- conceallevel=3 and concealcursor=nvic (render-markdown win_options).
local api, uv = vim.api, vim.uv or vim.loop
local scan = require("custom.mdtable.scan")
local layout = require("custom.mdtable.layout")
local project = require("custom.mdtable.project")
local draw = require("custom.mdtable.draw")

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
-- window bottom, scroll by the minimum (hide filler above topline first, then
-- whole lines). Never when the grid is fully visible.
local function fit(win, crow, cr, h, view)
  view = view or api.nvim_win_call(win, vim.fn.winsaveview)
  local top, tf = view.topline - 1, view.topfill
  if crow < top then return false end
  local pre
  if crow == top then
    pre = tf
  else
    pre = tf + th(win, { start_row = top, end_row = crow - 1, start_vcol = 0 }).all
      + th(win, { start_row = crow, end_row = crow }).fill
  end
  local grid_top = pre - cr.sep_above
  local bottom = grid_top + cr.height
  local d = math.min(bottom - h, grid_top)
  M.last_fit = { top = top, topfill = tf, pre = pre, height = cr.height, h = h, d = d }
  if d <= 0 then return false end
  local ntop, nfill
  if d <= tf then
    ntop, nfill = top, tf - d
  else
    local need = d - tf
    if crow == top then return false end
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
  api.nvim_win_call(win, function() vim.fn.winrestview({ topline = ntop + 1, topfill = nfill, skipcol = 0 }) end)
  return true
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
  if not opts.force and not reclip and ws.key == key and in_range then return end
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
        above, below = cr.above, cr.below
        cursor = { row = crow, sig = tostring(cr), marks = cr.marks }
        model.cursor = { tbl = tbl, lay = lay, r = r, k = k, lnum = crow, proj = cr }
        fitme = cr
        min_keep, arows = #cr.extra + 1, cr.rows
      end
      entry.cursor = true
    else
      local cov = anc.below and project.covered_tail(tbl, lay, popts) or project.covered_row(tbl, lay, 1, popts)
      above, below, arows = cov.above, cov.below, cov.rows
      for i, m in ipairs(cov.marks) do
        marks[#marks + 1] = { key = "h" .. tbl.start_row .. ":" .. i, row = anc.anchor, kind = "raw",
          col = m[1], o = m[2], sig = tostring(cov) .. i }
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
  local scrolled = false
  if not opts.nofit then
    scrolled = reanchor(win, ws, moved, view)
    local fkey = tick .. ":" .. crow .. ":" .. W .. ":" .. (model.cursor and model.cursor.k or 0)
    if fitme and ws.fitted ~= fkey then
      ws.fitted = fkey
      scrolled = fit(win, crow, fitme, h, not scrolled and view or nil) or scrolled
    end
  end
  ws.concealed, ws.crow = concealed, crow
  ws.view = scrolled and api.nvim_win_call(win, vim.fn.winsaveview) or view
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
  pcall(api.nvim_del_augroup_by_name, "mdtable_" .. buf)
  if api.nvim_buf_is_valid(buf) then nav.unmap(buf) end
  draw.clear(buf)
  scan.detach(buf)
end

local function rerender_all()
  for buf, st in pairs(state) do
    st.wins = {}
    if enabled then
      nav.map(buf); render_buf(buf, { force = true })
    elseif api.nvim_buf_is_valid(buf) then
      draw.clear(buf); nav.unmap(buf)
    end
  end
end

function M.toggle(on)
  if on == nil then on = not enabled end
  enabled = on
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
    if win then draw.forget_win(win) end
  end,
})

api.nvim_create_user_command("MdTable", function(o)
  local a = o.fargs[1] or "toggle"
  if a == "toggle" then M.toggle()
  elseif a == "enable" then M.toggle(true)
  elseif a == "disable" then M.toggle(false)
  elseif a == "separators" then
    local b = api.nvim_get_current_buf()
    vim.b[b].mdtable_row_separators = not seps_for(b)
    if state[b] then render_buf(b, { force = true }) end
  elseif a == "stats" then
    if o.fargs[2] == "render" then M.render(0, { force = true }) end
    print(M.stats_line())
  else
    vim.notify("MdTable: toggle|enable|disable|separators|stats", vim.log.levels.ERROR)
  end
end, { nargs = "*", complete = function() return { "toggle", "enable", "disable", "separators", "stats" } end })

return M
