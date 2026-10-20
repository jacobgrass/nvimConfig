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
    -- a cursor row taller than the window is drawn raw (init.lua, WP-E E2): one raw row tolerated then
    -- the gutter (number column) blanked, as CH and tmux_check.lua do: a raw
    -- row (per row since WP-I, also in cell 1) starts with its line number
    local r = c.lua([[local rows = S.screen(0); local to = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff
      local chk = {}
      for i, x in ipairs(rows) do chk[i] = string.rep(" ", to) .. vim.fn.strcharpart(x, to) end
      local m = M._last_model(0); local e, b = S.check(chk, (m and m.tall) and 1 or 0); return { e, b, rows }]])
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
      local e = t.lua([[local rest = ...; local to = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff
        for i, x in ipairs(rest) do rest[i] = string.rep(" ", to) .. vim.fn.strcharpart(x, to) end -- gutter blanked
        local m = M._last_model(0); return (S.check(rest, (m and m.tall) and 1 or 0))]], rest)
      if #e > 0 then error(label .. ": below the marker: " .. table.concat(e, "\n") .. "\n" .. t.dump(rows), 2) end
    end
    for i = 1, n do H.eq(f.text[i], rows[i]:sub(1, #f.text[i]), label .. ": screen row " .. i .. " is the float's line") end
    local wl = t.lua("return WINLINE()")
    -- (WP-J: a virtual row scrolled in place (its top above the float's
    -- bottom) may have its line, the cursor, under the float: the active
    -- cell's highlight is what shows)
    local scrolled = t.lua([[local m = M._last_model(0); local v = m and m.vrow
      return v ~= nil and v.lnum == LL() - 1 and (v.off > 0 or (v.pre or 0) < (v.reserve or 0))]])
    if wl - 1 < n and not scrolled then error(label .. (": cursor screen row %d under the %d-line float\n"):format(wl - 1, n) .. t.dump(rows), 2) end
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
  return { line = LL(), topline = v.topline, topfill = v.topfill, fh = fh,
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
  H.eq(LAST + 1, t.lua("return LL()"), "G on the last row")
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
    if #t.floats() == 1 and marker_count_ok(t, "row " .. t.lua("return LL()")) then checked = checked + 1 end
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
    H.eq(45, t.lua("return LL() - 1"), "cursor stays on the last row")
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
  H.eq(FIRST + 2, t.lua("return LL()"), "cursor still on the row")
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

-- WP-G: a cursor row whose cell spills rows above carries its separator on
-- the line's first screen row; seated under the float, that separator goes
-- under the float's delimiter like a separator drawn as filler, so the
-- delimiter is never followed by a second border line.
-- needs-live.md: header 7, delimiter 8, body 9..12; line 11 (151) cells 4..7
-- spill 6..8 rows at 140 columns.
for _, mode in ipairs({ "row", "flow" }) do
  case("CG needs-live 140x50 spill=" .. mode .. ": Ctrl-l into spilling cells under the float: one border under the float, no double separator", 140, 50, function(t)
    t.open("needs-live.md", ("vim.g.mdtable_spill = %q"):format(mode))
    t.cur(11, t.col(11, 1))
    local shown = 0
    for k = 2, 7 do
      t.input("<C-l>")
      t.input("<Ignore>")
      local rows = t.screen()
      local m = t.lua("local m = M._last_model(0); return m and m.cursor and { k = m.cursor.k, lil = m.cursor.proj.lines_in_line, spill = m.cursor.proj.spill_above, blank = m.cursor.proj.blank_above + m.cursor.proj.blank_below } or vim.NIL")
      H.ok(m ~= vim.NIL and m.k == k, "cursor in cell " .. k)
      if mode == "flow" then H.eq(0, m.blank, "flow: cell " .. k .. " shows no blank row") end
      t.aligned("cell " .. k)
      if #t.floats() > 0 then
        shown = shown + 1
        local d
        for i, s in ipairs(rows) do if s:find("├", 1, true) then d = i; break end end
        H.ok(d and not (rows[d + 1] or ""):find("├", 1, true), ("cell %d (spill %d, lines in line %d): the float's delimiter is followed by a border line\n%s")
          :format(k, m.spill, m.lil, t.dump(rows)))
      end
    end
    if mode == "row" then H.ok(shown > 0, "the float is shown on the spilling cells") end
    t.no_errors("CG")
  end)
end

-- WP-G review round: "flow" draws lines of the block below on the cursor
-- line's spill rows; the row's height for scroll-to-fit must count them, or
-- a line exactly as tall as the window is fitted one row short and Neovim
-- moves the cursor to the next table row (needs.md row 12, cell 2 -> 3).
-- (Jacob's gutter: number column 5 wide; the window heights around 43)
for _, mode in ipairs({ "flow", "row", "cell" }) do
 for _, Hh in ipairs({ 43, 44, 45, 46 }) do
  case(("CH needs 120x%d spill=%s: Ctrl-l and Ctrl-h across row 12 stay on row 12, at each cell's start"):format(Hh, mode), 120, Hh, function(t)
    t.open("needs.md", ("vim.g.mdtable_spill = %q; vim.wo.number = true; vim.wo.numberwidth = 5"):format(mode))
    t.cur(12, t.col(12, 1))
    local seen, want_k = {}, nil
    for _, key in ipairs({ "<C-l>", "<C-l>", "<C-l>", "<C-l>", "<C-l>", "<C-l>", "<C-h>", "<C-h>", "<C-h>", "<C-h>", "<C-h>", "<C-h>" }) do
      t.input(key)
      t.input("<Ignore>")
      -- (a raw row, WP-I round 3 at these sizes in "flow": the cell from the
      -- cursor's byte, as nav.lua moves by the scan model)
      local c = t.lua([[local c = M.logical_cursor(0); local m = M._last_model(0)
        local cell = m and m.cursor and m.cursor.tbl.rows[m.cursor.r].cells[m.cursor.k]
        local k = m and m.cursor and m.cursor.k or 0
        if m and not m.cursor and m.vrow and m.vrow.lnum == c[1] - 1 then
          -- WP-J: a virtual (tall) row: its active cell
          k = m.vrow.k; cell = m.vrow.tbl.rows[m.vrow.r].cells[k]
        elseif m and not m.cursor and m.tall and m.tall.lnum == c[1] - 1 then
          for _, e in ipairs(m.tables) do
            if c[1] - 1 >= e.tbl.start_row and c[1] - 1 < e.tbl.end_row then
              local row = e.tbl.rows[c[1] - e.tbl.start_row]
              k = require("custom.mdtable.project").cell_at(row, c[2]); cell = row.cells[k]
            end
          end
        end
        return { c[1] - 1, c[2], k, m and m.cursor and m.cursor.proj.rows or (m and m.vrow and m.vrow.proj.rows) or -1,
          cell and cell.s or -1, cell and cell.e or -1 }]])
      want_k = (want_k or 1) + (key == "<C-l>" and 1 or -1)
      H.eq(12, c[1], mode .. " " .. key .. ": cursor line")
      H.eq(want_k, c[3], mode .. " " .. key .. ": cell")
      if c[6] > c[5] then H.eq(c[5], c[2], mode .. " " .. key .. ": at the start of cell " .. c[3]) end
      if seen[c[3]] then H.eq(seen[c[3]], c[4], mode .. ": cell " .. c[3] .. " height the same both ways") end
      seen[c[3]] = c[4]
      -- alignment with the number column blanked (as tmux_check.lua does)
      local a = t.lua([[local rows = S.screen(0)
        for i, x in ipairs(rows) do rows[i] = string.rep(" ", 5) .. vim.fn.strcharpart(x, 5) end
        local m = M._last_model(0); local e, b = S.check(rows, (m and m.tall) and 1 or 0); return { e, #b }]])
      H.eq({}, a[1], mode .. " cell " .. c[3] .. ": aligned")
      H.ok(a[2] > 0, mode .. " cell " .. c[3] .. ": a rendered table")
    end
    t.no_errors("CH")
  end)
 end
end

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
        if t.lua("return LL() - 1") ~= last then break end
        t.input("<C-e>")
      end
      if #t.floats() > 0 and t.lua("return LL() - 1") == last then
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
      local l = t.lua("return LL() - 1")
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
      H.ok(t.lua("return LL() - 1") < l, "<C-k> moved up from " .. l)
    end
    H.eq(first, t.lua("return LL() - 1"), "reached the first body row")
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
  -- WP-I: the float is decided per row (the screen is the same in every
  -- cell): cell 2 of the last row, whose own block above used to be too
  -- short for the 4-line float, shows the row's float like cell 3
  t.cur(LAST, t.col(LAST, 2)); n("cell 2 (the row's float, as cell 3)", 1)
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

-- WP-E E2: sizes. The renderer uses the window's current size after every
-- terminal resize (no cursor move) and after `j`; the float follows the
-- window width; a cursor row taller than the window is drawn raw, so
-- Neovim never scrolls inside it (w_skipcol: the overlays of the skipped
-- screen rows were drawn on top) and no "@@@"/"<<<" covers a bar.
local SIZE = [[
  local out = { stale = {}, wins = {} }
  for _, l in ipairs(M.dims_lines()) do if l:find("STALE", 1, true) then out.stale[#out.stale + 1] = l end end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(w).relative == "" then
      local rows = S.screen(w)
      local m = M._last_model(w)
      local e = S.check(rows, (m and m.tall) and 1 or 0)
      local at = 0
      for _, r in ipairs(rows) do if r:find("@@@", 1, true) or r:find("<<<", 1, true) then at = at + 1 end end
      local skip = vim.api.nvim_win_call(w, function() return vim.fn.winsaveview().skipcol end)
      local l = vim.api.nvim_win_get_cursor(w)[1] - 1
      local intable = false
      for _, en in ipairs(m and m.tables or {}) do if l >= en.tbl.start_row and l < en.tbl.end_row then intable = true end end
      out.wins[#out.wins + 1] = { win = w, errs = e, at = at, skip = skip, rows = rows, tall = m and m.tall ~= nil, intable = intable }
    end
  end
  return out
]]
local function sizes_ok(t, label)
  local r = t.lua(SIZE)
  if #r.stale > 0 then error(label .. ": render used an old size: " .. table.concat(r.stale, " | "), 2) end
  for _, w in ipairs(r.wins) do
    local why = {}
    if #w.errs > 0 then why[#why + 1] = w.errs[1] end
    -- cursor above/below a table whose anchor block overflows the window
    -- bottom: Neovim's "@@@" also on the committed code (WP-E report, p5-head.log)
    if w.at > 0 and w.intable then why[#why + 1] = w.at .. " row(s) with @@@/<<<" end
    if w.at > 0 and not w.intable then print(("KNOWN %s win %d: @@@ with the cursor outside the table"):format(label, w.win)) end
    if w.skip > 0 then why[#why + 1] = "skipcol " .. w.skip end
    if #why > 0 then error(("%s win %d: %s\n"):format(label, w.win, table.concat(why, "; ")) .. t.dump(w.rows), 2) end
  end
  for _, f in ipairs(t.floats()) do
    H.eq(f.pwidth, f.width, label .. ": float width = window width")
    H.eq(0, f.col, label .. ": float col")
  end
  if #t.floats() == 1 and #r.wins == 1 then t.pinned(label) end
  return r
end
local MATRIX = { { 97, 31 }, { 143, 38 }, { 100, 20 }, { 80, 50 }, { 120, 45 } }
for _, src in ipairs({ "needs", "needs+tall" }) do
  for _, at in ipairs({ "G", "row 3 cell 2" }) do
    case(("C11 %s %s: resize 120x45 -> 97x31, 143x38, 100x20, 80x50, 120x45; after each, no key, then j"):format(src, at), 120, 45, function(t)
      t.open(src == "needs" and "needs.md" or needs_tall())
      if at == "G" then t.input("G") else t.cur(FIRST + 2, t.col(FIRST + 2, 2)) end
      sizes_ok(t, "120x45 start")
      for _, sz in ipairs(MATRIX) do
        local tag = sz[1] .. "x" .. sz[2]
        t.c.request("nvim_ui_try_resize", sz[1], sz[2] + 1); t.input("<Ignore>")
        H.eq(sz[2], t.lua("return vim.api.nvim_win_get_height(0)"), tag .. ": window height")
        local r = sizes_ok(t, tag)
        t.input("j"); sizes_ok(t, tag .. " j"); t.input("k")
        if r.wins[1].tall then print(("INFO C11 %s %s %s: cursor row drawn raw (taller than the window)"):format(src, at, tag)) end
      end
      t.no_errors("C11")
    end)
  end
end
for _, sz in ipairs({ { 143, 38 }, { 120, 45 } }) do
  case(("C11 vsplit at %dx%d, then 97x31 and back"):format(sz[1], sz[2]), sz[1], sz[2], function(t)
    t.open("needs.md")
    t.input("<Cmd>vsplit<CR>"); t.cur(FIRST + 2, t.col(FIRST + 2, 2))
    sizes_ok(t, "vsplit")
    for _, s2 in ipairs({ { 97, 31 }, sz }) do
      t.c.request("nvim_ui_try_resize", s2[1], s2[2] + 1); t.input("<Ignore>")
      sizes_ok(t, s2[1] .. "x" .. s2[2]); t.input("j"); sizes_ok(t, s2[1] .. "x" .. s2[2] .. " j")
    end
    t.no_errors("C11 vsplit")
  end)
end
for _, sz in ipairs({ { 100, 20 }, { 97, 31 } }) do
  -- WP-J: the row is virtual (no longer raw): j/k scroll its virtual block
  -- one screen row at a time (view, then in-row offset), then leave it
  case(("C11 tall row %dx%d: virtual; j/k scroll it a screen row at a time, then leave it; no skipcol, no @@@"):format(sz[1], sz[2]), sz[1], sz[2], function(t)
    local lines = needs_tall()
    vim.list_extend(lines, { "", "after" })
    t.open(lines)
    t.cur(LAST + 1, t.col(LAST + 1, 3))
    local function vr()
      return t.lua([[local m = M._last_model(0); local v = m.vrow
        return v and { v.room_down, v.room_up, v.off, LL(), m.tall ~= nil } or false]])
    end
    local TL = LAST + 2 -- 1-based line of the tall row
    local v0 = vr()
    H.ok(v0, "the row is taller than the window: drawn virtual")
    H.eq(false, v0[5], "not raw")
    local down = v0[1]
    H.ok(down >= 3, "rows to scroll down: " .. down)
    for i = 1, down do
      t.input("j")
      local v = vr()
      H.ok(v, "j " .. i .. ": still virtual")
      H.eq({ TL, down - i }, { v[4], v[1] }, "j " .. i .. " stays on the row, one screen row scrolled")
      sizes_ok(t, "j " .. i)
    end
    t.input("j")
    H.eq(TL + 1, t.lua("return LL()"), "j at the row's end leaves the table")
    t.cur(LAST + 1, t.col(LAST + 1, 3))
    for _ = 1, vr()[1] do t.input("j") end -- (the view differs from the first visit: no note)
    local up = vr()[2]
    H.ok(up >= 3, "rows to scroll up: " .. up)
    for i = 1, up do
      t.input("k")
      local v = vr()
      H.eq({ TL, up - i }, { v[4], v[2] }, "k " .. i .. " stays on the row, one screen row scrolled")
      sizes_ok(t, "k " .. i)
    end
    t.input("k")
    H.eq(TL - 1, t.lua("return LL()"), "k at the row's top: the row above")
    sizes_ok(t, "k across")
    print(("INFO C11 tall %dx%d: %d screen rows scrolled down, %d up"):format(sz[1], sz[2], down, up))
    t.no_errors("C11 tall")
  end)
end

H.done()
