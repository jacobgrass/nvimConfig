-- WP-J: rows taller than the window are virtual while the cursor is on them
-- (init.lua tall_of / virtual_row, project.tall_row): the active cell and its
-- header cell highlighted, Ctrl-hjkl and hjkl move the highlight or scroll
-- the row (nav.lua), the edit keys open the cell editor (test_celledit W1).
-- Runs in a child nvim with a UI of each size (tests/uidriver.lua).
local here = vim.fn.fnamemodify(_G.arg[0], ":p:h")
local H = dofile(here .. "/helpers.lua")
local D = dofile(here .. "/uidriver.lua")
local ONLY = os.getenv("ONLY")
D.timeout_ms = 120000

local function case(name, W, Hh, fn)
  if ONLY and not name:find(ONLY, 1, true) then return end
  H.run(name, function()
    local c = D.start(W, Hh + 1)
    local ok, err = xpcall(function()
      c.lua("_G.S = dofile(...); _G.M = require('custom.mdtable'); M._reset_hint()", here .. "/screen.lua")
      fn(c)
      local msgs = c.lua("return vim.fn.execute('messages')")
      H.ok(not msgs:find("E%d+:") and not msgs:find("rror"), "no errors in :messages: " .. msgs)
      H.eq({}, c.lua("return S.errors()"), "no mdtable errors")
    end, debug.traceback)
    c.stop()
    if not ok then error(err, 0) end
  end)
end

-- child helpers: the virtual row's state, the screen and hl attrs
local INIT = [=[
function _G.VR()
  local m = M._last_model(0)
  local v, w = m.vrow, vim.fn.winsaveview()
  local c = M.logical_cursor(0) -- (WP-K: the active row while parked)
  if not v then return { virtual = false, raw = m.tall ~= nil, line = c[1] - 1, k = m.active and m.active.k or 0 } end
  return { virtual = true, raw = m.tall ~= nil, line = c[1] - 1, k = v.k, r = v.r, off = v.off, s = v.proj.s,
    first = v.proj.first_t, last = v.proj.last_t, pre = v.pre, res = v.reserve, vis_lo = v.vis_lo, vis_hi = v.vis_hi,
    down = v.room_down, up = v.room_up, topline = w.topline, topfill = w.topfill }
end
-- the chunk of tape line i covering grid column x: its hl group
local function hl_at(line, x)
  local col = 0
  for _, ch in ipairs(line) do
    local w = vim.api.nvim_strwidth(ch[1])
    if x >= col and x < col + w then return ch[2] end
    col = col + w
  end
end
-- hl groups of the active row's first line and the header's first line at
-- every cell's content start (model chunks, what draw.lua puts on screen)
function _G.CHUNK_HL()
  local m = M._last_model(0)
  local v = m.vrow
  local g = v.proj.g
  local row, head = {}, {}
  for k = 1, #v.tbl.rows[v.r].cells do
    row[k] = hl_at(g.lines[g.first[v.r]], g.left[k])
    head[k] = hl_at(g.lines[g.first[1]], g.left[k])
  end
  return { row = row, head = head }
end
-- screen attrs at the content start of every cell on the active row's
-- first screen line and on the header's first screen line (the real header
-- or the sticky float: the first line under the first top border)
function _G.SCREEN_ATTR()
  vim.cmd("redraw!")
  local m = M._last_model(0)
  local v = m.vrow
  local e
  for _, x in ipairs(m.tables) do if x.tbl == v.tbl then e = x end end
  local g = M.grid(e)
  local info = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
  local rrow = info.winrow + v.pre + (v.proj.first_t - v.proj.s)
  local hrow
  for r = info.winrow, info.winrow + info.height - 1 do
    if vim.fn.screenstring(r, info.wincol + info.textoff + (v.tbl.indent or 0)) == "┌" then hrow = r + 1; break end
  end
  local row, head = {}, {}
  for k = 1, #v.tbl.rows[v.r].cells do
    local col = info.wincol + info.textoff + g.left[k]
    row[k] = vim.fn.screenattr(rrow, col)
    head[k] = hrow and vim.fn.screenattr(hrow, col) or -1
  end
  return { row = row, head = head, rrow = rrow, hrow = hrow or -1 }
end
-- the table's grid lines on screen (the float rows and markers blanked)
function _G.GRID()
  local rows = S.screen(0)
  local v = M._last_model(0).vrow
  local res = v and v.reserve or 0
  for i, s in ipairs(rows) do
    if i <= res or S.is_marker(s) or not s:find("│", 1, true) then rows[i] = "" end
  end
  return rows
end
function _G.KEY(k) vim.api.nvim_input(k); return vim.api.nvim_eval("1") end
]=]

local function key(c, k) c.request("nvim_input", k); c.request("nvim_eval", "1") end
local function setup(c, fx)
  c.lua("_G.BUF, _G.WIN = S.open(...)", fx)
  c.lua(INIT)
end
-- B is A shifted by d rows (B[i] == A[i - d]) on every grid row both show
local function shifted(A, B, d)
  local n = 0
  for i = 1, #B do
    local a = A[i - d]
    if a and a ~= "" and B[i] ~= "" then
      if a ~= B[i] then return false, ("row %d: %q ~= row %d %q"):format(i, B[i], i - d, a) end
      n = n + 1
    end
  end
  return n > 3, "rows compared: " .. n
end

-- needs-live: the header fits, every body row is taller than the window
for _, sz in ipairs({ { 120, 45 }, { 100, 30 }, { 97, 31 } }) do
  local W, Hh = sz[1], sz[2]
  case(("T1 needs-live %dx%d: highlight on the active cell and its header (chunks and screen); Ctrl-hjkl, h/l; entering and leaving from the header"):format(W, Hh), W, Hh, function(c)
    setup(c, "needs-live.md")
    -- the header row (0-based line 7) is drawn in place; Ctrl-j enters the first body row (line 9)
    c.lua("M.goto(0, 7, S.vis_col(7, 3))")
    local v = c.lua("return VR()")
    H.eq({ false, false, 3 }, { v.virtual, v.raw, v.k }, "header: in place, cell 3")
    key(c, "<C-j>")
    v = c.lua("return VR()")
    H.eq({ true, false, 9, 3, 0 }, { v.virtual, v.raw, v.line, v.k, v.off }, "Ctrl-j into a tall row: virtual, the same column")
    local ch = c.lua("return CHUNK_HL()")
    for k = 1, #ch.row do
      H.eq(k == 3 and "MdTableActiveCell" or "Normal", ch.row[k], "row chunk hl, cell " .. k)
      H.eq(k == 3 and "MdTableActiveCol" or "@markup.heading", ch.head[k], "header chunk hl, cell " .. k)
    end
    local a = c.lua("return SCREEN_ATTR()")
    H.ok(a.hrow > 0, "header on screen (real or float)")
    for k = 1, #a.row do
      if k ~= 3 then
        H.ok(a.row[k] ~= a.row[3], ("screen: active cell 3 attr %d differs from cell %d attr %d"):format(a.row[3], k, a.row[k]))
        H.ok(a.head[k] ~= a.head[3], ("screen: header cell 3 attr %d differs from header cell %d attr %d"):format(a.head[3], k, a.head[k]))
      end
    end
    local act, other, hact = a.row[3], a.row[1], a.head[3]
    local g0 = c.lua("return GRID()")
    -- Ctrl-l, l: the highlight moves, nothing else on screen changes
    for i, kk in ipairs({ { "<C-l>", 4 }, { "l", 5 }, { "<C-h>", 4 }, { "h", 3 } }) do
      key(c, kk[1])
      v = c.lua("return VR()")
      H.eq({ 9, kk[2], true }, { v.line, v.k, v.virtual }, kk[1] .. ": active cell")
      a = c.lua("return SCREEN_ATTR()")
      H.eq({ act, hact }, { a.row[kk[2]], a.head[kk[2]] }, kk[1] .. ": the highlight on cell " .. kk[2])
      H.eq(other, a.row[1], kk[1] .. ": cell 1 not highlighted")
      H.eq(g0, c.lua("return GRID()"), kk[1] .. " (step " .. i .. "): the screen text did not change")
    end
    -- the row's edges, as from a row drawn in place (review F1): Ctrl-h on
    -- the first cell goes to the previous row's last cell (the header, in
    -- place: the real cursor there), Ctrl-l on the last cell to the next
    -- row's first cell (a tall row: its active cell)
    local nc = c.lua("return #M._last_model(0).vrow.tbl.rows[M._last_model(0).vrow.r].cells")
    for _ = 1, 2 do key(c, "<C-h>") end
    v = c.lua("return VR()")
    H.eq({ true, 9, 1 }, { v.virtual, v.line, v.k }, "Ctrl-h to the row's first cell")
    key(c, "<C-h>")
    v = c.lua("return VR()")
    H.eq({ false, false, 7, nc }, { v.virtual, v.raw, v.line, v.k }, "Ctrl-h on the first cell: the header's last cell, in place")
    H.ok(c.lua("local m = M._last_model(0); return m.cursor ~= nil and m.cursor.k == " .. nc), "the real cursor in that cell")
    key(c, "<C-l>")
    v = c.lua("return VR()")
    H.eq({ true, 9, 1 }, { v.virtual, v.line, v.k }, "Ctrl-l on the header's last cell: the tall row's first cell")
    for _ = 1, nc - 1 do key(c, "l") end
    v = c.lua("return VR()")
    H.eq({ true, 9, nc }, { v.virtual, v.line, v.k }, "l to the row's last cell")
    key(c, "l")
    v = c.lua("return VR()")
    H.eq({ true, 9, nc }, { v.virtual, v.line, v.k }, "l on the last cell stays in the row (as h/l in a row drawn in place)")
    key(c, "<C-l>")
    v = c.lua("return VR()")
    H.eq({ true, 10, 1 }, { v.virtual, v.line, v.k }, "Ctrl-l on the last cell: the next (tall) row's first cell")
    key(c, "<C-h>")
    v = c.lua("return VR()")
    H.eq({ true, 9, nc }, { v.virtual, v.line, v.k }, "Ctrl-h on its first cell: back to the last cell")
    -- Ctrl-k back to the header: the real cursor in that cell (in place)
    key(c, "<C-k>")
    v = c.lua("return VR()")
    H.eq({ false, 7, nc }, { v.virtual, v.line, v.k }, "Ctrl-k to the header: in place, the same cell")
    -- Ctrl-j / Ctrl-k between two tall rows keep the column
    key(c, "<C-j>"); key(c, "<C-j>")
    v = c.lua("return VR()")
    H.eq({ true, 10, nc }, { v.virtual, v.line, v.k }, "Ctrl-j from a tall row to the next: the same column")
    H.eq({}, c.lua("return S.check(S.screen(0), 0)"), "aligned")
    -- :MdTable stats: active cell and tall rows
    local st = c.lua("return vim.fn.execute('MdTable stats')")
    H.ok(st:find(("active cell: row 4, cell %d (line 11), virtual row"):format(nc), 1, true), "stats: active cell\n" .. st)
    H.ok(st:find("tall rows: 4 of 5 rows", 1, true), "stats: tall rows\n" .. st)
  end)

  case(("T2 needs-live %dx%d: j/k scroll the row one screen row at a time (a uniform scroll), leave it at its ends; Ctrl-d/u; a cell off screen scrolls back uniformly"):format(W, Hh), W, Hh, function(c)
    setup(c, "needs-live.md")
    -- the last body row (line 12): the tallest
    c.lua("M.goto(0, 12, S.vis_col(12, 1))")
    -- its longest cell and its shortest
    local kk = c.lua([[local v = M._last_model(0).vrow; local lr = v.lay.rows[v.r]; local best, short, nb, ns = 1, 1, -1, math.huge
      for k, cl in ipairs(lr.cells) do local n = 0; for _, ch in ipairs(cl.chunks) do if not ch.fill then n = n + 1 end end
        if n > nb then best, nb = k, n end; if n < ns then short, ns = k, n end end
      return { best, nb, short, ns }]])
    c.lua("M.goto(0, 12, S.vis_col(12, ...))", kk[1])
    local v = c.lua("return VR()")
    H.ok(v.virtual and v.k == kk[1], "on the longest cell " .. kk[1])
    H.ok(v.down > 5, "the row has rows below the screen: " .. v.down)
    local steps = 0
    while true do
      local A, v0 = c.lua("return GRID()"), c.lua("return VR()")
      if v0.down == 0 then break end
      key(c, "j")
      local B, v1 = c.lua("return GRID()"), c.lua("return VR()")
      steps = steps + 1
      H.eq({ 12, true }, { v1.line, v1.virtual }, "j " .. steps .. ": on the row")
      H.eq(v0.down - 1, v1.down, "j " .. steps .. ": one row scrolled")
      local ok, why = shifted(A, B, -1)
      H.ok(ok, "j " .. steps .. ": every grid row moved up one: " .. why)
      if steps > 80 then error("no end") end
    end
    H.ok(steps > 5, "scrolled " .. steps .. " rows")
    -- Ctrl-u, Ctrl-d: half a window (the row's top / end clamp)
    local u0 = c.lua("return VR()").up
    key(c, "<C-u>")
    local half = math.floor(Hh / 2)
    H.eq(math.max(u0 - half, 0), c.lua("return VR()").up, "Ctrl-u scrolled half a window up")
    key(c, "<C-d>")
    H.eq(0, c.lua("return VR()").down, "Ctrl-d back to the row's end")
    -- the shortest cell's lines are above the screen now: Ctrl-l/Ctrl-h to it
    -- scroll back uniformly (only when needed); every other step changes no text
    local vnow = c.lua("return VR()")
    H.ok(vnow.vis_lo > vnow.first + kk[4] - 1, "the short cell's lines are off screen")
    local dir = kk[3] > kk[1] and "<C-l>" or "<C-h>"
    for i = 1, math.abs(kk[3] - kk[1]) do
      local A, v0 = c.lua("return GRID()"), c.lua("return VR()")
      key(c, dir)
      local B, v1 = c.lua("return GRID()"), c.lua("return VR()")
      local d = (v0.s - v0.pre) - (v1.s - v1.pre) -- (tape index at the window top: the float may come or go)
      local ok, why = shifted(A, B, d)
      if d == 0 then
        H.eq(A, B, dir .. " " .. i .. ": the screen text did not change")
      elseif math.abs(d) < Hh - 6 then -- (a longer scroll leaves no row on screen to compare)
        H.ok(ok, dir .. " " .. i .. ": a uniform scroll by " .. d .. ": " .. why)
      end
      H.eq(12, v1.line, dir .. " " .. i .. ": on the row")
    end
    v = c.lua("return VR()")
    H.eq(kk[3], v.k, "on the short cell")
    H.ok(v.vis_lo <= v.first + kk[4] - 1, "its lines are on screen: " .. vim.inspect(v, { newline = " " }))
    -- k to the top, then k leaves the row (the previous row, the same cell)
    local n = 0
    while c.lua("return VR()").up > 0 and n < 80 do key(c, "k"); n = n + 1 end
    key(c, "k")
    v = c.lua("return VR()")
    H.eq({ 11, kk[3] }, { v.line, v.k }, "k at the row's top: the previous row, the same cell")
    -- j at the end of the last row leaves the table
    c.lua("M.goto(0, 12, S.vis_col(12, 1))")
    n = 0
    while c.lua("return VR()").down > 0 and n < 80 do key(c, "j"); n = n + 1 end
    key(c, "j")
    -- (the table ends the file: no line to leave to, j clamps as on a row drawn in place)
    H.eq({ 12, true, 0 }, { c.lua("return LL() - 1"), c.lua("return VR()").virtual, c.lua("return VR()").down },
      "j at the end of the last row, the table at EOF: clamped, still at the row's end")
  end)
end

-- WP-K: rows whose bytes do not fit the window (7x500, 7x700) are parked:
-- the real cursor on the delimiter (the park line), the row virtual and its
-- active cell highlighted; edits act on the active row
for _, sz in ipairs({ { 100, 30 }, { 80, 24 } }) do
  local W, Hh = sz[1], sz[2]
  case(("T4 huge.md %dx%d: parked rows: active cell, cell move marks and CPU, float, o/O, dd/yy/p, u, x, V, raw jumps"):format(W, Hh), W, Hh, function(c)
    setup(c, "huge.md")
    local P = "local p = M.park_of(0); return p and { p.plnum, p.lnum, p.k } or false"
    c.lua("M.goto(0, 7, S.vis_col(7, 2))")
    H.eq({ 5, 7, 2 }, c.lua(P), "parked on the delimiter (line 5), active row line 7, cell 2")
    local v = c.lua("return VR()")
    H.eq({ true, false, 7, 2, 6 }, { v.virtual, v.raw, v.line, v.k, c.lua("return vim.fn.line('.')") }, "virtual, not raw; line('.') is the park line")
    H.eq({}, c.lua("return S.check(S.screen(0), 0)"), "aligned, no raw row")
    H.ok(c.lua("return vim.fn.execute('MdTable stats')"):find("cursor parked on line 6", 1, true), "stats: the park line")
    -- a cell move: highlight marks only (<= 4 mark writes), < 1 ms CPU
    local mv = c.lua([[local nav, out, marks = require('custom.mdtable.nav'), {}, 0
      for i = 1, 8 do
        local t0 = vim.uv.hrtime(); nav.run(i % 2 == 1 and 10 or 9, 0); out[#out + 1] = (vim.uv.hrtime() - t0) / 1e6
        local m = M.stats.marks; marks = math.max(marks, m.set + m.updated + m.deleted + m.cursor)
      end
      table.sort(out); return { out[4], marks, M.park_of(0) and M.park_of(0).k or 0 }]])
    print(("PERF %dx%d parked cell move: median %.3f ms, at most %d mark writes"):format(W, Hh, mv[1], mv[2]))
    H.ok(mv[2] <= 4, "cell move mark writes <= 4: " .. mv[2])
    H.ok(mv[1] < 1.0, ("cell move CPU %.3f ms < 1.0 ms"):format(mv[1]))
    H.eq(2, mv[3], "back on cell 2")
    local L = function(n) return c.lua("local l = ...; return vim.api.nvim_buf_get_lines(0, l, l + 1, false)[1]", n) end
    local n0, line7 = c.lua("return vim.api.nvim_buf_line_count(0)"), L(7)
    -- i: the float on the active cell; the apply writes that cell of line 7
    key(c, "i")
    H.eq({ 7, 2 }, c.lua("local s = require('custom.mdtable.celledit').state(); return { s.lnum, s.k }"), "i: the float on line 7 cell 2")
    key(c, "Q"); key(c, "<Esc>"); key(c, "<CR>")
    local s2 = c.lua("return require('custom.mdtable.scan').tables(0, 7, 8)[1].rows[4].cells[2].s")
    H.eq(line7:sub(1, s2) .. "Q" .. line7:sub(s2 + 1), L(7), "exact bytes: Q at cell 2's start of line 7")
    H.eq({ 5, 7, 2 }, c.lua(P), "parked again on the same cell")
    key(c, "u")
    H.eq(line7, L(7), "u restores line 7")
    -- x: the float in normal mode, nothing deleted
    c.lua("M.goto(0, 7, S.vis_col(7, 2))")
    key(c, "x")
    H.eq({ true, "n" }, c.lua("return { require('custom.mdtable.celledit').is_open(), vim.api.nvim_get_mode().mode }"), "x: the float, normal mode")
    key(c, "q")
    H.eq(line7, L(7), "x deleted nothing")
    -- o / O: a line after / before the active row, un-parked onto it
    key(c, "o")
    H.eq({ 8, "i", n0 + 1 }, { c.lua("return vim.fn.line('.') - 1"), c.lua("return vim.api.nvim_get_mode().mode"), c.lua("return vim.api.nvim_buf_line_count(0)") }, "o: a new line 8, insert mode")
    key(c, "<Esc>"); key(c, "u")
    H.eq({ n0, line7 }, { c.lua("return vim.api.nvim_buf_line_count(0)"), L(7) }, "u removes it")
    c.lua("M.goto(0, 7, S.vis_col(7, 2))")
    key(c, "O")
    H.eq({ 7, "i", line7 }, { c.lua("return vim.fn.line('.') - 1"), c.lua("return vim.api.nvim_get_mode().mode"), L(8) }, "O: a new line 7 before the active row")
    key(c, "<Esc>"); key(c, "u")
    H.eq({ n0, line7 }, { c.lua("return vim.api.nvim_buf_line_count(0)"), L(7) }, "u removes it")
    -- yy p: the active row copied below it; dd: the active row deleted; u
    c.lua("M.goto(0, 7, S.vis_col(7, 2))")
    key(c, "yy"); key(c, "p")
    H.eq({ n0 + 1, line7, line7 }, { c.lua("return vim.api.nvim_buf_line_count(0)"), L(7), L(8) }, "yy p: line 7 pasted as line 8")
    key(c, "u")
    c.lua("M.goto(0, 7, S.vis_col(7, 2))")
    local line8 = L(8)
    key(c, "dd")
    H.eq({ n0 - 1, line8 }, { c.lua("return vim.api.nvim_buf_line_count(0)"), L(7) }, "dd: line 7 deleted")
    key(c, "u")
    H.eq({ n0, line7 }, { c.lua("return vim.api.nvim_buf_line_count(0)"), L(7) }, "u restores it")
    -- V: the active row's line selected (raw while visual), Esc parks again
    c.lua("M.goto(0, 7, S.vis_col(7, 2))")
    key(c, "V")
    H.eq({ "V", 8, 8 }, { c.lua("return vim.api.nvim_get_mode().mode"), c.lua("return vim.fn.line('v')"), c.lua("return vim.fn.line('.')") }, "V selects line 8 (1-based)")
    key(c, "<Esc>")
    H.eq(5, c.lua("local p = M.park_of(0); return p and p.plnum or -1"), "parked again after visual")
    -- raw jumps onto a huge row park on it: :N, G (the last row), nvim_win_set_cursor
    c.lua("M.goto(0, 0, 0)")
    key(c, ":10<CR>")
    H.eq({ 5, 9, 1 }, c.lua(P), ":10 parks with line 10's row active, cell 1")
    key(c, "G")
    v = c.lua("return VR()")
    H.eq({ 13, false }, { v.line, v.virtual }, "G: the last line, outside the table")
    c.lua("vim.api.nvim_win_set_cursor(0, { 12, 0 }); M.render(0)")
    H.eq({ 5, 11, 1 }, c.lua(P), "nvim_win_set_cursor onto line 12: parked with it active (no relocation)")
    H.eq({}, c.lua("return S.check(S.screen(0), 0)"), "aligned")
  end)
end

-- WP-K review: on a parked row no key edits the park line; J, >>, << act
-- on the active row's line, the editing keys open the float, the rest are
-- a no-op with a notice
case("T5 huge.md 100x30 parked: C S D r R X J >> << == ~ guu gUU g~~ gJ . d gu > = <C-a> and a macro never touch the park line", 100, 30, function(c)
  setup(c, "huge.md")
  local L = function(n) return c.lua("local l = ...; return vim.api.nvim_buf_get_lines(0, l, l + 1, false)[1]", n) end
  local park0, row0, n0 = L(5), L(7), c.lua("return vim.api.nvim_buf_line_count(0)")
  local function park(tag)
    c.lua("M.goto(0, 7, S.vis_col(7, 2))")
    H.eq({ 5, 7 }, c.lua("local p = M.park_of(0); return p and { p.plnum, p.lnum } or false"), tag .. ": parked on line 5, row 7 active")
  end
  local function same(tag)
    H.eq(park0, L(5), tag .. ": the park line is byte-identical")
    H.eq({ row0, n0 }, { L(7), c.lua("return vim.api.nvim_buf_line_count(0)") }, tag .. ": the active row restored")
  end
  -- the float keys: the editor on the active cell, the key run there; q discards
  for _, k in ipairs({ { "C", "<Esc>" }, { "S", "<Esc>" }, { "D" }, { "rZ" }, { "RZZ", "<Esc>" }, { "X" } }) do
    park(k[1])
    key(c, k[1])
    H.eq({ true, 7, 2 }, c.lua("local s = require('custom.mdtable.celledit').state(); return { s ~= nil, s and s.lnum or -1, s and s.k or -1 }"), k[1] .. ": the float on the active cell")
    if k[2] then key(c, k[2]) end
    key(c, "q")
    same(k[1])
  end
  -- the row keys: on the active row's line (u restores)
  for _, k in ipairs({ { ">>", function(l) return l == "  " .. row0 end }, { "==", function(l) return l == row0 or l:match("^%s*") ~= nil end },
      { "~", function(l) return l ~= row0 and #l == #row0 end }, { "gUU", function(l) return l == row0:upper() end },
      { "guu", function(l) return l == row0:lower() end }, { "g~~", function(l) return #l == #row0 end },
      { "J", function(l) return l:sub(1, #row0) == row0 and #l > #row0 end }, { "gJ", function(l) return l:sub(1, #row0) == row0 and #l > #row0 end } }) do
    park(k[1])
    key(c, k[1])
    H.eq(park0, L(5), k[1] .. ": the park line is byte-identical")
    H.ok(k[2](L(7)), k[1] .. ": acted on the active row's line: " .. L(7):sub(1, 40))
    key(c, "u")
    same(k[1] .. " u")
  end
  park("<<")
  key(c, ">>"); key(c, "<LT><LT>") -- (nvim_input: a literal < is <LT>)
  H.eq({ park0, row0 }, { L(5), L(7) }, ">> then <<: the active row back, the park line untouched")
  key(c, "u"); key(c, "u")
  -- the blocked keys: a no-op and a notice
  c.lua("vim.cmd('normal! 3G'); vim.cmd('normal! x'); M.goto(0, 7, S.vis_col(7, 2))") -- (a change for . to repeat)
  local text3 = L(2)
  for _, k in ipairs({ ".", "dw", "guw", ">j", "=j", "<C-a>", "&" }) do
    park(k)
    key(c, k)
    H.eq(park0, L(5), k .. ": the park line is byte-identical")
    H.eq(row0, L(7), k .. ": the active row untouched")
  end
  H.ok(vim.tbl_contains(c.lua("local t = {} for _, n in ipairs(S.notes) do t[#t + 1] = n.msg end return t"), "parked row: edit in the float"), "the notice")
  -- a macro of line edits replayed while parked
  park("macro")
  c.lua("vim.fn.setreg('q', 'x.D>>J')")
  -- (its x opens the float, the rest runs there; q discards it)
  key(c, "@q")
  H.ok(c.lua("return require('custom.mdtable.celledit').is_open()"), "@q: x opened the float, the macro ran in it")
  key(c, "q")
  H.eq(park0, L(5), "@q: the park line is byte-identical")
  H.eq(row0, L(7), "@q: the active row untouched (discarded)")
  H.eq(text3, L(2), "the earlier line untouched")
end)

-- WP-K review: an audit against :help normal-index. Every normal-mode key
-- that changes or yanks the cursor line, pressed on a parked row, leaves
-- the park line byte-identical (they open the float, act on the active row
-- or do nothing). Passed through on purpose (not asserted): u, U, <C-r>,
-- q, motions and Ex commands. Then the review's cases: P (linewise,
-- charwise), "ap, v / <C-v> / v l l d, Y, :MdTable disable, :enew + :b#.
case("T6 huge.md 100x30 parked: normal-index audit of line-editing keys; P \"ap v <C-v> Y act on the active row; disable and :b# leave the cursor on it", 100, 30, function(c)
  setup(c, "huge.md")
  local orig = c.lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)")
  local L = function(n) return c.lua("local l = ...; return vim.api.nvim_buf_get_lines(0, l, l + 1, false)[1]", n) end
  local P = "local p = M.park_of(0); return p and { p.plnum, p.lnum } or false"
  local park0, row0 = L(5), L(7)
  local col = c.lua("return S.vis_col(7, 2)")
  local function reset(tag)
    c.lua([[local o = ...; local ce = require('custom.mdtable.celledit'); if ce.is_open() then ce.close(false) end]], orig)
    key(c, "<Esc>")
    c.lua("local o = ...; vim.api.nvim_buf_set_lines(0, 0, -1, false, o); M.goto(0, 7, S.vis_col(7, 2))", orig)
    H.eq({ 5, 7 }, c.lua(P), tag .. ": parked on line 5, row 7 active")
  end
  c.lua("vim.cmd('normal! 3G'); vim.cmd('normal! x'); vim.fn.histadd(':', 's/Rows/ROWS/')") -- (a change for ., a cmdline for @:)
  orig = c.lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)")
  local AUDIT = { "x", "X", "<Del>", "D", "C", "S", "s", "cw", "cc", "dw", "dd", "J", "gJ", "rZ", "RZ", "grZ", "gRZ", "~",
    "g~w", "g~~", "g~g~", "guw", "guu", "gugu", "gUw", "gUU", "gUgU", "g?w", "g??", "g?g?", ">j", ">>", "<LT>j", "<LT><LT>",
    "=j", "==", "<C-a>", "<C-x>", "p", "P", "]p", "[p", "]P", "[P", "zp", "zP", "gp", "gP", "&", "g&", ".", "@:", "!!",
    "!j", "gqq", "gqj", "gww", "gwj", "zyw", "zfj", "gcc", "gcj", "i", "a", "I", "A", "o", "O", "gi", "gI", "<Insert>",
    "vd", "vlld", "Vd", "<C-v>d", "gvd", "ghx", "yw", "yy", "Y" }
  for _, k in ipairs(AUDIT) do
    reset(k)
    key(c, k)
    c.lua("local ce = require('custom.mdtable.celledit'); if ce.is_open() then ce.close(false) end")
    key(c, "<Esc>")
    H.eq(park0, L(5), k .. ": the park line is byte-identical")
  end
  -- P: linewise after yy (the row above the active row), charwise into the active row
  reset("P")
  key(c, "yy"); key(c, "P")
  H.eq({ park0, row0, row0, #orig + 1 }, { L(5), L(7), L(8), c.lua("return vim.api.nvim_buf_line_count(0)") }, "yy P: the row pasted above the active row")
  reset("charwise P")
  c.lua("vim.fn.setreg('a', 'XY', 'c')")
  key(c, '"aP')
  H.eq({ park0, row0:sub(1, col) .. "XY" .. row0:sub(col + 1) }, { L(5), L(7) }, '"aP: XY inserted in the active row at its cell')
  reset('"ap')
  c.lua("vim.fn.setreg('a', { 'NEWLINE' }, 'l'); vim.fn.setreg('\"', { 'WRONG' }, 'l')")
  key(c, '"ap')
  H.eq({ park0, row0, "NEWLINE" }, { L(5), L(7), L(8) }, '"ap: register a pasted below the active row')
  -- v / <C-v>: the selection on the active row (raw while visual), then parked again
  for _, k in ipairs({ { "vd", 1 }, { "<C-v>d", 1 }, { "vlld", 3 } }) do
    reset(k[1])
    key(c, k[1])
    H.eq({ park0, row0:sub(1, col) .. row0:sub(col + 1 + k[2]) }, { L(5), L(7) }, k[1] .. ": " .. k[2] .. " character(s) of the active row deleted")
    H.eq({ 5, 7 }, c.lua(P), k[1] .. ": parked again")
  end
  -- Ex commands with the default range act on the active row
  reset(":s")
  key(c, ":s/e/E/<CR>")
  H.eq({ park0, (row0:gsub("e", "E", 1)) }, { L(5), L(7) }, ":s/e/E/: the active row changed, the park line untouched")
  H.eq({ 5, 7 }, c.lua(P), ":s: parked again")
  reset(":d")
  key(c, ":d<CR>")
  H.eq({ park0, orig[9], #orig - 1 }, { L(5), L(7), c.lua("return vim.api.nvim_buf_line_count(0)") }, ":d: the active row deleted, the park line untouched")
  reset("Y")
  key(c, "Y")
  H.eq(row0 .. "\n", c.lua("return vim.fn.getreg('\"')"), "Y yanks the active row")
  -- :MdTable disable and :enew / :b# leave the real cursor on the active row
  reset("disable")
  c.lua("vim.cmd('MdTable disable')")
  H.eq(8, c.lua("return vim.fn.line('.')"), ":MdTable disable: the cursor on the active row's line")
  c.lua("vim.cmd('MdTable enable')")
  reset(":b#")
  c.lua("vim.cmd('enew'); vim.cmd('b#')")
  H.eq(8, c.lua("return LL()"), ":enew :b#: back on the active row")
end)

case("T3 in-row scroll CPU < 0.5 ms median (draw only; needs-live 120x45, the last row)", 120, 45, function(c)
  setup(c, "needs-live.md")
  c.lua("M.goto(0, 12, S.vis_col(12, 1))")
  local t = c.lua([[local win = vim.api.nvim_get_current_win(); local out = {}
    for i = 1, 40 do
      local dir = (i <= 20) and 1 or -1
      local t0 = vim.uv.hrtime(); M.tall_scroll(win, dir, 1); out[#out + 1] = (vim.uv.hrtime() - t0) / 1e6
    end
    table.sort(out); return { out[20], out[40] }]])
  print(("PERF in-row scroll (M.tall_scroll, one row): median %.3f ms, max %.3f ms"):format(t[1], t[2]))
  H.ok(t[1] < 0.5, ("in-row scroll median %.3f ms < 0.5 ms"):format(t[1]))
  -- Ctrl-l / Ctrl-h on the virtual row (nav.run: the move and its render)
  local tl = c.lua([[local nav, out = require('custom.mdtable.nav'), {}
    for i = 1, 12 do
      local t0 = vim.uv.hrtime(); nav.run(i <= 6 and 10 or 9, 0); out[#out + 1] = (vim.uv.hrtime() - t0) / 1e6
    end
    table.sort(out); return { out[6], out[12], M._last_model(0).vrow ~= nil }]])
  print(("PERF Ctrl-l/Ctrl-h on a virtual row (nav.run incl. render): median %.3f ms, max %.3f ms"):format(tl[1], tl[2]))
  H.ok(tl[3], "still on the virtual row")
  H.ok(tl[1] < 1.5, ("Ctrl-l median %.3f ms < 1.5 ms (the cursor-move budget)"):format(tl[1]))
end)

H.done()
