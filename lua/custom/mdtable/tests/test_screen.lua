-- Screen tests: every case runs in a fresh child nvim with a UI of the given
-- size (tests/uidriver.lua). Keys go through nvim_input, i.e. the real input
-- path: the command runs, CursorMoved/TextChanged fire, Neovim scrolls and
-- redraws. screen.lua (in the child) dumps the screen with `redraw!` +
-- screenstring() and checks that every bar of every rendered table line sits
-- at the top border's columns and that no raw `|` row is visible.
-- MDTABLE_OLD=<dir> runs the cases against an older module tree.
local here = vim.fn.fnamemodify(_G.arg[0], ":p:h")
local H = dofile(here .. "/helpers.lua")
local D = dofile(here .. "/uidriver.lua")
local OLD = os.getenv("MDTABLE_OLD") or ""
local ONLY = os.getenv("ONLY")

local function child(W, Hh)
  local c = D.start(W, Hh + 1)
  c.lua("vim.env.MDTABLE_OLD = ...; _G.S = dofile(" .. vim.inspect(here .. "/screen.lua") .. "); _G.M = require('custom.mdtable')", OLD)
  local t = { c = c }
  function t.lua(code, ...) return c.lua(code, ...) end
  function t.input(keys)
    c.request("nvim_input", keys)
    c.lua("if S.old then vim.wait(60, function() return false end) end")
  end
  function t.open(src, setup_code)
    c.lua("_G.BUF, _G.WIN = S.open(...)" .. (setup_code and (";" .. setup_code) or ""), src)
    t.input("<Ignore>")
  end
  -- programmatic moves go through M.goto (cursor + render before Neovim
  -- validates the cursor), like the navigation keys
  function t.cur(l, col)
    t.input(("<Cmd>lua if M.goto then M.goto(0, %d, %d) else vim.fn.cursor(%d, %d) end<CR>"):format(l, col, l + 1, col + 1))
  end
  function t.screen(win) return c.lua("return S.screen(...)", win or 0) end
  function t.aligned(label, allow_raw, win, allow_none)
    local r = c.lua("local rows = S.screen(...); local e, b = S.check(rows, select(2, ...)); return { e, b, rows }", win or 0, allow_raw or 0)
    local errs, blocks, rows = r[1], r[2], r[3]
    if #errs > 0 or (#blocks == 0 and not allow_none) then
      local d = {}
      for i, s in ipairs(rows) do d[#d + 1] = ("%2d|%s"):format(i, s) end
      error(label .. ": " .. (#blocks == 0 and "no rendered table" or table.concat(errs, "\n")) .. "\n" .. table.concat(d, "\n"), 2)
    end
    return rows, blocks
  end
  function t.no_errors(label)
    local e = c.lua("local e = S.errors(); if vim.v.errmsg ~= '' then e[#e + 1] = 'errmsg: ' .. vim.v.errmsg end; return e")
    if #e > 0 then error(label .. ": errors: " .. table.concat(e, " | "), 2) end
  end
  function t.stop() c.stop() end
  return t
end

local function case(name, W, Hh, fn)
  if ONLY and not name:find(ONLY, 1, true) then return end
  H.run(name, function()
    local t = child(W, Hh)
    local ok, err = xpcall(fn, debug.traceback, t)
    t.stop()
    if not ok then error(err, 0) end
  end)
end

local function find(rows, pat)
  for i, s in ipairs(rows) do if s:find(pat, 1, true) then return i end end
end

-- needs.md: header at line 7, delimiter 8, body rows 9..13 (0-based)
local HEADER, FIRST, LAST = 7, 9, 13

for _, size in ipairs({ { 120, 45 }, { 80, 30 } }) do
  local W, Hh = size[1], size[2]
  case(("needs %dx%d: cursor outside, header, cells 1/3/last of a wrapped row, last row"):format(W, Hh), W, Hh, function(t)
    t.open("needs.md")
    local _, blocks = t.aligned("outside")
    H.eq(1, #blocks, "one table")
    t.cur(HEADER, t.lua("return S.cell_col(...)", HEADER, 2))
    t.aligned("header row")
    for _, j in ipairs({ 1, 3, 7 }) do
      t.cur(FIRST + 1, t.lua("return S.cell_col(...)", FIRST + 1, j))
      local rows = t.aligned("cell " .. j)
      H.ok(find(rows, "Titles solve") or j ~= 3, "cell 3 text visible")
    end
    t.cur(LAST, t.lua("return S.cell_col(...)", LAST, 3))
    t.aligned("last row")
    t.no_errors("sweep")
  end)
end

case("needs 120x45: typing xxxxx in cell 3, Esc, then cells 1 and last", 120, 45, function(t)
  t.open("needs.md")
  for _, j in ipairs({ 3, 1, 7 }) do
    t.cur(FIRST, t.lua("return S.cell_col(...)", FIRST, j))
    t.input("ixxxxx")
    local rows = t.aligned("insert cell " .. j)
    H.ok(find(rows, "xxxxx"), "typed text visible (cell " .. j .. ")")
    H.eq("i", t.lua("return vim.api.nvim_get_mode().mode"), "still in insert mode")
    t.input("<Esc>")
    t.aligned("after Esc cell " .. j)
  end
  t.no_errors("typing")
end)

case("needs 120x45: append a row at EOF (o + full row)", 120, 45, function(t)
  t.open("needs.md")
  t.input("G")
  t.input("o| 99 | appended row | a | b | c | d | e |<Esc>")
  local rows = t.aligned("after append")
  H.ok(find(rows, "appended row"), "new row drawn")
  t.input("gg")
  rows = t.aligned("cursor back at the top")
  t.no_errors("append")
end)

case("B1: R5 repro C-j b J G from line 1 (stale tree ranges), then J two rows and undo", 120, 45, function(t)
  t.open("needs.md")
  t.input("<C-j>bJG")
  t.aligned("after C-j b J G")
  t.no_errors("after C-j b J G")
  t.input("u")
  t.cur(FIRST, t.lua("return S.cell_col(...)", FIRST, 2))
  t.input("J")
  t.no_errors("after J")
  t.screen()
  t.input("u")
  t.aligned("after undo")
  t.no_errors("after undo")
  t.input("<C-r>u")
  t.aligned("after redo+undo")
  t.no_errors("B1")
end)

local ICON_LINES = {
  "# Icons", "",
  "| A | B |",
  "|---|---|",
  -- column B is 42 wide: "see docs w*33" fits one line without the
  -- 2-column icon and needs two with it. The spike did not count the icon in
  -- its virtual rows (1 line) but its cursor row did (2 lines): the row grew
  -- on entry and the grid shifted.
  "| a | see [docs](x) " .. string.rep("w", 33) .. " |",
  "| b | c |",
  "", "end",
}
local ICON_SETUP = [[
  local ns = vim.api.nvim_create_namespace("fake.icons")
  local line = vim.api.nvim_buf_get_lines(BUF, 4, 5, false)[1]
  vim.api.nvim_buf_set_extmark(BUF, ns, 4, line:find("[", 1, true) - 1, { virt_text = { { "󰖟 ", "Special" } }, virt_text_pos = "inline" })
]]
case("B4: inline icon mark: cursor row keeps the virtual row's height and alignment", 50, 24, function(t)
  t.open(ICON_LINES, ICON_SETUP)
  local _, b0 = t.aligned("outside")
  local h0 = b0[1].bottom - b0[1].top
  t.cur(4, t.lua("return S.cell_col(...)", 4, 2))
  local rows, b1 = t.aligned("in icon cell")
  H.eq(h0, b1[1].bottom - b1[1].top, "table height with the cursor in the icon row")
  H.ok(find(rows, "󰖟"), "icon drawn")
  t.cur(5, 2)
  local _, b2 = t.aligned("next row")
  H.eq(h0, b2[1].bottom - b2[1].top, "table height with the cursor in the next row")
  t.no_errors("B4")
end)

case("B5: >> on a row (R5 soft.md repro): row stays in the grid, no raw leak, first cell drawn", 60, 30, function(t)
  t.open("soft.md")
  t.cur(4, 0)
  t.input(">>")
  local rows = t.aligned("after >>", 0)
  local r = find(rows, "│ x ")
  H.ok(r, "first cell (x) drawn")
  H.ok(not rows[r]:find("\\|", 1, true), "no raw backslash: " .. rows[r])
  t.input("<<")
  t.aligned("after <<")
  t.no_errors("B5")
end)

case("B6: insert on the first char of a wrapped grid line: cursor drawn on that char", 120, 45, function(t)
  t.open("needs.md")
  local c3 = t.lua("return S.vis_col(...)", FIRST + 1, 3)
  for n = 1, 2 do
    t.cur(FIRST + 1, c3)
    t.input(n .. "j") -- to the first char of grid line n + 1 of the cell (nav keys)
    H.ok(t.lua("return vim.api.nvim_win_get_cursor(0)[2]") > c3, "j moved within the cell")
    t.input("i")
    local got = t.lua([[
      vim.cmd("redraw!")
      local line = vim.api.nvim_get_current_line()
      local col = vim.api.nvim_win_get_cursor(0)[2]
      local pos = vim.api.nvim_win_get_position(0)
      local r, c = pos[1] + vim.fn.winline(), pos[2] + vim.fn.wincol()
      return { want = line:sub(col + 1, col + 1), got = vim.fn.screenstring(r, c), wincol = vim.fn.wincol() }
    ]])
    H.eq(got.want, got.got, "char under the insert cursor (wincol " .. got.wincol .. ")")
    t.aligned("insert at wrapped line start")
    t.input("<Esc>")
  end
  t.no_errors("B6")
end)

case("vsplit: both windows aligned with their own cursor and width", 120, 45, function(t)
  t.open("needs.md")
  t.input("<Cmd>vsplit<CR>")
  local wins = t.lua("return vim.api.nvim_tabpage_list_wins(0)")
  t.cur(FIRST, t.lua("return S.cell_col(...)", FIRST, 3))
  t.input("<C-w>w")
  t.cur(FIRST + 1, t.lua("return S.cell_col(...)", FIRST + 1, 1))
  for _, w in ipairs(wins) do t.aligned("window " .. w, 0, w) end
  t.no_errors("vsplit")
end)

for _, size in ipairs({ { 120, 45 }, { 80, 30 } }) do
  case(("ledger %dx%d: sweep every table line, cells 1 and last"):format(size[1], size[2]), size[1], size[2], function(t)
    t.open("ledger.md")
    local lines = t.lua([[
      local out = {}
      for _, tb in ipairs(M._last_model(0).tables) do
        for l = tb.tbl.start_row, tb.tbl.end_row - 1 do out[#out + 1] = l end
      end
      return out
    ]])
    H.ok(#lines > 10, "tables found")
    for _, l in ipairs(lines) do
      t.cur(l, 2)
      t.aligned("line " .. l .. " cell 1", 2)
      t.input("$")
      t.aligned("line " .. l .. " last cell", 2)
    end
    t.no_errors("ledger sweep")
  end)
end

case("separators toggle, toggle/disable/enable, stats", 120, 45, function(t)
  t.open("needs.md")
  local function seps(rows)
    local n = 0
    for _, s in ipairs(rows) do if s:find("├", 1, true) then n = n + 1 end end
    return n
  end
  local on = seps(t.aligned("separators on"))
  t.input("<Cmd>MdTable separators<CR>")
  local off = seps(t.aligned("separators off"))
  H.ok(on > off and off >= 1, ("separator lines %d -> %d"):format(on, off))
  t.input("<Cmd>MdTable separators<CR>")
  H.eq(on, seps(t.aligned("separators back on")), "separators restored")
  t.input("<Cmd>MdTable disable<CR>")
  local rows = t.screen()
  H.ok(not find(rows, "┌") and find(rows, "| #"), "disabled: raw table")
  t.input("<Cmd>MdTable enable<CR>")
  t.aligned("enabled again")
  t.input("<Cmd>MdTable toggle<CR>")
  H.ok(not find(t.screen(), "┌"), "toggled off")
  t.input("<Cmd>MdTable toggle<CR>")
  t.aligned("toggled on")
  local out = t.lua("return vim.api.nvim_exec2('MdTable stats', { output = true }).output")
  H.ok(out:match("^MdTable: %d+ renders, last [%d.]+ms, median [%d.]+ms, max [%d.]+ms") and out:find("cache hits", 1, true), out)
  t.no_errors("commands")
end)

case("scroll-to-fit: no pinning on entry from above, minimal scroll when clipped", 120, 45, function(t)
  t.open("needs.md")
  local v0 = t.lua("return vim.fn.winsaveview()")
  for _ = 1, HEADER do t.input("j") end
  H.eq(HEADER, t.lua("return vim.api.nvim_win_get_cursor(0)[1] - 1"), "on the header")
  local v1 = t.lua("return vim.fn.winsaveview()")
  H.eq(v0.topline, v1.topline, "topline unchanged entering the table from above")
  t.aligned("header from above")
  t.input("<C-j>") -- first body row: fully visible, no scroll
  H.eq(v0.topline, t.lua("return vim.fn.winsaveview().topline"), "no scroll for a fully visible row")
  t.input("<C-j>")
  t.input("<C-j>") -- third body row (row 70): clipped at the bottom -> minimal scroll
  local r = t.lua([[
    vim.cmd("redraw!")
    local f = M.last_fit
    return { fit = f, view = vim.fn.winsaveview(), last = S.screen()[vim.api.nvim_win_get_height(0)] }
  ]])
  local rows = t.aligned("after scroll-to-fit")
  local bottom = rows[#rows]
  H.ok(r.fit and r.fit.d and r.fit.d > 0, "fit scrolled: " .. vim.inspect(r.fit))
  H.ok(find(rows, "Impossibly sides enter"), "row 70 visible")
  H.ok(bottom:find("├", 1, true) or bottom:find("└", 1, true) or find(rows, "smile ro-vard"), "row's grid reaches the window: " .. bottom)
  t.no_errors("fit")
end)

case("cell navigation keys, insert-mode Ctrl-l, mdtable_table_motions", 120, 45, function(t)
  t.open("needs.md")
  local c2 = t.lua("return S.vis_col(...)", FIRST, 2)
  local c3 = t.lua("return S.vis_col(...)", FIRST, 3)
  t.cur(FIRST, c2)
  t.input("<C-l>")
  H.eq({ FIRST + 1, c3 }, t.lua("return vim.api.nvim_win_get_cursor(0)"), "C-l to the next cell")
  t.input("<C-h>")
  H.eq({ FIRST + 1, c2 }, t.lua("return vim.api.nvim_win_get_cursor(0)"), "C-h back")
  t.input("<C-j>")
  H.eq({ FIRST + 2, t.lua("return S.vis_col(...)", FIRST + 1, 2) }, t.lua("return vim.api.nvim_win_get_cursor(0)"), "C-j next row")
  t.input("<C-k>")
  H.eq(FIRST + 1, t.lua("return vim.api.nvim_win_get_cursor(0)[1]"), "C-k back")
  t.input("l")
  H.eq(c2 + 1, t.lua("return vim.api.nvim_win_get_cursor(0)[2]"), "l within the cell")
  t.cur(FIRST, c3)
  t.input("j")
  local p = t.lua("return vim.api.nvim_win_get_cursor(0)")
  H.eq(FIRST + 1, p[1], "j stays in the row (wrapped cell)")
  H.ok(p[2] > c3, "j moved to the next grid line of the cell")
  t.cur(FIRST, c2)
  t.input("i<C-l>")
  H.eq("i", t.lua("return vim.api.nvim_get_mode().mode"), "insert mode kept")
  H.eq({ FIRST + 1, c3 }, t.lua("return vim.api.nvim_win_get_cursor(0)"), "insert-mode C-l to the next cell")
  t.aligned("insert after C-l")
  t.input("<Esc>")
  t.no_errors("nav")
  local maps = t.lua([[
    vim.g.mdtable_table_motions = false
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(b)
    vim.bo[b].filetype = "markdown"
    M.attach(b)
    local n = 0
    for _, d in ipairs(vim.api.nvim_buf_get_keymap(b, "n")) do if d.desc == "mdtable: cell navigation" then n = n + 1 end end
    return n
  ]])
  H.eq(0, maps, "no maps with mdtable_table_motions = false")
end)

case("edge.md and inline.md: every table aligned (ragged rows raw)", 80, 30, function(t)
  t.open("inline.md")
  t.aligned("inline.md")
  for l = 2, 12 do t.cur(l, 2); t.aligned("inline line " .. l) end
  t.open("edge.md")
  t.aligned("edge.md", 2)
  t.no_errors("edge")
end)

-- F1 (review): raw jumps (:N, /, ?, n, N, G) onto a concealed table line.
-- Neovim validates the cursor with the previous marks before CursorMoved;
-- with ~1-2 window heights of filler it moved the cursor off the target.
-- Each step asserts line('.') == the target computed before the key.
local EXPECT = [[
  local k = ...
  local function sp(p, f) local r = vim.fn.searchpos(p, f); return r[1] end
  if k:match("^:%d+") then return tonumber(k:match("%d+")) end
  if k == "G" then return vim.fn.line("$") end
  if k == "gg" then return 1 end
  if k:sub(1, 1) == "/" then return sp(k:sub(2):gsub("<CR>$", ""), "nw") end
  if k:sub(1, 1) == "?" then return sp(k:sub(2):gsub("<CR>$", ""), "bnw") end
  local fwd = vim.v.searchforward == 1
  if k == "n" then return sp(vim.fn.getreg("/"), fwd and "nw" or "bnw") end
  if k == "N" then return sp(vim.fn.getreg("/"), fwd and "bnw" or "nw") end
  return -1
]]
local function jumps(t, steps, label)
  for _, k in ipairs(steps) do
    local want = t.lua(EXPECT, k)
    t.input(k)
    local got = t.lua("return vim.fn.line('.')")
    if want > 0 then H.eq(want, got, label .. ": line after " .. k) end
    t.aligned(label .. " after " .. k, 2, nil, true)
  end
  t.no_errors(label)
end
local function big(n)
  local lines = { "# Big", "", "| # | Topic | Detail |", "|---|---|---|" }
  for i = 1, n do lines[#lines + 1] = ("| %d | topic%d | %s |"):format(i, i, ("detail word "):rep(12) .. "end" .. i) end
  lines[#lines + 1] = ""; lines[#lines + 1] = "after"
  return lines
end
for _, size in ipairs({ { 120, 45, { 12, 16, 20, 24 } }, { 100, 30, { 6, 8, 10, 12, 14 } } }) do
  local W, Hh = size[1], size[2]
  case(("F1 raw jumps %dx%d: needs.md, ledger.md and grids of 1-2 window heights"):format(W, Hh), W, Hh, function(t)
    t.open("needs.md")
    jumps(t, { "gg", ":12<CR>", "gg", "/Impossibly<CR>", "gg", "?Sagg-acwrite<CR>", "n", "N", "gg", "G", ":3<CR>", ":14<CR>", ":1<CR>", ":$<CR>" }, "needs")
    t.input("gg"); t.input("G"); t.input("k")
    local l = t.lua("return vim.fn.line('.')")
    H.ok(l >= t.lua("return vim.fn.line('$')") - 1, "G then k stays in the last row or the one above: " .. l)
    t.aligned("needs G k", 2)
    t.open("ledger.md")
    jumps(t, { ":12<CR>", "gg", "/GM5<CR>", "gg", "?Ignores<CR>", "n", "N", "G", "gg", ":20<CR>" }, "ledger")
    for _, n in ipairs(size[3]) do
      t.open(big(n))
      local last, mid = 4 + n, 4 + math.floor(n / 2)
      jumps(t, { "gg", ":" .. last .. "<CR>", "gg", ":" .. mid .. "<CR>", ":" .. last .. "<CR>", "?end" .. math.floor(n / 2) .. "<CR>",
        "G", "?end" .. n .. "<CR>", "gg", "/end" .. n .. "<CR>", ":5<CR>", ":" .. last .. "<CR>", "gg", "/end" .. mid - 4 .. "<CR>", "n", "N" }, "big " .. n)
      t.input("G"); t.input("k"); t.input("k")
      H.eq(last, t.lua("return vim.fn.line('.')"), "big " .. n .. ": G k k lands on the last row")
      t.aligned("big G k k", 2)
    end
  end)
end

-- Viewport clipping (fix round 2): a table 4-5x the window height.
local function seen(rows)
  local ks, mk, set = {}, {}, {}
  for i, s in ipairs(rows) do
    local k = tonumber(s:match("│%s*topic(%d+)"))
    if k and not set[k] then set[k] = true; ks[#ks + 1] = k end
    local m = s:match("… (%d+) more rows? …")
    if m then mk[#mk + 1] = { row = i, n = tonumber(m) } end
  end
  table.sort(ks)
  return ks, mk, set
end
local function desc(ks, mk)
  local m = {}
  for _, x in ipairs(mk) do m[#m + 1] = ("row %d: %d more"):format(x.row, x.n) end
  return ("rows %s..%s, markers [%s]"):format(ks[1] or "-", ks[#ks] or "-", table.concat(m, ", "))
end
for _, size in ipairs({ { 120, 45, 60 }, { 100, 30, 40 } }) do
  local W, Hh, n = size[1], size[2], size[3]
  case(("clip %dx%d: %d-row table: first rows + marker, <C-e>/<C-d> reveal rows, row 30 with markers above and below"):format(W, Hh, n), W, Hh, function(t)
    t.open(big(n))
    t.input("gg")
    local rows = t.aligned("cursor above the table")
    local ks, mk = seen(rows)
    print("    gg: " .. desc(ks, mk))
    H.eq(1, #mk, "one marker below the first rows")
    H.ok(mk[1].row >= Hh - 2, "marker at the window bottom: " .. desc(ks, mk))
    H.eq(1, ks[1], "first row visible")
    H.eq(n - ks[#ks], mk[1].n, "marker counts the rows left out")
    local prev_max, prev_n = ks[#ks], mk[1].n
    for i = 1, 3 do
      t.input("<C-e>")
      rows = t.aligned("<C-e> " .. i)
      ks, mk = seen(rows)
      print(("    <C-e> %d: %s"):format(i, desc(ks, mk)))
      H.eq(1, #mk, "marker after <C-e>")
      H.ok(mk[1].row >= Hh - 2, "marker at the window bottom")
      H.eq(n - ks[#ks], mk[1].n, "marker count after <C-e>")
    end
    H.ok(ks[#ks] > prev_max and mk[1].n < prev_n, ("<C-e> revealed rows: max %d -> %d, marker %d -> %d"):format(prev_max, ks[#ks], prev_n, mk[1].n))
    prev_max = ks[#ks]
    -- <C-d> moves by rendered screen lines (nav.lua N.scroll, WP-E E3): from
    -- the header half a window down the grid, the view scrolled as much
    t.lua("require('custom.mdtable.nav').last_scroll = nil")
    t.input("<C-d>")
    local ls = t.lua("return require('custom.mdtable.nav').last_scroll")
    H.ok(ls, "<C-d> moved by the table model")
    local want = ls[1]
    rows = t.aligned("<C-d>")
    ks, mk = seen(rows)
    print(("    <C-d>: line %d (motion target %d), %s"):format(t.lua("return vim.fn.line('.')"), want, desc(ks, mk)))
    H.eq(want, t.lua("return vim.fn.line('.')"), "<C-d> lands on its target")
    H.ok(ks[#ks] > prev_max, "<C-d> revealed rows: " .. desc(ks, mk))
    t.input(":34<CR>") -- row 30
    H.eq(34, t.lua("return vim.fn.line('.')"), "on row 30")
    rows = t.aligned("row 30")
    ks, mk = seen(rows)
    print("    :34 (row 30): " .. desc(ks, mk))
    -- Neovim chooses the view (cursor line at the top or the bottom of the
    -- window); <C-y> brings the marker above the rows when it is off screen
    H.ok(find(rows, "topic30"), "row 30 visible: " .. desc(ks, mk))
    local tries = 0
    while tries < Hh do
      local _, m2 = seen(t.screen())
      if #m2 >= 2 then break end
      t.input("<C-y>"); tries = tries + 1
    end
    rows = t.aligned("row 30 after <C-y> x" .. tries)
    ks, mk = seen(rows)
    print(("    <C-y> x%d: line %d, %s"):format(tries, t.lua("return vim.fn.line('.')"), desc(ks, mk)))
    H.eq(34, t.lua("return vim.fn.line('.')"), "cursor still on row 30")
    H.ok(#mk == 2 and mk[1].row < find(rows, "topic30") and mk[2].row > find(rows, "topic30"), "markers above and below row 30: " .. desc(ks, mk))
    -- the clip's marker counts the header among the rows above; the sticky
    -- header float's marker (last float line) counts body rows only
    local fh = t.lua("local _, f = next(require('custom.mdtable.header')._floats); return f and vim.api.nvim_win_get_height(f.win) or 0")
    H.eq(mk[1].row == fh and ks[1] - 1 or ks[1], mk[1].n, "top marker counts the rows above (float: header excluded)")
    H.eq(n - ks[#ks], mk[2].n, "bottom marker counts the rows below")
    for i = 1, 6 do -- scroll down: rows below row 30 appear, the bottom marker stays at the bottom
      t.input("<C-e>")
      rows = t.aligned("row 30 <C-e> " .. i)
      ks, mk = seen(rows)
      print(("    row 30 <C-e> %d: line %d, %s"):format(i, t.lua("return vim.fn.line('.')"), desc(ks, mk)))
    end
    local _, _, set = seen(rows)
    H.eq(34, t.lua("return vim.fn.line('.')"), "cursor on row 30 after <C-e>")
    H.ok(set[29] and set[30] and set[31], "rows 29-31 visible: " .. desc(ks, mk))
    H.ok(#mk >= 1 and mk[#mk].row > find(rows, "topic31") and mk[#mk].row >= Hh - 3, "marker at the bottom: " .. desc(ks, mk))
    H.eq(n - ks[#ks], mk[#mk].n, "bottom marker count after <C-e>")
    t.no_errors("clip")
  end)
end

-- F8: search intents with 'ignorecase' + 'smartcase' (NvChad sets both,
-- lua/core/init.lua:55-56; --clean children do not): the target is the
-- search's own, not the lowercase decoy earlier in the file.
case("F8 smartcase: / ? n N targets and landings honour ignorecase + smartcase", 120, 45, function(t)
  local lines = { "# S", "", "| # | Detail |", "|---|---|" }
  for i = 1, 16 do
    local d = ("detail word "):rep(12) .. "end" .. i
    if i == 2 then d = "has wp5 lower " .. d elseif i == 12 then d = "has WP5 upper " .. d end
    lines[#lines + 1] = ("| %d | %s |"):format(i, d)
  end
  lines[#lines + 1] = ""; lines[#lines + 1] = "after"
  t.open(lines, "vim.o.ignorecase = true; vim.o.smartcase = true")
  local function target(pat, back, l)
    return t.lua("local p, b, l = ...; return M._intent_target(0, { kind = 'search', pattern = p, backward = b, origin = { l, 0 }, time = vim.uv.now() })", pat, back, l)
  end
  H.eq({ 15, 11 }, target("WP5", false, 0), "intent target of /WP5 from the top (row 12)")
  H.eq({ 5, 10 }, target("wp5", false, 0), "intent target of /wp5 (row 2: lowercase matches both, first)")
  H.eq({ 15, 11 }, target("WP5", true, 20), "intent target of ?WP5 from the end")
  H.eq({ 5, 10 }, target("\\cWP5", false, 0), "intent target of /\\cWP5")
  local function land(keys, want)
    t.input(keys)
    H.eq(want, t.lua("return vim.fn.line('.')"), "line after " .. keys)
    t.aligned("after " .. keys, 2)
  end
  land("gg", 1); land("/WP5<CR>", 16); land("gg", 1); land("/wp5<CR>", 6)
  land("gg", 1); land("/WP5<CR>", 16); land("gg", 1); land("n", 16); land("G", 22); land("N", 16)
  land("G", 22); land("?WP5<CR>", 16); land("gg", 1); land("/\\cWP5<CR>", 6)
  H.eq(0, t.lua("return M.stats.corrected or 0"), "no backup corrections")
  t.no_errors("smartcase")
end)

H.done()
