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
  local c = vim.api.nvim_win_get_cursor(0)
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
    H.eq({ 12, true, 0 }, { c.lua("return vim.fn.line('.') - 1"), c.lua("return VR()").virtual, c.lua("return VR()").down },
      "j at the end of the last row, the table at EOF: clamped, still at the row's end")
  end)
end

-- review: the raw fallback (a line taller than the window minus 3 rows,
-- here 28 screen rows at 100x30) shows the note right above it; i opens the
-- editor there; x on a virtual row opens it (normal mode) and deletes nothing
case("T4 100x30: raw fallback row: the note above it, i opens the float; x on a virtual row deletes nothing", 100, 30, function(c)
  local long = (("lorem ipsum dolor sit amet "):rep(110)):sub(1, 2720)
  setup(c, { "# t", "", "| a | b | c | d | e | f | g |", "|---|---|---|---|---|---|---|", "| a | b | c | d | e | f | " .. long .. " |",
    "| 1 | 2 | 3 | 4 | 5 | 6 | 7 |", "", "after" })
  c.lua("M.goto(0, 4, S.vis_col(4, 2))")
  local v = c.lua("return VR()")
  H.eq({ false, true }, { v.virtual, v.raw }, "the row is drawn raw (its line does not fit the window)")
  local rows = c.lua("return S.screen(0)")
  local at
  for i, s in ipairs(rows) do if s:find(M_HINT or "tall row: Ctrl-hjkl select a cell, i edits in a float", 1, true) then at = i end end
  H.ok(at, "the note on screen\n" .. table.concat(rows, "\n") .. "\n" .. vim.inspect(c.lua("local v = vim.fn.winsaveview(); return { v.topline, v.topfill, v.skipcol, vim.fn.line('.') }")))
  H.ok(rows[at + 1]:match("^|"), "right above the raw row: " .. tostring(rows[at + 1]))
  H.eq({}, c.lua("return S.check(S.screen(0), 1)"), "aligned (one raw row)")
  key(c, "i")
  H.eq({ true, 2, "i" }, c.lua("local s = require('custom.mdtable.celledit').state(); return { s ~= nil, s and s.k or 0, vim.api.nvim_get_mode().mode }"),
    "i opens the editor on cell 2, insert mode")
  key(c, "<Esc>"); key(c, "q")
  -- x on a virtual row: the editor in normal mode, the line unchanged
  c.lua("_G.BUF, _G.WIN = S.open(...)", "needs-live.md")
  c.lua("M.goto(0, 9, S.vis_col(9, 2))")
  local line0 = c.lua("return vim.fn.getline(10)")
  H.ok(c.lua("return VR()").virtual, "virtual row")
  key(c, "x")
  H.eq({ true, "n" }, c.lua("return { require('custom.mdtable.celledit').is_open(), vim.api.nvim_get_mode().mode }"), "x opens the editor (normal mode)")
  key(c, "q")
  H.eq(line0, c.lua("return vim.fn.getline(10)"), "x deleted nothing")
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
