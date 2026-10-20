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
-- Rows taller than the window (WP-J, tall_of: the row's most lines from
-- above plus its most screen rows below them exceed the window minus the
-- sticky header float when it would show) are virtual while the cursor is
-- on them (virtual_row, project.tall_row): the line is a covered row, the
-- active cell (model.active, the cursor's cell) and its header cell are
-- highlighted (MdTableActiveCell, MdTableActiveCol), j/k scroll the row
-- (M.tall_scroll) and the edit keys open the cell editor (nav.lua). Raw
-- only when the line itself does not fit the window, or on an error.
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
  -- WP-J: the active cell of a virtual (tall) cursor row and its header cell
  api.nvim_set_hl(0, "MdTableActiveCell", { link = "Visual", default = true })
  api.nvim_set_hl(0, "MdTableActiveCol", { link = "CursorColumn", default = true })
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
-- ri (project.row_info): the fit holds for every cell of the row (WP-I): the
-- row's first own grid line G stays on its screen row across cells, so the
-- view keeps G at least ri.lil rows down (the line's first row on screen in
-- every cell) and G + ri.depth within the window. With the cursor line at
-- the window top and G above that, it shows more filler (scrolls up) when
-- the row still fits.
-- The view with R screen rows above line A's text (A's filler included).
local function view_above(win, A, R)
  local fillA = th(win, { start_row = A, end_row = A }).fill
  if R <= fillA then return { topline = A + 1, topfill = math.max(R, 0) } end
  local base = fillA
  for T = A - 1, 0, -1 do
    local x = th(win, { start_row = T, end_row = T })
    base = base + x.all - x.fill
    if base >= R then return { topline = T + 1, topfill = 0 } end
    if base + x.fill >= R then return { topline = T + 1, topfill = R - base } end
    base = base + x.fill
  end
  return { topline = 1, topfill = 0 }
end

local function fit(win, crow, cr, h, view, reserve, ri)
  local top, tf = view.topline - 1, view.topfill
  if crow < top then return nil end
  local pre
  if crow == top then
    pre = tf
  else
    pre = tf + th(win, { start_row = top, end_row = crow - 1, start_vcol = 0 }).all
      + th(win, { start_row = crow, end_row = crow }).fill
  end
  local lil = cr.lines_in_line or 0
  local grid_top = pre - cr.sep_above + lil
  local bottom = pre - cr.sep_above + cr.height
  local d = math.min(bottom - h, grid_top - (reserve or 0))
  local G = pre + lil
  if ri then
    -- (+ 2 below the row's longest line: the below block's marker and the
    -- line after the table (X) stay on screen in every cell, see budget())
    bottom = G + math.max(ri.depth, ri.rl + 2)
    d = math.min(bottom - h, G - math.max(ri.sep + (reserve or 0), ri.lil))
  end
  M.last_fit = { top = top, topfill = tf, pre = pre, height = cr.height, h = h, d = d }
  if cr.tall and pre - cr.sep_above < (reserve or 0) then
    -- a virtual row (WP-J) entered under the sticky header float: its first
    -- screen row (or the note above it, sep_above) just below the float
    local nv = view_above(win, crow, reserve + cr.sep_above)
    if nv.topline ~= view.topline or nv.topfill ~= tf then
      M.last_fit.new = { nv.topline - 1, nv.topfill }
      return nv
    end
  end
  if d < 0 and ri and crow == top and G < ri.lil and bottom + ri.lil - G <= h then
    local fill = th(win, { start_row = crow, end_row = crow }).fill
    local nf = math.min(fill, ri.lil - lil)
    if nf > tf then
      M.last_fit.new = { crow, nf }
      return { topline = crow + 1, topfill = nf }
    end
  end
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
      local want = ri and math.max(ri.sep, ri.lil) - lil or cr.sep_above
      ntop, nfill = crow, math.max(0, math.min(th(win, { start_row = crow, end_row = crow }).fill, want))
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
-- view is scroll-to-fit with float_height rows reserved (once per row:
-- ws.fitted; it holds for every cell, project.row_info), then the float's seat (header.scroll_view). A cursor
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
    if f and ws.fitted ~= f.key then v = fit(win, f.crow, f.cr, h, v, p.float_height, f.ri) or v end
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
-- lim: a cursor row's longest line (other cells) ends lim rows lower; the
-- budget counts from there, so the marker is on one screen row in every
-- cell (WP-I), lim more lines kept.
local function budget(win, view, A, h, m, min_keep, lim)
  lim = lim or 0
  local top, tf = view.topline - 1, view.topfill
  if A < top then return m end
  local rows
  if A == top then
    rows = math.min(tf, th(win, { start_row = A, end_row = A }).fill) + th(win, { start_row = A, end_row = A, start_vcol = 0 }).all
  else
    rows = tf + th(win, { start_row = top, end_row = A, start_vcol = 0, max_height = h }).all
  end
  rows = rows + lim
  if rows >= h then return m end
  -- (at least the marker after the row's longest line, in every cell)
  return math.min(m, math.max(lim + math.max(h - rows - 1, 1), min_keep))
end

-- WP-J: the note drawn right above a virtual row (project.tall_row) during
-- the first visit of a virtual row in the session (one line per indent:
-- stable block signatures); vim.g.mdtable_tall_hint = false: never.
local hints, hint_visit = {}, nil -- hint_visit: { buf, win, lnum, done }
M.HINT = "tall row: Ctrl-hjkl select a cell, i edits in a float"
local function vrow_note(indent)
  if not hints[indent] then hints[indent] = { { string.rep(" ", indent) .. M.HINT, "Comment" } } end
  return hints[indent]
end
local function vrow_hint(win, buf, lnum, indent)
  if vim.g.mdtable_tall_hint == false or vim.g.mdtable_cell_editor == false then return nil end
  local hv = hint_visit
  if hv and (hv.done or hv.buf ~= buf or hv.win ~= win or hv.lnum ~= lnum) then return nil end
  hint_visit = hv or { buf = buf, win = win, lnum = lnum }
  return hints[indent] or vrow_note(indent)
end
function M._reset_hint() hint_visit = nil end -- tests: a new session

-- Screen rows of the buffer lines directly above tbl, as virtual lines
-- (nearest last), covering at least `need` rows: the lines that a cursor
-- row's spill rows carry beyond the table's own lines above (WP-I round 3).
-- Stops at another table or the buffer start; the rest are empty rows (the
-- table then sits lower while the cursor is on that row). Memoized per
-- window: { opts (popts + ext), lines (buffer lines to conceal) }.
local EMPTY_ROW = { { "", "Normal" } }
local function ext_for(ws, buf, tbl, tables, need, W, tick, popts)
  local key = table.concat({ tick, tbl.start_row, W, need, popts.tabstop, tostring(popts.separators) }, ":")
  ws.extc = ws.extc or {}
  local e = ws.extc[key]
  if e then return e end
  local function in_table(l)
    for _, t in ipairs(tables) do if l >= t.start_row and l < t.end_row then return true end end
    return false
  end
  local rows, lines = {}, {}
  local l = tbl.start_row - 1
  while #rows < need and l >= 0 and not in_table(l) do
    local text = api.nvim_buf_get_lines(buf, l, l + 1, false)[1] or ""
    if text:find("\t") then
      local o, col = {}, 0
      for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if ch == "\t" then local n = popts.tabstop - col % popts.tabstop; o[#o + 1] = (" "):rep(n); col = col + n
        else o[#o + 1] = ch; col = col + vim.fn.strdisplaywidth(ch) end
      end
      text = table.concat(o)
    end
    local pieces, cur, cw = {}, {}, 0
    for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
      local w = api.nvim_strwidth(ch)
      if cw + w > W then pieces[#pieces + 1] = { { table.concat(cur), "Normal" } }; cur, cw = {}, 0 end
      cur[#cur + 1] = ch; cw = cw + w
    end
    if #cur > 0 or #pieces == 0 then pieces[#pieces + 1] = #cur > 0 and { { table.concat(cur), "Normal" } } or EMPTY_ROW end
    for i = #pieces, 1, -1 do table.insert(rows, 1, pieces[i]) end
    lines[#lines + 1] = l
    l = l - 1
  end
  local blank = math.max(need - #rows, 0)
  while #rows < need do table.insert(rows, 1, EMPTY_ROW) end
  e = { opts = setmetatable({ ext = rows }, { __index = popts }), lines = lines, blank = blank }
  ws.extc = { [key] = e } -- one entry: the rows above one table at a time
  return e
end

-- WP-J predicate: row r is "tall" when its most grid lines from above drawn
-- on the line plus its most screen rows below them, over all cells (the
-- rows that show every cell's line from one view), exceed the window minus
-- the sticky header float when the float would show for the row (the
-- view-independent part of header.rule: a body row whose grid fits under
-- it, the header not on the line). Also returns the row_info and opts the
-- in-place drawing uses ("flow": with the buffer lines above the table).
local function tall_of(ws, buf, tbl, lay, r, popts, tables, W, h, tick)
  local g = project.grid(tbl, lay, popts)
  local ropts, prose, ext = popts, nil, nil
  local rinfo = project.row_info(tbl, lay, r, ropts)
  local ab_end = g.first[r] - 1
  if popts.spill == "flow" and rinfo.spill > ab_end then
    ext = ext_for(ws, buf, tbl, tables, rinfo.spill - ab_end, W, tick, popts)
    ropts, prose = ext.opts, ext.lines
    rinfo = project.row_info(tbl, lay, r, ropts)
  end
  local nf = header.height(buf, { g = g, tbl = tbl }, h)
  local hf = (nf > 0 and tbl.rows[r].kind == "body" and not rinfo.header_all and rinfo.hl + nf <= h) and nf or 0
  return rinfo.lil + rinfo.rl > h - hf, rinfo, ropts, prose, ext
end

local function note_error(err)
  local msg = "mdtable: " .. tostring(err)
  if not err_shown[msg] then
    err_shown[msg] = true
    vim.notify(msg, vim.log.levels.ERROR)
  end
end

-- WP-J: the virtual cursor row on row r of tbl, active cell k (project.tall_row
-- with this window's in-row scroll ws.vrow), or nil when its line, every
-- byte concealed, does not fit the window (raw then; Neovim scrolls inside
-- a line taller than the window). Second value: true when the line does
-- not fit under the sticky header float (no float for the row then). A cell
-- change whose lines are all above the screen (after an in-row scroll)
-- scrolls back until the cell's first line is the first line shown (a
-- uniform scroll: the in-row offset first, then the view; third value: the
-- rows left for the view, do_render shows that much more of the line's
-- filler); otherwise a cell change changes highlights only.
local function virtual_row(ws, win, buf, tbl, lay, r, k, popts, crow, W, h)
  local vs = ws.vrow
  if not (vs and vs.lnum == crow and vs.W == W and vs.h == h and vs.buf == buf) then
    vs = { lnum = crow, W = W, h = h, buf = buf, off = 0, k = k }
  end
  local hint = vrow_hint(win, buf, crow, tbl.indent or 0)
  local ok, tr = pcall(project.tall_row, tbl, lay, r, k, vs.off, popts, hint)
  if not ok then note_error(tr); return nil end
  if tr.rows + 3 > h then return nil end
  local nofloat = tr.rows + 3 + header.height(buf, { g = tr.g, tbl = tbl }, h) > h
  local rem, back = 0, false
  if vs.k ~= k and vs.vis_lo then
    local lc, nk = lay.rows[r].cells[k], 0
    for _, ch in ipairs(lc and lc.chunks or {}) do if not ch.fill then nk = nk + 1 end end
    if tr.first_t + math.max(nk, 1) - 1 < vs.vis_lo then
      local need = vs.vis_lo - tr.first_t
      rem, back = math.max(need - tr.off, 0), true
      if tr.off > 0 then tr = project.tall_row(tbl, lay, r, k, tr.off - need, popts, hint) end
    end
  end
  vs.k, vs.off = k, tr.off
  ws.vrow = vs
  return tr, nofloat, rem, back
end

-- WP-J: what the screen shows of a virtual row in the settled view (nav.lua
-- in-row scroll, test oracles): vis_lo / vis_hi, the first and last tape
-- index on screen (vis_lo: the first one below the header float);
-- room_down / room_up: rows to scroll until the row's last line is on
-- screen / its first line is below the float.
local function vrow_rooms(win, ws, vr, h)
  local tr, v = vr.proj, ws.view or api.nvim_win_call(win, vim.fn.winsaveview)
  local A = vr.lnum
  local fill = th(win, { start_row = A, end_row = A }).fill
  local t, tf = v.topline - 1, v.topfill
  local pre
  if A < t then pre = 0
  elseif A == t then pre = math.min(tf, fill)
  else pre = tf + th(win, { start_row = t, end_row = A - 1, start_vcol = 0, max_height = h }).all + fill end
  local f = header._floats[win]
  local res = (f and api.nvim_win_is_valid(f.win)) and api.nvim_win_get_height(f.win) or 0
  local bl = vr.bmark and vr.bmark.lines or {}
  local nb = #bl - ((#bl > 0 and #bl < #tr.below) and 1 or 0) -- a clipped block ends in its marker
  vr.pre, vr.reserve = pre, res
  vr.vis_lo = tr.s - (pre - res)
  vr.vis_hi = math.min(tr.s + tr.consumed - 1 + nb, tr.s + h - 1 - pre)
  vr.room_down = math.max(0, tr.last_t - vr.vis_hi)
  vr.room_up = math.max(0, vr.vis_lo - tr.first_t)
  if ws.vrow and ws.vrow.lnum == A then ws.vrow.vis_lo = vr.vis_lo end
end

-- The raw fallback's note above the line is hidden: Neovim fitted the line
-- by hiding all of its filler after the render (the CursorMoved render then
-- renders in full, see do_render's view nudge).
local function raw_note_pending(win, ws, crow, h)
  local mt = ws.model and ws.model.tall
  if not (mt and mt.note and not mt.anchor and mt.lnum == crow and mt.arows + 1 <= h) then return false end
  local v = api.nvim_win_call(win, vim.fn.winsaveview)
  return v.topline - 1 == crow and v.topfill == 0 and (v.skipcol or 0) == 0
end

local function do_render(win, opts)
  local buf = api.nvim_win_get_buf(win)
  local st = state[buf]
  if not st or not enabled then return end
  local ws = st.wins[win]
  if not ws then ws = { anchors = {} }; st.wins[win] = ws end
  local ptick, plil = ws.tick, ws.lil -- the previous render (view compensation)
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
  if not opts.force and not reclip and ws.key == key and in_range and not raw_note_pending(win, ws, crow, h) then
    -- same model: a pre-render (nofit) of a jump (G, :N, n) drew it without
    -- moving the view; apply the viewport plan here as any render does
    if not opts.nofit then ws.view = settle(win, ws, h, nil, true) end
    if ws.model and ws.model.vrow then vrow_rooms(win, ws, ws.model.vrow, h) end
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
  -- vim.g.mdtable_spill: "flow" (default), "row" or "cell", what the spill
  -- rows of a cursor row carry (project.lua header)
  local sp = vim.g.mdtable_spill
  local popts = { width = W, separators = seps, tabstop = vim.bo[buf].tabstop,
    spill = (sp == "row" or sp == "cell") and sp or "flow" }
  local marks, cursor = {}, nil
  local model = { tick = tick, tables = {}, cursor = nil }
  local anchors, moved = {}, nil
  local fitme, fitri
  local vrem, vback -- WP-J: a virtual row's scroll-back to the active cell, the rows left for the view (virtual_row)
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
    local ri -- project.row_info of the cursor row drawn as a grid
    local prose -- buffer lines above the table drawn on the cursor row's spill rows
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
        -- per row, never per cell (WP-I): every cell drawn with the row's nl
        -- lines (project.row_info). WP-J: a row taller than the window
        -- (tall_of) is drawn virtual while the cursor is on it
        -- (virtual_row: the active cell highlighted; nav.lua moves it,
        -- celledit.lua edits it); raw only as a fallback, when its line
        -- (every byte concealed) does not fit the window or on an error
        local tall, rinfo, ropts, rprose, ext = tall_of(ws, buf, tbl, lay, r, popts, sc.tables, W, h, tick)
        -- once raw, the line stays raw while the cursor stays on it at this
        -- window size (review WP-E F2: gj/gk walk its screen rows)
        local wt = ws.tall
        local stuck = wt ~= nil and wt.lnum == crow and wt.W == W and wt.h == h
        local tr, nofloat
        if tall and not stuck then tr, nofloat, vrem, vback = virtual_row(ws, win, buf, tbl, lay, r, k, popts, crow, W, h) end
        if tr then
          g = tr.g -- the highlighted grid: clips, markers and the header float use it
          above, below, arows = tr.above, tr.below, tr.rows
          cursor = { row = crow, sig = tostring(tr), marks = tr.marks }
          model.vrow = { lnum = crow, tbl = tbl, lay = lay, r = r, k = k, off = tr.off, proj = tr, ri = rinfo, nofloat = nofloat,
            note = tr.from_t > (g.sep[r] or g.first[r]) }
          -- scroll-to-fit: the row's grid from the line's first screen row
          -- (its separator) to its end; taller than the window, so the fit
          -- seats its top under the float (once per row: ws.fitted)
          local note = tr.from_t > (g.sep[r] or g.first[r]) and 1 or 0 -- the note above the row (vrow_hint)
          fitme = { lines_in_line = 0, sep_above = note, height = note + (g.sep[r] and 1 or 0) + g.count[r] + (r == #tbl.rows and 1 or 0),
            tall = true }
        elseif tall or stuck then
          -- the fallback: the line raw (Neovim would show the lower part of a
          -- line taller than the window with w_skipcol and "@@@"), the other
          -- rows virtual
          above = project.slice(g, 1, g.first[r] - 1)
          below = project.slice(g, g.first[r] + g.count[r], #g.lines)
          arows = math.ceil(math.max(vim.fn.strdisplaywidth(row.line), 1) / W)
          model.tall = { lnum = crow, rows = rinfo.rows, ri = rinfo, arows = arows }
        else
          if rprose then
            -- WP-I round 3: spill rows beyond the table's lines above carry
            -- the buffer lines above the table (concealed while the cursor is
            -- on this row): the text never moves by cell
            prose = rprose
            model.ext = { lnum = crow, rows = #ext.opts.ext, lines = #ext.lines, blank = ext.blank }
          end
          local cr = project.cursor_row(tbl, lay, r, k, ropts, rinfo.nl, rinfo.after)
          above, below = cr.above, cr.below
          cursor = { row = crow, sig = tostring(cr), marks = cr.marks }
          model.cursor = { tbl = tbl, lay = lay, r = r, k = k, lnum = crow, proj = cr, ri = rinfo }
          fitme, fitri, ri = cr, rinfo, rinfo
          min_keep, arows = #cr.extra + 1, cr.rows
        end
        model.active = { lnum = crow, r = r, k = k, tall = tr ~= nil }
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
    if prose and ri then
      for _, l in ipairs(prose) do
        marks[#marks + 1] = { key = "q" .. l, row = l, kind = "conceal" }
        concealed[l] = true
      end
    end
    local full_below = below
    -- the above block leaves room for the anchor line, one line and the
    -- marker below it and the line after the table: scrolled up to its top
    -- marker, the markers above and below the cursor row are both on screen
    local cap_a = math.max(1, math.min(m, h - arows - 3))
    -- a cursor row: the same grid lines kept above the row's own grid in
    -- every cell (#above + lines_in_line constant, so the same marker)
    -- (lines on the line itself cannot be clipped: room for the most of them
    -- and a marker)
    if ri then cap_a = math.max(1, math.min(m, math.max(h - 3 - ri.rl, ri.lil + 1) - model.cursor.proj.lines_in_line)) end
    -- (cursor row: clip cuts on the same grid lines in every cell, WP-I)
    local lim_a = ri and ri.lil - model.cursor.proj.lines_in_line or 0
    -- (a virtual row's note ends the block above while the row is not
    -- scrolled: not a row boundary for the cut, so the block keeps its rows)
    if model.vrow and model.vrow.tbl == tbl and model.vrow.note and model.vrow.off == 0 then lim_a = 1 end
    local lim_b = ri and ri.rl - (model.cursor.proj.rows - model.cursor.proj.lines_in_line) or 0
    local clip_a = #above > cap_a
    local hdr_whole -- the block kept whole instead of a header-only cut: it still depends on the view
    if clip_a then
      local cut = project.clip(g, tbl, above, cap_a, "above", lim_a)
      -- a cut that hides only the header row saves two lines, and the
      -- sticky float would cover its `… 1 more row …` with a blank grid
      -- row: keep the block whole while it is not too tall (m)
      if cut[1] == project.marker(g, tbl, 1) and #above <= m then clip_a, hdr_whole = false, true else above = cut end
    end
    local guess
    if #below > min_keep then -- measured after drawing: it may reach past the window bottom
      guess = math.min(m, math.max(bkeep[tbl.start_row] or m, min_keep))
      below = project.clip(g, tbl, full_below, guess, "below", lim_b)
    end
    clipdep = clipdep or clip_a or hdr_whole or guess ~= nil
    if anc.inside and row.kind == "body" and not (model.vrow and model.vrow.tbl == tbl and model.vrow.nofloat) then
      hctx = { g = g, tbl = tbl, A = anc.anchor, r = r, above = above, clipped = clip_a,
        lil = model.cursor and model.cursor.tbl == tbl and model.cursor.proj.lines_in_line or 0, ri = ri,
        tall = model.vrow ~= nil and model.vrow.tbl == tbl or nil }
    end
    if anc.inside and model.tall and model.tall.lnum == crow and not model.tall.anchor
        and vim.g.mdtable_cell_editor ~= false and vim.g.mdtable_tall_hint ~= false then
      -- the raw fallback (a line taller than the window): the same note
      -- right above it on every visit (i opens the float there too); after
      -- hctx: the sticky header's room is the grid lines
      above = vim.list_extend(vim.list_slice(above), { vrow_note(tbl.indent or 0) })
      model.tall.note = true
    end
    if #above > 0 then
      marks[#marks + 1] = { key = "a" .. tbl.start_row, row = anc.anchor, kind = "vl", above = true, lines = above,
        sig = project.block_sig(above) }
    end
    if #below > 0 then
      marks[#marks + 1] = { key = "b" .. tbl.start_row, row = anc.anchor, kind = "vl", lines = below,
        sig = project.block_sig(below) }
      if model.vrow and model.vrow.tbl == tbl then model.vrow.bmark = marks[#marks] end -- (vrow_rooms)
      if guess then
        bfix[#bfix + 1] = { d = marks[#marks], g = g, tbl = tbl, full = full_below, keep = guess, A = anc.anchor, min = min_keep,
          lim = lim_b }
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
  if hint_visit and not hint_visit.done and hint_visit.win == win
      and not (model.vrow and model.vrow.lnum == hint_visit.lnum and hint_visit.buf == buf) then
    hint_visit.done = true -- the first virtual-row visit is over: no note again this session
  end
  ws.tall = (model.tall and not model.tall.anchor) and { lnum = model.tall.lnum, W = W, h = h } or nil
  local C = draw.apply(buf, win, { marks = marks, cursor = cursor }, tick)
  ws.tick = tick
  ws.model = model
  local view = api.nvim_win_call(win, vim.fn.winsaveview)
  -- WP-I: a cell move in the cursor row with the cursor line at the window
  -- top. The line's spill rows above carry lines_in_line grid lines taken
  -- off its filler, so topfill follows: the row's first own grid line keeps
  -- its screen row (inherent limit: topfill 0; the fit keeps room for it). Before the
  -- below blocks' budget, which measures from this view.
  local lil = model.cursor and model.cursor.proj.lines_in_line or nil
  local pv, comp = ws.view, false
  if not reclip and lil and plil and plil ~= lil and ws.crow == crow and ptick == tick and pv
      and pv.topline - 1 == crow and (pv.skipcol or 0) == 0 then
    view.topline, view.topfill, comp = crow + 1, math.max(0, pv.topfill + plil - lil), true
  end
  ws.lil = lil
  if vrem and vrem > 0 and not reclip and view.topline - 1 == crow then
    -- a virtual row's scroll-back to the active cell, the view's part: more
    -- of the line's filler (the block above, the row's lines scrolled past)
    local nf = math.min(th(win, { start_row = crow, end_row = crow }).fill, view.topfill + vrem)
    if nf ~= view.topfill then view.topfill, comp = nf, true end
  end
  -- below blocks taller than the window: end them at the window bottom (in
  -- table order: a block that reaches the bottom puts later tables off screen)
  local nkeep = {}
  local function rebudget(v)
    for _, f in ipairs(bfix) do
      local k = budget(win, v, f.A, h, m, f.min, f.lim)
      nkeep[f.tbl.start_row] = k
      if k ~= f.keep then
        local lines = project.clip(f.g, f.tbl, f.full, k, "below", f.lim)
        f.d.lines, f.d.sig, f.keep = lines, project.block_sig(lines), k
        draw.update(buf, win, f.d)
      end
    end
  end
  rebudget(view)
  ws.bkeep, ws.clipdep = nkeep, clipdep
  if comp or C.set + C.updated + C.deleted + C.cursor > 0 then
    -- the marks changed line heights: drop Neovim's cached botline (it would
    -- otherwise scroll for the old layout when the cursor moved below it)
    api.nvim_win_call(win, function() vim.fn.winrestview({ topline = view.topline, topfill = view.topfill }) end)
    if comp then view = api.nvim_win_call(win, vim.fn.winsaveview) end
  end
  ws.hctx = hctx
  -- fitted once per row (WP-I: the fit holds for every cell of the row)
  ws.fit = fitme and { crow = crow, cr = fitme, ri = fitri, key = tick .. ":" .. crow .. ":" .. W .. ":" .. h } or nil
  if not opts.nofit and reanchor(win, ws, moved, view) then view = api.nvim_win_call(win, vim.fn.winsaveview) end
  ws.concealed, ws.crow = concealed, crow
  local v0 = view
  ws.view = settle(win, ws, h, view, not opts.nofit)
  -- scroll-to-fit moved the view: the below blocks end at the new window
  -- bottom (WP-I: the same cut as the following renders of the row)
  if #bfix > 0 and (ws.view.topline ~= v0.topline or ws.view.topfill ~= v0.topfill) then
    rebudget(ws.view)
    ws.bkeep = nkeep
  end
  local mt = model.tall
  if mt and mt.note and not mt.anchor and not reclip and mt.lnum == crow and mt.arows + 1 <= h
      and ws.view.topline - 1 == crow and ws.view.topfill == 0 and (ws.view.skipcol or 0) == 0 then
    -- the raw fallback's note: Neovim fits the line by hiding all of its
    -- filler; the line and the note fit, so show the note (one filler row)
    api.nvim_win_call(win, function() vim.fn.winrestview({ topline = crow + 1, topfill = 1 }) end)
    ws.view = settle(win, ws, h, nil, false)
    if #bfix > 0 then rebudget(ws.view); ws.bkeep = nkeep end
  end
  if model.vrow then
    vrow_rooms(win, ws, model.vrow, h)
    local vr = model.vrow
    if vback and not reclip and vr.vis_lo > vr.proj.first_t and ws.view.topline - 1 == crow then
      -- the scroll-back's target still under the float (the float grew by
      -- its clip marker with the new view): the rest of the same scroll
      local nf = math.min(th(win, { start_row = crow, end_row = crow }).fill, ws.view.topfill + vr.vis_lo - vr.proj.first_t)
      if nf > ws.view.topfill then
        api.nvim_win_call(win, function() vim.fn.winrestview({ topline = crow + 1, topfill = nf }) end)
        ws.view = settle(win, ws, h, nil, false)
        if #bfix > 0 then rebudget(ws.view); ws.bkeep = nkeep end
        vrow_rooms(win, ws, vr, h)
      end
    end
  end
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

-- WP-J: scroll inside the virtual cursor row of win (nav.lua: j/k, <C-d>/<C-u>
-- there) by n screen rows in direction dir (1: down); returns the rows
-- scrolled, fewer than n at the row's end (its last line on screen, or its
-- first line below the header float). While rows above the line are on
-- screen the view scrolls (filler first, then whole lines); then the in-row
-- offset moves the row's lines up through the line. Every step moves every
-- visible row by the same amount: a scroll, never a re-layout.
function M.tall_scroll(win, dir, n)
  win = (win == nil or win == 0) and api.nvim_get_current_win() or win
  local st = state[api.nvim_win_get_buf(win)]
  local ws = st and st.wins[win]
  local vr = ws and ws.model and ws.model.vrow
  if not (vr and ws.vrow and ws.vrow.lnum == vr.lnum and vr.room_down) then return 0 end
  local need = math.min(n, dir > 0 and vr.room_down or vr.room_up)
  if need <= 0 then return 0 end
  local A, off, done = vr.lnum, ws.vrow.off, 0
  local v = api.nvim_win_call(win, vim.fn.winsaveview)
  local nv = { topline = v.topline, topfill = v.topfill }
  local function fill(l) return th(win, { start_row = l, end_row = l }).fill end
  if dir > 0 then
    while done < need do
      if nv.topfill > 0 then
        local d = math.min(nv.topfill, need - done)
        nv.topfill, done = nv.topfill - d, done + d
      elseif nv.topline - 1 < A then
        local t = nv.topline - 1
        done = done + th(win, { start_row = t, end_row = t, start_vcol = 0 }).all
        nv.topline = nv.topline + 1
        nv.topfill = fill(nv.topline - 1)
      else
        off, done = off + need - done, need
      end
    end
  else
    local d = math.min(off, need)
    off, done = off - d, d
    if done < need and nv.topline - 1 == A then
      local e = math.min(fill(A) - nv.topfill, need - done)
      nv.topfill, done = nv.topfill + e, done + e
    end
  end
  if nv.topline ~= v.topline or nv.topfill ~= v.topfill then
    api.nvim_win_call(win, function() vim.fn.winrestview({ topline = nv.topline, topfill = nv.topfill, skipcol = 0 }) end)
  end
  ws.vrow.off = off
  M.render(win, { force = true, nofit = true })
  return math.min(done, need)
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

-- WP-J: the active cell of the current window and the tall rows (drawn
-- virtual while the cursor is on them) of its rendered tables.
function M.active_lines()
  local win = api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  local st = state[buf]
  local ws = st and st.wins[win]
  local m, d = ws and ws.model, ws and ws.dims
  if not (m and d and ws.scan) then return {} end
  local sp = vim.g.mdtable_spill
  local popts = { width = d.width, separators = seps_for(buf), tabstop = vim.bo[buf].tabstop,
    spill = (sp == "row" or sp == "cell") and sp or "flow" }
  local ntall, nrows = 0, 0
  for _, e in ipairs(m.tables) do
    for r, row in ipairs(e.tbl.rows) do
      if row.kind ~= "delim" and not row.ragged and #row.cells > 0 then
        nrows = nrows + 1
        if tall_of(ws, buf, e.tbl, e.lay, r, popts, ws.scan.tables, d.width, d.height, m.tick) then ntall = ntall + 1 end
      end
    end
  end
  local a = m.active
  local at = "none (the cursor is not in a table row)"
  if a then
    at = ("row %d, cell %d (line %d)"):format(a.r, a.k, a.lnum + 1)
    if a.tall and m.vrow then at = at .. (", virtual row, in-row scroll %d"):format(m.vrow.off) end
  end
  return { ("MdTable active cell: %s; tall rows: %d of %d rows in %d rendered table%s (window %dx%d)"):format(at, ntall, nrows,
    #m.tables, #m.tables == 1 and "" or "s", d.width, d.height) }
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
-- What WinScrolled does for one window (also called by tests/probe_vjitter.lua:
-- a probe running inside one Lua call never returns to the main loop, where
-- Neovim fires WinScrolled after its own scroll).
function M._on_scrolled(win)
  if rendering or not (win and api.nvim_win_is_valid(win)) then return end
  do -- (the WinScrolled callback body)
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
      ws.view = settle(win, ws, info.height, ws.view, false)
      if ws.model and ws.model.vrow then vrow_rooms(win, ws, ws.model.vrow, info.height) end
      stats.htimes = stats.htimes or {}
      stats.htimes[#stats.htimes + 1] = (uv.hrtime() - t0) / 1e6
      if #stats.htimes > 200 then table.remove(stats.htimes, 1) end
    end
  end
  end
end

api.nvim_create_autocmd("WinScrolled", {
  group = ag,
  callback = function()
    if rendering then return end
    for w in pairs(vim.v.event) do
      local win = tonumber(w)
      if win and api.nvim_win_is_valid(win) then M._on_scrolled(win) end
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
    print(table.concat(vim.list_extend(vim.list_extend({ M.stats_line() }, M.active_lines()), M.dims_lines()), "\n"))
  else
    vim.notify("MdTable: toggle|enable|disable|separators|header|edit|stats", vim.log.levels.ERROR)
  end
end, { nargs = "*", complete = function() return { "toggle", "enable", "disable", "separators", "header", "edit", "stats" } end })

return M
