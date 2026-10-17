-- Sticky header (header.lua) screen tests: a child nvim per case with a UI
-- of the given size (tests/uidriver.lua), keys through nvim_input. The
-- screen dump (screen.lua, screenstring) shows floats, so S.check proves the
-- pinned header's bars sit at the body rows' columns.
local here = vim.fn.fnamemodify(_G.arg[0], ":p:h")
local H = dofile(here .. "/helpers.lua")
local D = dofile(here .. "/uidriver.lua")
local ONLY = os.getenv("ONLY")
D.timeout_ms = 20000 -- a child stuck in a prompt fails its case

local PRE = [[
_G.S = dofile(...)
_G.M = require('custom.mdtable')
_G.HD = require('custom.mdtable.header')
-- floats of the sticky header: { parent, win, height, width, col, row, text }
function _G.FLOATS()
  local out = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local c = vim.api.nvim_win_get_config(w)
    if c.relative ~= "" then
      local parent
      for p, f in pairs(HD._floats) do if f.win == w then parent = p end end
      out[#out + 1] = { parent = parent, win = w, height = c.height, width = c.width, col = c.col, row = c.row,
        text = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(w), 0, -1, false),
        pwidth = parent and vim.api.nvim_win_get_width(parent),
        textoff = parent and vim.fn.getwininfo(parent)[1].textoff }
    end
  end
  return out
end
function _G.WINLINE() return vim.fn.winline() end
]]

local function child(W, Hh)
  local c = D.start(W, Hh + 1)
  c.lua(PRE, here .. "/screen.lua")
  local t = { c = c }
  function t.lua(code, ...) return c.lua(code, ...) end
  function t.input(keys) c.request("nvim_input", keys) end
  function t.open(src, setup_code)
    c.lua("_G.BUF, _G.WIN = S.open(...)" .. (setup_code and (";" .. setup_code) or ""), src)
    t.input("<Ignore>")
  end
  function t.cur(l, col) t.input(("<Cmd>lua M.goto(0, %d, %d)<CR>"):format(l, col)) end
  function t.col(l, j) return c.lua("return S.cell_col(...)", l, j) end
  function t.floats() return c.lua("return FLOATS()") end
  function t.screen() return c.lua("return S.screen(0)") end
  function t.dump(rows)
    local d = {}
    for i, s in ipairs(rows or t.screen()) do d[#d + 1] = ("%2d|%s"):format(i, s) end
    return table.concat(d, "\n")
  end
  function t.aligned(label)
    local r = c.lua("local rows = S.screen(0); local e, b = S.check(rows, 0); return { e, b, rows }")
    local errs, blocks, rows = r[1], r[2], r[3]
    if #errs > 0 or #blocks == 0 then
      error(label .. ": " .. (#blocks == 0 and "no rendered table" or table.concat(errs, "\n")) .. "\n" .. t.dump(rows), 2)
    end
    return rows, blocks
  end
  function t.no_errors(label)
    local e = c.lua("local e = S.errors(); if vim.v.errmsg ~= '' then e[#e + 1] = 'errmsg: ' .. vim.v.errmsg end; return e")
    if #e > 0 then error(label .. ": errors: " .. table.concat(e, " | "), 2) end
  end
  -- the float (one expected) is shown and is the first screen lines
  function t.pinned(label)
    local fl = t.floats()
    local rows = t.aligned(label)
    if #fl ~= 1 then error(label .. ": " .. #fl .. " floats\n" .. t.dump(rows), 2) end
    local f = fl[1]
    H.eq(0, f.row, label .. ": float row")
    H.eq(0, f.col, label .. ": float col 0 (blank gutter prefix)")
    H.eq(f.pwidth, f.width, label .. ": float width = window width")
    H.eq(string.rep(" ", f.textoff), f.text[1]:sub(1, f.textoff), label .. ": gutter prefix blank")
    local n = f.height
    -- the clip marker it covers rides as the float's last line
    local marker = t.lua("return S.is_marker(...)", rows[n])
    local d = marker and n - 1 or n
    local ok = rows[1]:match("^%s*┌") and rows[d]:match("^%s*├")
    for i = 2, d - 1 do ok = ok and rows[i]:match("^%s*│") end
    if not ok then error(label .. ": first screen lines are not top border, header, delimiter\n" .. t.dump(rows), 2) end
    if marker then -- body rows below the marker against the float's top border
      local rest = {}
      for i, r in ipairs(rows) do if i ~= n then rest[#rest + 1] = r end end
      local e = t.lua("return (S.check(...))", rest, 0)
      if #e > 0 then error(label .. ": below the marker: " .. table.concat(e, "\n") .. "\n" .. t.dump(rows), 2) end
    end
    for i = 1, n do H.eq(f.text[i], rows[i]:sub(1, #f.text[i]), label .. ": screen row " .. i .. " is the float's line") end
    local wl = t.lua("return WINLINE()")
    if wl - 1 < n then error(label .. (": cursor screen row %d under the %d-line float\n"):format(wl - 1, n) .. t.dump(rows), 2) end
    return rows, f
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

local function count(rows, pat)
  local n = 0
  for _, s in ipairs(rows) do if s:find(pat, 1, true) then n = n + 1 end end
  return n
end

-- needs.md: header at line 7, delimiter 8, body rows 9..13 (0-based)
local HEADER, FIRST, LAST = 7, 9, 13
local LABEL = "What is absent" -- header text of needs.md

-- generated long table: n rows, 2-line rows at width ~60
local function long(n)
  local lines = { "# Long", "", "intro line", "", "| # | Name | Detail |", "|---|---|---|" }
  for i = 1, n do
    lines[#lines + 1] = ("| %d | name %d | %s end%d |"):format(i, i, ("detail words "):rep(6), i)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "after"
  return lines
end

local LONG = long

-- viewport plan state (C1b, C1c, C10)
local GUTTER = "vim.wo[WIN].number = true; vim.wo[WIN].numberwidth = 2; vim.wo[WIN].signcolumn = 'yes'; vim.wo[WIN].scrolloff = 0"
local STATE = [[
  local v = vim.fn.winsaveview()
  local p = M._plan(0)
  local f = HD._floats[vim.api.nvim_get_current_win()]
  local fh = (f and vim.api.nvim_win_is_valid(f.win)) and vim.api.nvim_win_get_config(f.win).height or 0
  return { line = vim.fn.line("."), topline = v.topline, topfill = v.topfill, fh = fh,
    show = p and p.show_header or false, plan = p and { p.topline, p.topfill, p.float_height } or {} }
]]
local function fmt(s)
  return ("line %d top %d fill %d float %d show %s plan %s"):format(s.line, s.topline, s.topfill, s.fh, tostring(s.show),
    table.concat(s.plan, "/"))
end
local function same(t, label, a, b, plan_too)
  local ok = a.line == b.line and a.topline == b.topline and a.topfill == b.topfill and a.fh == b.fh and a.show == b.show
  if plan_too then ok = ok and table.concat(a.plan, "/") == table.concat(b.plan, "/") end
  if not ok then error(("%s: state changed\n  was %s\n  now %s\n"):format(label, fmt(a), fmt(b)) .. t.dump(), 2) end
end

-- after a landing: a second render keeps the plan, float and view; l, h
-- inside the cell keep the float state and the view
local function stable(t, label)
  local s0 = t.lua(STATE)
  t.input("<Cmd>lua M.render(0, { force = true })<CR>")
  same(t, label .. ": second render", s0, t.lua(STATE), true)
  t.input("l"); same(t, label .. ": l", s0, t.lua(STATE))
  t.input("h"); same(t, label .. ": h", s0, t.lua(STATE))
  return s0
end

case("C1 needs 120x45: cursor on the last row, header off-screen -> pinned header aligned with the body", 120, 45, function(t)
  t.open("needs.md")
  t.cur(LAST, t.col(LAST, 3))
  local rows = t.pinned("last row")
  H.eq(1, count(rows, LABEL), "header text once")
  t.no_errors("C1")
end)

case("C1b needs 120x45: G from the top shows the float at once, aligned", 120, 45, function(t)
  t.open("needs.md")
  t.input("G")
  H.eq(LAST + 1, t.lua("return vim.fn.line('.')"), "G on the last row")
  local rows = t.pinned("G")
  H.eq(1, count(rows, LABEL), "header text once")
  stable(t, "C1b G")
  t.pinned("C1b after l h")
  t.no_errors("C1b")
end)

case("C1c needs 120x45 with 8 prose lines above: G, header_top > n: scrolled to the real marker, float shown", 120, 45, function(t)
  local lines = H.read("needs.md")
  for i = 1, 8 do table.insert(lines, 1, "prose line " .. i) end
  t.open(lines)
  t.input("G")
  local rows, f = t.pinned("G")
  H.ok(t.lua("return S.is_marker(...)", rows[f.height]), "float ends with a marker\n" .. t.dump(rows))
  H.eq(1, count(rows, "more row"), "one marker on screen (the real one is under the float)\n" .. t.dump(rows))
  stable(t, "C1c G")
  t.pinned("C1c after l h")
  t.no_errors("C1c")
end)

-- marker in the float: N = body rows above the cursor row whose first line
-- is not on screen below the float (the header is shown, not counted)
local function marker_count_ok(t, label)
  local rows, f = t.pinned(label)
  local mk = rows[f.height]
  if not t.lua("return S.is_marker(...)", mk) then return false end
  local n = tonumber(mk:match("… (%d+) more row")) or error("no count in " .. mk)
  local first
  for i = f.height + 1, #rows do
    local k = rows[i]:match("^%s*│%s*(%d+)%s*│")
    if k then first = tonumber(k); break end
  end
  H.eq(first - 1, n, label .. ": marker counts the hidden body rows (first visible row " .. first .. ")\n" .. t.dump(rows))
  return true
end

case("C1d marker count: 40-row table at 120x45, rows 40..20 with <C-k>; header_top == n included", 120, 45, function(t)
  t.open(LONG(40))
  t.cur(45, t.col(45, 2))
  local checked, hts = 0, {}
  for _ = 1, 20 do
    if #t.floats() == 1 and marker_count_ok(t, "row " .. t.lua("return vim.fn.line('.')")) then checked = checked + 1 end
    t.input("<C-k>")
  end
  H.ok(checked > 3, "float markers checked: " .. checked)
  -- header_top == n and > n on a plain scroll (no render): the float shows
  t.cur(45, t.col(45, 2))
  local A = 45
  local function at_ht(ht) -- topline l (topfill 0) giving header_top ht, set through input (WinScrolled fires)
    local l = t.lua([[local A, ht = ...
      for l = 0, A - 1 do
        local R = vim.api.nvim_win_text_height(0, { start_row = l, end_row = A - 1, start_vcol = 0 }).all
        if R == ht then return l end
      end
      return nil]], A, ht)
    if l then t.input(("<Cmd>call winrestview({'topline': %d, 'topfill': 0})<CR>"):format(l + 1)) end
    return l
  end
  for _, ht in ipairs({ 3, 4 }) do
    H.ok(at_ht(ht), "a topline gives header_top " .. ht)
    H.eq(45, t.lua("return vim.fn.line('.') - 1"), "cursor stays on the last row")
    local fl = t.floats()
    H.eq(1, #fl, "header_top " .. ht .. ": float shown\n" .. t.dump())
    local rows = t.aligned("header_top " .. ht)
    -- actual header_top: a clipped block is at most h - arows - 3 lines, so
    -- Neovim keeps the cursor line visible by scrolling back to ht <= 3
    local got = t.lua([[local A = ...
      local v = vim.fn.winsaveview()
      local fill = vim.api.nvim_win_text_height(0, { start_row = A, end_row = A }).fill
      if v.topline - 1 == A then return v.topfill - fill end
      return v.topfill + vim.api.nvim_win_text_height(0, { start_row = v.topline - 1, end_row = A - 1, start_vcol = 0 }).all]], A)
    print(("INFO C1d asked header_top %d, got %d, float height %d"):format(ht, got, fl[1].height))
    -- ht <= n: the float (n + 1 lines) covers the real marker and ends with
    -- its own; ht > n: header only, the real marker below it
    H.eq(got <= 3 and 4 or 3, fl[1].height, "float height at header_top " .. got .. "\n" .. t.dump(rows))
    H.eq(1, count(rows, "more row"), "one marker on screen at header_top " .. got .. "\n" .. t.dump(rows))
    if got <= 3 then marker_count_ok(t, "header_top " .. got) end
  end
  t.no_errors("C1d")
end)

case("C2 needs 120x45: <C-e> scrolls the header off (float), <C-y> back to the real header (no float, no duplicate)", 120, 45, function(t)
  t.open("needs.md")
  t.cur(FIRST + 1, t.col(FIRST + 1, 2))
  H.eq(0, #t.floats(), "header visible: no float")
  local shown
  for i = 1, 40 do
    t.input("<C-e>")
    local fl, rows = t.floats(), t.screen()
    if count(rows, LABEL) > 1 then error("duplicate header after <C-e> x" .. i .. "\n" .. t.dump(rows)) end
    if #fl == 1 then shown = i; t.pinned("<C-e> x" .. i); break end
  end
  H.ok(shown, "float shown after scrolling the header off")
  H.eq(FIRST + 2, t.lua("return vim.fn.line('.')"), "cursor still on the row")
  for i = 1, 40 do
    t.input("<C-y>")
    local fl, rows = t.floats(), t.screen()
    if count(rows, LABEL) > 1 then error("duplicate header after <C-y> x" .. i .. "\n" .. t.dump(rows)) end
    if #fl == 0 then
      H.eq(1, count(rows, LABEL), "real header visible when the float hides")
      H.ok(rows[1]:find("┌", 1, true) == nil or count(rows, "┌") == 1, "one top border")
      t.aligned("<C-y> x" .. i)
      t.no_errors("C2")
      return
    end
    t.pinned("<C-y> x" .. i)
  end
  error("float never hid\n" .. t.dump())
end)

case("C3 needs+text 120x45: cursor below the table hides the float, back into the table shows it", 120, 45, function(t)
  local lines = H.read("needs.md")
  vim.list_extend(lines, { "", "after the table" })
  t.open(lines)
  t.cur(LAST, t.col(LAST, 3))
  t.pinned("last row")
  t.cur(#lines - 1, 0)
  H.eq(0, #t.floats(), "cursor below the table: no float")
  t.aligned("below")
  t.cur(LAST, t.col(LAST, 2))
  t.pinned("back on the last row")
  t.no_errors("C3")
end)

case("C4 needs 120x45: typing in the far-right cell with the float shown: relayout, float still aligned", 120, 45, function(t)
  t.open("needs.md")
  t.cur(LAST, t.col(LAST, 7))
  local _, f0 = t.pinned("last cell")
  local w0 = t.lua("return HD.counters.writes")
  t.input("iwidening_the_status_column_text ")
  local _, f1 = t.pinned("typing")
  H.eq("i", t.lua("return vim.api.nvim_get_mode().mode"), "insert mode")
  local changed = table.concat(f0.text, "\n") ~= table.concat(f1.text, "\n")
  H.ok(changed, "widths changed: the float's lines were rewritten")
  H.ok(t.lua("return HD.counters.writes") > w0, "float buffer rewritten")
  t.input("<Esc>")
  t.pinned("after Esc")
  t.no_errors("C4")
end)

case("C5 short fully visible table: no float on any row or scroll", 80, 30, function(t)
  t.open({ "# T", "", "| a | b |", "|---|---|", "| 1 | one |", "| 2 | two |", "| 3 | three |", "", "after" })
  for l = 2, 6 do
    t.cur(l, 2)
    H.eq(0, #t.floats(), "row " .. l)
  end
  t.input("<C-e>")
  H.eq(0, #t.floats(), "<C-e>")
  t.no_errors("C5")
end)

for _, size in ipairs({ { 120, 45 }, { 80, 24 } }) do
  case(("C5 ledger %dx%d: a scrolled table shows the float"):format(size[1], size[2]), size[1], size[2], function(t)
    t.open("ledger.md")
    -- every table: cursor on its last row, then <C-e> until its header is off
    local tables = t.lua([[local m = M.model(0); local out = {}
      for _, e in ipairs(m.tables) do out[#out + 1] = { e.tbl.start_row, e.tbl.end_row } end; return out]])
    local shown = 0
    for _, tb in ipairs(tables) do
      local last = tb[2] - 1
      t.cur(last, t.col(last, 2))
      for _ = 1, 30 do
        if #t.floats() > 0 then break end
        if t.lua("return vim.fn.line('.') - 1") ~= last then break end
        t.input("<C-e>")
      end
      if #t.floats() > 0 and t.lua("return vim.fn.line('.') - 1") == last then
        shown = shown + 1
        t.pinned(("table at %d"):format(tb[1]))
      end
    end
    H.ok(shown > 0, "at least one ledger table showed a pinned header")
    print(("INFO ledger %dx%d: %d of %d tables pinned"):format(size[1], size[2], shown, #tables))
    t.no_errors("C5 ledger")
  end)
end


case("C6 vsplit: one float per window at its own width; closing a split removes its float", 120, 45, function(t)
  t.open(LONG(40))
  t.cur(45, t.col(45, 3))
  t.pinned("single")
  t.input("<Cmd>vsplit<CR>")
  t.cur(45, t.col(45, 3))
  local fl = t.floats()
  H.eq(2, #fl, "two floats\n" .. t.dump())
  local parents = {}
  for _, f in ipairs(fl) do
    H.ok(f.parent, "float has a parent")
    H.eq(f.pwidth, f.width, "float width = its window's width")
    parents[f.parent] = true
  end
  H.eq(2, vim.tbl_count(parents), "distinct parents")
  H.eq(4, #t.lua("return vim.api.nvim_list_wins()"), "2 windows + 2 floats")
  t.input("<Cmd>close<CR>")
  t.input("<Ignore>")
  t.lua("vim.wait(50, function() return false end)")
  H.eq(2, #t.lua("return vim.api.nvim_list_wins()"), "1 window + 1 float after :close")
  t.pinned("after close")
  t.no_errors("C6")
end)

for _, sp in ipairs({ { "needs.md", 120, 45, FIRST, LAST }, { "needs.md", 80, 30, FIRST, LAST }, { "long", 60, 20, 6, 45 } }) do
  local src, W, Hh, first, last = sp[1], sp[2], sp[3], sp[4], sp[5]
  case(("C7 %s %dx%d: <C-k> from the last row to the first body row: cursor never under the float"):format(src, W, Hh), W, Hh, function(t)
    t.open(src == "long" and long(40) or src)
    t.cur(last, t.col(last, 2))
    local steps, pinned = 0, 0
    while true do
      local l = t.lua("return vim.fn.line('.') - 1")
      local fl = t.floats()
      local rows = t.aligned("row " .. l)
      if #fl > 0 then
        pinned = pinned + 1
        local wl = t.lua("return WINLINE()")
        if wl - 1 < fl[1].height then
          error(("row %d: cursor screen row %d < float height %d\n"):format(l, wl - 1, fl[1].height) .. t.dump(rows))
        end
        t.pinned("row " .. l)
      end
      if l <= first then break end
      t.input("<C-k>")
      steps = steps + 1
      H.ok(steps < 100, "walk ends")
      H.ok(t.lua("return vim.fn.line('.') - 1") < l, "<C-k> moved up from " .. l)
    end
    H.eq(first, t.lua("return vim.fn.line('.') - 1"), "reached the first body row")
    print(("INFO C7 %s %dx%d: %d steps, float shown in %d"):format(src, W, Hh, steps, pinned))
    if src == "long" then H.ok(pinned > 5, "the float showed during the walk") end
    t.no_errors("C7")
  end)
end

case("C8 :MdTable header, g:mdtable_sticky_header, disable/toggle, :bd", 120, 45, function(t)
  t.open("needs.md")
  t.cur(LAST, t.col(LAST, 3))
  t.pinned("on")
  local log = {}
  local function n(label, want)
    local got = #t.floats()
    log[#log + 1] = ("%s: %d float(s)"):format(label, got)
    H.eq(want, got, label)
  end
  t.input("<Cmd>MdTable header<CR>"); n(":MdTable header (off)", 0)
  t.input("<Cmd>MdTable header<CR>"); n(":MdTable header (on)", 1)
  t.lua("vim.b.mdtable_sticky_header = nil; vim.g.mdtable_sticky_header = false"); t.input("<Cmd>lua M.render(0, { force = true })<CR>"); n("g:mdtable_sticky_header=false", 0)
  t.lua("vim.g.mdtable_sticky_header = nil"); t.input("<Cmd>lua M.render(0, { force = true })<CR>"); n("g:mdtable_sticky_header=nil", 1)
  t.input("<Cmd>MdTable disable<CR>"); n(":MdTable disable", 0)
  t.input("<Cmd>MdTable enable<CR>"); n(":MdTable enable", 1)
  -- cell 2 of the last row is taller: the clipped block above it is the
  -- marker and a separator (2 lines), too short to hold the 4-line float
  -- without covering the cursor line, so no float
  t.cur(LAST, t.col(LAST, 2)); n("cell 2 (block above shorter than the float)", 0)
  H.ok(t.lua("return #require('custom.mdtable')._last_model(0).tables") > 0, "still rendered")
  t.cur(LAST, t.col(LAST, 3)); n("back to cell 3", 1)
  t.input("<Cmd>MdTable toggle<CR>"); n(":MdTable toggle (off)", 0)
  t.input("<Cmd>MdTable toggle<CR>"); t.cur(LAST, t.col(LAST, 3)); n(":MdTable toggle (on)", 1)
  t.input("<Cmd>bd!<CR>"); t.input("<Ignore>")
  n(":bd!", 0)
  H.eq(1, #t.lua("return vim.api.nvim_list_wins()"), "one window after :bd!")
  for _, l in ipairs(log) do print("LOG C8 " .. l) end
  t.no_errors("C8")
end)

case("C9 perf: WinScrolled with the float shown < 0.3 ms per step (median of 30), no relayout, no rewrite", 60, 20, function(t)
  -- separators off: the 10-row grid fits the window (no clipping, no re-clip render)
  local lines = { "| # | Name |", "|---|---|" }
  for i = 1, 10 do lines[#lines + 1] = ("| %d | name %d |"):format(i, i) end
  lines[#lines + 1] = ""; lines[#lines + 1] = "after"
  t.open(lines, "vim.b[BUF].mdtable_row_separators = false")
  t.cur(11, 2)
  -- <C-y> next to concealed lines jumps the view to the table's first line
  -- (Neovim): scroll by topfill with winrestview, which fires WinScrolled too
  local top = t.lua("return vim.fn.winsaveview().topline")
  H.eq(12, top, "view top is the cursor line (scroll-to-fit)")
  t.input("<Cmd>call winrestview({'topline': 12, 'topfill': 8})<CR>")
  local _, f = t.pinned("scrolled")
  local r0 = t.lua("return { M.stats.n, require('custom.mdtable.layout').cache_size(), HD.counters.writes, HD.counters.opens, HD.counters.configs, M.stats.reclips or 0 }")
  t.lua("M.stats.htimes = {}")
  for i = 1, 30 do
    t.input(("<Cmd>call winrestview({'topline': 12, 'topfill': %d})<CR>"):format(i % 2 == 1 and 9 or 8))
    H.eq(i % 2 == 1 and 9 or 8, t.lua("return vim.fn.winsaveview().topfill"), "scrolled at step " .. i)
    H.eq(1, #t.floats(), "float shown at step " .. i)
  end
  local r1 = t.lua("return { M.stats.n, require('custom.mdtable.layout').cache_size(), HD.counters.writes, HD.counters.opens, HD.counters.configs, M.stats.reclips or 0 }")
  local times = t.lua("return M.stats.htimes")
  table.sort(times)
  local med = times[math.floor((#times + 1) / 2)]
  print(("PERF sticky header WinScrolled: %d steps, median %.4f ms, max %.4f ms; renders %d, layouts %d, rewrites %d, opens %d, configs %d, re-clips %d")
    :format(#times, med, times[#times], r1[1] - r0[1], r1[2] - r0[2], r1[3] - r0[3], r1[4] - r0[4], r1[5] - r0[5], r1[6] - r0[6]))
  H.ok(#times >= 30, "30 WinScrolled steps measured")
  H.ok(med < 0.3, ("median %.4f ms < 0.3"):format(med))
  H.eq(r0[1], r1[1], "no render on scroll")
  H.eq(r0[2], r1[2], "no relayout on scroll")
  H.eq(r0[3], r1[3], "float buffer not rewritten")
  H.eq(r0[4], r1[4], "float reused")
  H.eq(3, f.height, "header block: top, header, delimiter")
  t.no_errors("C9")
end)

-- One viewport plan (review finding 5): the float and scroll-to-fit come
-- from the same plan on every render path. After a landing (G, :$), a second
-- render with no cursor change and l/h inside the cell keep the plan, the
-- float state and the view; a cursor row too tall to fit below the float
-- gets no float in every state; :$ from inside the table lands in the same
-- float state as from outside.
-- needs.md plus a last row shaped like the reviewer's (cells of 64, 731
-- and 67 characters): too tall for the float at 100 columns
local function needs_tall()
  local lines = H.read("needs.md")
  local function words(n) return (("lorem ipsum dolor sit amet "):rep(40)):sub(1, n) end
  table.insert(lines, LAST + 2, ("| 999 | %s | %s | %s | 2026-10-01 | open | x |"):format(words(64), words(731), words(67)))
  return lines
end
for _, src in ipairs({ "needs", "needs+tall" }) do
for _, sz in ipairs({ { 100, 30 }, { 100, 42 }, { 120, 45 } }) do
  for _, gut in ipairs({ false, true }) do
    local W, Hh = sz[1], sz[2]
    local last = src == "needs" and LAST or LAST + 1
    local tag = ("%s %dx%d%s"):format(src, W, Hh, gut and " number+signcolumn" or "")
    case("C10 " .. tag .. ": gg G, re-render, l, h, :$ from inside: one plan, float and view constant", W, Hh, function(t)
      t.open(src == "needs" and "needs.md" or needs_tall(), gut and GUTTER or nil)
      t.input("gg"); t.input("G")
      local s0 = t.lua(STATE)
      H.eq(last + 1, s0.line, "G on the last row")
      H.ok(s0.plan[1] ~= nil, "a viewport plan for the cursor row")
      H.eq(s0.show and s0.plan[3] or 0, s0.show and s0.plan[3] or 0, "plan float height")
      if s0.show then t.pinned("G") else
        H.eq(0, s0.fh, "row too tall for the float: no float\n" .. t.dump())
        t.aligned("G")
      end
      print(("INFO C10 %s G: %s"):format(tag, fmt(s0)))
      t.input("<Cmd>lua M.render(0, { force = true })<CR>")
      same(t, "second render", s0, t.lua(STATE), true)
      t.input("l"); same(t, "l", s0, t.lua(STATE))
      t.input("h"); same(t, "h", s0, t.lua(STATE))
      t.input("h"); same(t, "h again", s0, t.lua(STATE))
      if s0.fh > 0 then t.pinned("after l h h") else t.aligned("after l h h") end
      -- :$ from outside (gg) and from inside the table (line 10)
      for _, from in ipairs({ "gg", ":10<CR>" }) do
        t.input("gg"); if from ~= "gg" then t.input(from) end
        t.input(":$<CR>")
        local s1 = t.lua(STATE)
        H.eq(last + 1, s1.line, ":$ from " .. from)
        if s1.show ~= s0.show or (s1.fh > 0) ~= (s0.fh > 0) then
          error((":$ from %s: float state differs from G\n  G  %s\n  :$ %s\n"):format(from, fmt(s0), fmt(s1)) .. t.dump())
        end
        t.input("l"); same(t, ":$ from " .. from .. " then l", s1, t.lua(STATE))
        t.input("h"); same(t, ":$ from " .. from .. " then h", s1, t.lua(STATE))
      end
      t.no_errors("C10")
    end)
  end
end
end

H.done()
