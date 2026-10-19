-- Floating cell editor (celledit.lua): pure helpers in this process, the
-- editor itself in a child nvim per case with a UI of the given size
-- (tests/uidriver.lua), keys through nvim_input. The leader is the default
-- backslash (`nvim --clean`), so <leader>te is "\te".
local here = vim.fn.fnamemodify(_G.arg[0], ":p:h")
local H = dofile(here .. "/helpers.lua")
local D = dofile(here .. "/uidriver.lua")
local ONLY = os.getenv("ONLY")
D.timeout_ms = 20000

local CE = require("custom.mdtable.celledit")

-- needs.md: header at line 7, delimiter 8, body rows 9..13 (0-based)
local HEADER, FIRST, LAST = 7, 9, 13
local ROW12 = 12 -- body row 4
local SIZES = { { 100, 20 }, { 100, 30 }, { 120, 45 } }

local PRE = [[
local spath = ...
_G.S = dofile(spath)
-- <leader>te as Jacob's config defines it: the mdtable section of
-- lua/core/mappings.lua (the one definition; celledit maps nothing)
do
  local maps = dofile(vim.fn.fnamemodify(spath, ":h:h:h:h:h") .. "/lua/core/mappings.lua")
  local m = maps.mdtable.n["<leader>te"]
  vim.keymap.set("n", "<leader>te", m[1], { desc = m[2] })
end
_G.NOTES = {}
local notify = vim.notify
vim.notify = function(msg, lvl, o) NOTES[#NOTES + 1] = msg; return notify(msg, lvl, o) end
_G.M = require('custom.mdtable')
_G.CE = require('custom.mdtable.celledit')
local api = vim.api
-- the editor's float: config, text, cursor, mode
function _G.FL()
  local st = CE.state()
  if not st or not api.nvim_win_is_valid(st.win) then return nil end
  local c = api.nvim_win_get_config(st.win)
  local title = {}
  for _, ch in ipairs(type(c.title) == "table" and c.title or {}) do title[#title + 1] = type(ch) == "table" and ch[1] or ch end
  return { win = st.win, buf = st.buf, pwin = st.pwin, lnum = st.lnum, k = st.k, width = c.width, height = c.height,
    row = c.row, col = c.col, relative = c.relative, title = table.concat(title),
    text = api.nvim_buf_get_lines(st.buf, 0, -1, false), cursor = api.nvim_win_get_cursor(st.win),
    current = api.nvim_get_current_win() == st.win, mode = api.nvim_get_mode().mode,
    pw = api.nvim_win_get_width(st.pwin), ph = api.nvim_win_get_height(st.pwin),
    th = api.nvim_win_text_height(st.win, {}).all, view = api.nvim_win_call(st.win, vim.fn.winsaveview),
    ft = vim.bo[st.buf].filetype, attached = M.attached(st.buf), wrap = vim.wo[st.win].wrap,
    linebreak = vim.wo[st.win].linebreak, cl = vim.wo[st.win].conceallevel, pcl = vim.wo[st.pwin].conceallevel,
    bufhidden = vim.bo[st.buf].bufhidden, listed = vim.bo[st.buf].buflisted }
end
-- the table behind the float: the float hidden for the screen dump
function _G.BEHIND(win)
  local st = CE.state()
  if st then api.nvim_win_set_config(st.win, { hide = true }) end
  local rows = S.screen(win or (st and st.pwin) or 0)
  if st then api.nvim_win_set_config(st.win, { hide = false }) end
  local m = M._last_model(win or (st and st.pwin) or 0)
  local errs, blocks = CHECK(rows, win or (st and st.pwin) or 0)
  return { errs, #blocks, rows, m and m.tall ~= nil }
end
-- S.check without the raw-row hint line (init.lua draws it above a row
-- drawn raw; it is not a grid line)
function _G.CHECK(rows, win)
  local m = M._last_model(win or 0)
  local out = {}
  for _, r in ipairs(rows) do
    if not r:find("row too tall to render here", 1, true) then out[#out + 1] = r end
  end
  return S.check(out, (m and m.tall) and 1 or 0)
end
-- every float and every editor buffer
function _G.LEFT()
  local f, b = 0, 0
  local hdr = {}
  for _, x in pairs(require('custom.mdtable.header')._floats) do hdr[x.win] = true end
  for _, w in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_config(w).relative ~= "" and not hdr[w] then f = f + 1 end -- the sticky header's floats aside
  end
  for _, x in ipairs(api.nvim_list_bufs()) do if api.nvim_buf_get_name(x):match("^mdtable%-cell://") then b = b + 1 end end
  return { f, b }
end
-- text rows of the editor float (inside its border)
function _G.FSCREEN()
  vim.cmd("redraw!")
  local st = CE.state()
  local pos = api.nvim_win_get_position(st.win) -- the border's top-left
  local c = api.nvim_win_get_config(st.win)
  local out = {}
  for r = 1, c.height do
    local t = {}
    for col = 1, c.width do t[#t + 1] = vim.fn.screenstring(pos[1] + 1 + r, pos[2] + 1 + col) end
    out[r] = table.concat(t)
  end
  return out
end
function _G.CELL(lnum, k)
  local c = CE._cell_of(api.nvim_win_get_buf(_G.WIN), lnum, k)
  return { s = c.cell.s, e = c.cell.e, text = c.cell.text, line = c.row.line }
end
]]

local function child(W, Hh)
  local c = D.start(W, Hh + 1)
  c.lua(PRE, here .. "/screen.lua")
  local t = { c = c }
  function t.lua(code, ...) return c.lua(code, ...) end
  function t.input(keys) c.request("nvim_input", keys); c.request("nvim_input", "<Ignore>") end
  function t.open(src, setup_code)
    c.lua("_G.BUF, _G.WIN = S.open(...)" .. (setup_code and (";" .. setup_code) or ""), src)
    t.input("<Ignore>")
  end
  function t.cur(l, col) t.input(("<Cmd>lua M.goto(0, %d, %d)<CR>"):format(l, col)) end
  function t.col(l, j) return c.lua("return S.cell_col(...)", l, j) end
  function t.fl()
    local f = c.lua("return FL()")
    if f == vim.NIL then return nil end -- nil over msgpack
    return f
  end
  function t.line(l) return c.lua("return vim.api.nvim_buf_get_lines(BUF, ..., ... + 1, false)[1]", l) end
  function t.cell(l, k) return c.lua("return CELL(...)", l, k) end
  function t.dump(rows)
    local d = {}
    for i, s in ipairs(rows) do d[#d + 1] = ("%2d|%s"):format(i, s) end
    return table.concat(d, "\n")
  end
  function t.behind(label)
    local r = c.lua("return BEHIND()")
    if #r[1] > 0 or r[2] == 0 then
      error(label .. ": table behind the float: " .. (r[2] == 0 and "no rendered table" or table.concat(r[1], "\n")) .. "\n"
        .. t.dump(r[3]), 2)
    end
    return r
  end
  function t.aligned(label)
    local r = c.lua("local rows = S.screen(0); local e, b = CHECK(rows); return { e, #b, rows }")
    if #r[1] > 0 or r[2] == 0 then
      error(label .. ": " .. (r[2] == 0 and "no rendered table" or table.concat(r[1], "\n")) .. "\n" .. t.dump(r[3]), 2)
    end
  end
  function t.notes() return c.lua("local o = {}; for _, n in ipairs(S.notes) do o[#o + 1] = n.msg end; return o") end
  function t.no_errors(label)
    local e = c.lua("local e = S.errors(); if vim.v.errmsg ~= '' then e[#e + 1] = 'errmsg: ' .. vim.v.errmsg end; return e")
    if #e > 0 then error(label .. ": errors: " .. table.concat(e, " | "), 2) end
  end
  function t.left() c.lua("vim.wait(30)"); return c.lua("return LEFT()") end
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

-- float geometry rules (brief: width = clamp(wrap-60 width, 20, winwidth-6),
-- height = wrapped line count clamped to 1..winheight-4, centred)
local function geometry_ok(t, f, label)
  local want_w = t.lua("return require('custom.mdtable.celledit').width_for(...)", table.concat(f.text, " "), f.pw)
  H.eq(want_w, f.width, label .. ": width")
  H.ok(f.width <= f.pw - 6, label .. ": width within the window")
  H.eq(math.max(1, math.min(f.th, f.ph - 4)), f.height, label .. ": height")
  H.ok(f.height + 2 <= f.ph, label .. ": height within the window")
  H.eq(math.max(0, math.floor((f.ph - f.height - 2) / 2)), f.row, label .. ": centred row")
  H.eq(math.max(0, math.floor((f.pw - f.width - 2) / 2)), f.col, label .. ": centred col")
end

------------------------------------------------------------------------------
-- pure helpers

H.run("U1 escape/unescape/join/text_of", function()
  H.eq("a | b", CE.unescape("a \\| b"))
  H.eq("a \\| b", CE.escape("a | b"))
  H.eq("one two three", CE.join({ "one  ", "  two", "three" }))
  H.eq("a  b c", CE.join({ "  a  b", "c  " }), "inner runs kept, joins collapsed")
  H.eq("a b", CE.join({ "a", "", "b" }), "empty line between")
  H.eq("", CE.join({ "" }))
  H.eq("x \\| y", CE.text_of({ "x |", "y" }))
end)

H.run("U2 C4 round trip: \\|, **bold**, link, CJK, emoji, code are byte-identical", function()
  local lines = H.read("celledit.md")
  H.with_buffer(lines, function(buf)
    local scan = require("custom.mdtable.scan")
    local n = 0
    for _, tbl in ipairs(scan.tables(buf, 0, #lines)) do
      for _, row in ipairs(tbl.rows) do
        if row.kind ~= "delim" then
          for _, cell in ipairs(row.cells) do
            local float = { CE.unescape(cell.text) }
            H.eq(cell.text, CE.text_of(float), "row " .. row.lnum .. " cell " .. cell.text)
            n = n + 1
          end
        end
      end
    end
    H.eq(12, n, "cells checked")
  end)
end)

H.run("U3 width_for: wrap at 60, clamp 20..winwidth-6", function()
  H.eq(20, CE.width_for("short", 100))
  H.eq(59, CE.width_for(("abcd "):rep(100), 200), "12 words of 4 per line")
  H.eq(94, CE.width_for(("x"):rep(150), 100), "a word longer than the window")
  H.eq(14, CE.width_for("short", 20), "narrow window")
  H.eq(1, CE.width_for("x", 3))
  H.eq(55, CE.width_for(("日本語 "):rep(40), 100), "CJK display width: 8 words of 6 per line")
end)

------------------------------------------------------------------------------
-- editor (child nvim with a UI)

for _, sz in ipairs(SIZES) do
  local W, Hh = sz[1], sz[2]
  local tag = W .. "x" .. Hh
  case("C1 " .. tag .. ": <leader>te on row 12 cell 3 opens the titled float, wrapped, cursor at start; table behind aligned", W, Hh, function(t)
    t.open("needs.md")
    t.cur(ROW12, t.col(ROW12, 3) + 5)
    t.input("\\te")
    local f = t.fl()
    H.ok(f, "float open")
    local cell = t.cell(ROW12, 3)
    H.eq(" What is absent · row 4 ", f.title, "title")
    H.eq({ (cell.text:gsub("\\|", "|")) }, f.text, "float text")
      H.eq({ 1, 0 }, f.cursor, "cursor at the start (the key was pressed 5 bytes into the cell)")
    H.ok(f.current, "float is the current window")
    H.eq("win", f.relative, "relative to the window")
    H.eq({ "markdown", false, true, true, "wipe", false }, { f.ft, f.attached, f.wrap, f.linebreak, f.bufhidden, f.listed },
      "scratch buffer: markdown, renderer not attached, wrap, linebreak, wiped, unlisted")
    H.eq(f.pcl, f.cl, "conceallevel as the main window")
    geometry_ok(t, f, tag)
    -- the float shows the cell text: its first screen line starts the text
    local rows = t.lua("return FSCREEN()")
    H.eq(f.text[1]:sub(1, 12), rows[1]:sub(1, 12), "float's first text line")
    H.eq(f.height, #rows, "float rows")
    local b = t.behind(tag)
    print(("INFO C1 %s: behind the float the cursor row is %s"):format(tag, b[4] and "raw (row taller than the window)" or "the in-place cursor row"))
    t.no_errors("C1")
  end)
end

H.run("C1b <leader>te opens at the cursor's offset; :MdTableCellEdit; outside a table the key notifies", function()
  local t = child(100, 30)
  local ok, err = xpcall(function()
    t.open("needs.md")
    local s = t.cell(ROW12, 3).s
    t.cur(ROW12, s + 7)
    t.input("<Cmd>MdTableCellEdit<CR>")
    local f = t.fl()
    H.ok(f, "open by command")
    H.eq({ 1, 0 }, f.cursor, ":MdTableCellEdit: cursor at the start")
    t.input("q")
    t.cur(ROW12, s + 7)
    t.input("<Cmd>lua CE.open_at_cursor({ at_cursor = true })<CR>")
    H.eq({ 1, 7 }, t.fl().cursor, "at_cursor keeps the cursor's offset in the cell")
    t.input("q")
    H.ok(not t.fl(), "closed")
    t.cur(0, 0)
    t.lua("NOTES = {}")
    t.input("\\te")
    H.ok(not t.fl(), "no float outside a table")
    local notes = t.lua("return NOTES")
    H.ok(#notes == 1 and notes[1]:find("not in a table", 1, true), "outside a table: one notice 'not in a table': " .. vim.inspect(notes))
    t.cur(8, 2)
    t.input("\\te")
    H.ok(not t.fl(), "no float on the delimiter row")
    t.no_errors("C1b")
  end, debug.traceback)
  t.stop()
  if not ok then error(err, 0) end
end)

for _, sz in ipairs(SIZES) do
  local W, Hh = sz[1], sz[2]
  local tag = W .. "x" .. Hh
  case("C2 " .. tag .. ": type at the start, <Esc>, <CR>: bytes [s,e) replaced, aligned, one u restores", W, Hh, function(t)
    t.open("needs.md")
    t.cur(ROW12, t.col(ROW12, 3))
    local old = t.line(ROW12)
    local cell = t.cell(ROW12, 3)
    t.input("\\te")
    t.input("ixxxxx <Esc>")
    H.ok(t.fl(), "still open after <Esc> from insert")
    t.input("<CR>")
    H.ok(not t.fl(), "closed by <CR>")
    local want = old:sub(1, cell.s) .. "xxxxx " .. cell.text .. old:sub(cell.e + 1)
    H.eq(want, t.line(ROW12), "line = old with the cell replaced")
    H.eq(t.lua("return WIN"), t.lua("return vim.api.nvim_get_current_win()"), "back in the main window")
    t.aligned(tag .. " after apply")
    t.input("u")
    H.eq(old, t.line(ROW12), "one u restores")
    t.aligned(tag .. " after u")
    t.no_errors("C2")
  end)
end

case("C2b two applies are two undo steps; <C-s> and :w apply and keep open", 100, 30, function(t)
  t.open("needs.md")
  t.cur(ROW12, t.col(ROW12, 3))
  local old = t.line(ROW12)
  t.input("\\te")
  t.input("iAAA <C-s>")
  local f = t.fl()
  H.ok(f and f.mode == "i", "<C-s> keeps the float open, in insert mode")
  local one = t.line(ROW12)
  H.ok(one:find("| AAA ", 1, true) ~= nil, "applied by <C-s>")
  t.input("BBB <Esc>:w<CR>")
  H.ok(t.fl(), ":w keeps the float open")
  local two = t.line(ROW12)
  H.ok(two:find("| AAA BBB ", 1, true) ~= nil, "applied by :w")
  H.eq(false, t.lua("return vim.bo[CE.state().buf].modified"), "not modified after :w")
  t.input("q")
  H.ok(not t.fl(), "q closes without a notice after :w")
  H.eq(0, #vim.tbl_filter(function(m) return m == "cell edit discarded" end, t.notes()), "no discard notice")
  t.input("u")
  H.eq(one, t.line(ROW12), "first u undoes the second apply")
  t.input("u")
  H.eq(old, t.line(ROW12), "second u undoes the first")
  t.no_errors("C2b")
end)

case("C3 q unmodified closes; q after typing discards and notifies; <Esc> after typing applies", 100, 20, function(t)
  t.open("needs.md")
  t.cur(ROW12, t.col(ROW12, 3))
  local old = t.line(ROW12)
  t.input("\\te"); t.input("q")
  H.ok(not t.fl(), "q closes")
  H.eq(old, t.line(ROW12), "unchanged")
  H.eq({}, t.notes(), "no notice")
  t.input("\\te"); t.input("izzz<Esc>q")
  H.ok(not t.fl(), "q closes a modified float")
  H.eq(old, t.line(ROW12), "discarded")
  H.eq({ "cell edit discarded" }, t.notes(), "discard notice")
  t.input("\\te"); t.input("<Esc>")
  H.ok(not t.fl(), "<Esc> closes an unmodified float")
  H.eq(old, t.line(ROW12), "unchanged by <Esc>")
  t.input("\\te"); t.input("iyyy <Esc><Esc>")
  H.ok(not t.fl(), "<Esc> closes a modified float")
  local cell = t.cell(ROW12, 3)
  H.eq("yyy ", cell.text:sub(1, 4), "<Esc> applied")
  t.aligned("C3")
  t.no_errors("C3")
end)

case("C4 apply without edits leaves the line byte-identical; an edit keeps \\| and multibyte text", 100, 30, function(t)
  t.open("celledit.md")
  for _, l in ipairs({ 4, 5, 6 }) do
    for k = 1, 3 do
      local old = t.line(l)
      t.cur(l, t.col(l, k))
      t.input("\\te"); t.input("<Cmd>lua CE.apply()<CR>"); t.input("<CR>")
      H.eq(old, t.line(l), ("line %d cell %d byte-identical"):format(l, k))
    end
  end
  local cell = t.cell(4, 2)
  H.eq("a \\| b **bold** [link](https://example.com) 日本語 😀 end", cell.text)
  t.cur(4, t.col(4, 2))
  t.input("\\te")
  H.eq({ "a | b **bold** [link](https://example.com) 日本語 😀 end" }, t.fl().text, "unescaped in the float")
  t.input("A | z<Esc><CR>")
  H.eq(cell.text .. " \\| z", t.cell(4, 2).text, "edit appended, | re-escaped")
  -- an empty cell gets spaces next to the bars
  t.cur(5, t.cell(5, 2).s) -- S.cell_col skips a blank cell's spaces into the next cell
  t.input("\\te"); t.input("inew<Esc><CR>")
  H.eq("new", t.cell(5, 2).text, "empty cell filled")
  H.ok(t.line(5):find("| new ", 1, true) ~= nil, "padded: " .. t.line(5))
  t.no_errors("C4")
end)

for _, sz in ipairs(SIZES) do
  local W, Hh = sz[1], sz[2]
  local tag = W .. "x" .. Hh
  case("C5 " .. tag .. ": <C-l>/<C-h>/<C-j>/<C-k> apply and move, clamp at the edges, insert mode kept", W, Hh, function(t)
    t.open("needs.md")
    t.cur(ROW12, t.col(ROW12, 3))
    t.input("\\te")
    t.input("iQ<Esc>")
    t.input("<C-l>")
    local f = t.fl()
    H.eq({ ROW12, 4 }, { f.lnum, f.k }, "cell 4")
    H.eq("Q", t.cell(ROW12, 3).text:sub(1, 1), "cell 3 applied before the move")
    H.eq({ (t.cell(ROW12, 4).text:gsub("\\|", "|")) }, f.text, "cell 4 text")
    H.ok(f.title:find("· row 4 ", 1, true), "title row 4: " .. f.title)
    geometry_ok(t, f, tag .. " cell 4")
    t.behind(tag .. " cell 4")
    t.input("<C-j>")
    f = t.fl(); H.eq({ ROW12 + 1, 4 }, { f.lnum, f.k }, "next row, same column")
    t.input("<C-j>")
    f = t.fl(); H.eq({ LAST, 4 }, { f.lnum, f.k }, "clamped at the last row")
    t.input("<C-l><C-l><C-l><C-l><C-l>")
    f = t.fl(); H.eq({ LAST, 7 }, { f.lnum, f.k }, "clamped at the last column")
    t.input("<C-h><C-h><C-h><C-h><C-h><C-h><C-h><C-h>")
    f = t.fl(); H.eq({ LAST, 1 }, { f.lnum, f.k }, "clamped at the first column")
    t.input("<C-k><C-k><C-k><C-k>")
    f = t.fl(); H.eq({ FIRST, 1 }, { f.lnum, f.k }, "first body row")
    t.input("<C-k>")
    f = t.fl(); H.eq({ HEADER, 1 }, { f.lnum, f.k }, "the header, delimiter skipped")
    H.eq(" # · header ", f.title, "header title")
    t.input("<C-k>")
    f = t.fl(); H.eq({ HEADER, 1 }, { f.lnum, f.k }, "clamped at the header")
    t.input("<C-j>")
    f = t.fl(); H.eq({ FIRST, 1 }, { f.lnum, f.k }, "header to the first body row")
    -- insert mode: move and keep typing
    t.input("<C-l>")
    t.input("iW<C-l>")
    f = t.fl()
    H.eq({ FIRST, 3 }, { f.lnum, f.k }, "moved from insert mode")
    H.eq("i", f.mode, "still in insert mode")
    t.input("V<C-j>")
    f = t.fl()
    H.eq({ FIRST + 1, 3 }, { f.lnum, f.k }, "<C-j> from insert mode")
    H.eq("i", f.mode, "still in insert mode")
    t.input("<Esc><CR>")
    H.eq("W", t.cell(FIRST, 2).text:sub(1, 1), "typed in cell 2")
    H.eq("V", t.cell(FIRST, 3).text:sub(1, 1), "typed in cell 3")
    t.aligned(tag .. " after the moves")
    t.no_errors("C5")
  end)
end

for _, sz in ipairs(SIZES) do
  local W, Hh = sz[1], sz[2]
  local tag = W .. "x" .. Hh
  case("C6 " .. tag .. ": geometry rules for every cell of row 12; a 2,000-character cell scrolls inside the float", W, Hh, function(t)
    local lines = H.read("needs.md")
    local big = (("lorem ipsum dolor sit amet "):rep(80)):sub(1, 2000)
    table.insert(lines, LAST + 2, ("| 999 | short | %s | x | 2026-10-01 | open | y |"):format(big))
    t.open(lines)
    for k = 1, 7 do
      t.cur(ROW12, t.col(ROW12, k))
      t.input("\\te")
      geometry_ok(t, t.fl(), tag .. " cell " .. k)
      t.input("q")
    end
    t.cur(LAST + 1, t.col(LAST + 1, 3))
    t.input("\\te")
    local f = t.fl()
    H.eq(2000, #f.text[1], "the whole cell in the float")
    geometry_ok(t, f, tag .. " big")
    if f.th > f.ph - 4 then
      H.ok(f.th > f.height, "taller than the float: it scrolls")
      t.input("$")
      f = t.fl()
      H.ok(f.view.skipcol > 0 or f.view.topline > 1, "scrolled inside the float: " .. vim.inspect(f.view))
      local rows = t.lua("return FSCREEN()")
      local last = vim.trim(rows[#rows])
      H.ok(#last > 10 and big:sub(-#last) == last, "float shows the cell's tail: " .. last)
    else
      H.eq(f.th, f.height, "fits: no scrolling needed at " .. tag)
    end
    -- resize: the rules hold for the new parent size
    for _, s2 in ipairs({ { 100, 20 }, { 120, 45 } }) do
      t.c.request("nvim_ui_try_resize", s2[1], s2[2] + 1); t.input("<Ignore>")
      geometry_ok(t, t.fl(), tag .. " resized to " .. s2[1] .. "x" .. s2[2])
    end
    t.no_errors("C6")
  end)
end

case("C7 no orphan floats or buffers: :q of the parent split, :bd, :tabnew, close_all", 100, 30, function(t)
  t.open("needs.md")
  H.eq({ 0, 0 }, t.left(), "nothing before")
  -- :q of the parent split
  t.input("<Cmd>split<CR>")
  t.cur(ROW12, t.col(ROW12, 3))
  t.input("\\te")
  H.eq({ 1, 1 }, t.left(), "one float, one buffer")
  t.input("<C-w>p:q<CR>")
  H.eq({ 0, 0 }, t.left(), "after :q of the parent split")
  -- :q of the parent split from inside the float (parent closed by API)
  t.input("<Cmd>split<CR>")
  t.cur(ROW12, t.col(ROW12, 3))
  t.input("\\te")
  t.input("<Cmd>lua vim.api.nvim_win_close(CE.state().pwin, true)<CR>")
  H.eq({ 0, 0 }, t.left(), "after closing the parent from the float")
  -- :tabnew from inside the float
  t.cur(ROW12, t.col(ROW12, 3))
  t.input("\\te")
  t.input(":tabnew<CR>")
  H.eq({ 0, 0 }, t.left(), "after :tabnew")
  t.input(":tabclose<CR>")
  -- close_all (VimLeavePre, :MdTable disable)
  t.cur(ROW12, t.col(ROW12, 3))
  t.input("\\te")
  t.input("<Cmd>lua CE.close_all()<CR>")
  H.eq({ 0, 0 }, t.left(), "after close_all")
  t.input("\\te")
  t.input("<Cmd>doautocmd VimLeavePre<CR>")
  H.eq({ 0, 0 }, t.left(), "after VimLeavePre")
  -- :bd of the parent buffer (from the parent window)
  t.cur(ROW12, t.col(ROW12, 3))
  t.input("\\te")
  t.input("ichanged<Esc>")
  t.input("<C-w>p:bd!<CR>")
  H.eq({ 0, 0 }, t.left(), "after :bd")
  H.ok(vim.tbl_contains(t.notes(), "cell edit discarded"), "a change lost to :bd is announced")
  H.eq(false, t.lua("return CE.is_open()"), "state cleared")
  t.no_errors("C7")
end)

------------------------------------------------------------------------------
-- wiring (init.lua, nav.lua): i/a/I/A on a row drawn raw, the hint,
-- :MdTable edit, :MdTable disable, detach

local HINT = "row too tall to render here — i or \\te opens the cell editor"
local function cell_k(t) -- cell of the main window's cursor
  return t.lua("local c = vim.api.nvim_win_get_cursor(0); local m = require('custom.mdtable.scan').tables(0, c[1] - 1, c[1]); for _, tb in ipairs(m) do local r = tb.rows[c[1] - tb.start_row]; if r then return require('custom.mdtable.project').cell_at(r, c[2]) end end")
end
local function screen_has(t, text)
  local rows = t.lua("return S.screen(0)")
  for i, r in ipairs(rows) do if r:find(text, 1, true) then return i, rows end end
  return nil, rows
end

for _, sz in ipairs({ { 100, 20 }, { 100, 30 } }) do
  local W, Hh = sz[1], sz[2]
  local tag = W .. "x" .. Hh
  case("W1 " .. tag .. ": raw row: hint above it; i/a/I/A open the editor at the cursor's cell; back in the same cell", W, Hh, function(t)
    t.open("needs.md")
    local cell = t.cell(ROW12, 3)
    t.cur(ROW12, cell.s + 7)
    H.ok(t.lua("return M._last_model(0).tall ~= nil"), "the row is drawn raw")
    local hi, rows = screen_has(t, HINT)
    H.ok(hi, "hint on screen\n" .. t.dump(rows))
    H.ok(rows[hi + 1]:match("^%s*|"), "hint right above the raw row\n" .. t.dump(rows))
    t.aligned(tag .. " with the hint")
    t.input("i")
    local f = t.fl()
    H.ok(f, "i opens the editor")
    H.eq({ ROW12, 3, "i" }, { f.lnum, f.k, f.mode }, "cell 3, insert mode")
    H.eq({ 1, 7 }, f.cursor, "at the cursor's offset")
    t.input("Q<Esc><CR>")
    H.eq(cell.text:sub(1, 7) .. "Q" .. cell.text:sub(8), t.cell(ROW12, 3).text, "typed at the offset")
    H.ok(not t.fl(), "closed")
    H.eq(ROW12 + 1, t.lua("return vim.fn.line('.')"), "back on the row")
    H.eq(3, cell_k(t), "back in cell 3")
    H.ok(t.lua("return M._last_model(0).tall ~= nil"), "still drawn raw")
    t.aligned(tag .. " after the editor")
    -- A: insert at the end; I: at the start; a: after the cursor's character
    t.input("A")
    f = t.fl()
    H.eq({ "i", #f.text[1] }, { f.mode, f.cursor[2] }, "A: insert at the end")
    t.input("<Esc>q")
    t.input("I")
    f = t.fl()
    H.eq({ "i", 0 }, { f.mode, f.cursor[2] }, "I: insert at the start")
    t.input("<Esc>q")
    t.cur(ROW12, t.cell(ROW12, 3).s + 2)
    t.input("a")
    f = t.fl()
    H.eq({ "i", 3 }, { f.mode, f.cursor[2] }, "a: after the cursor's character")
    -- move to the next row in the editor: closing lands in that row's cell
    t.input("<C-j><Esc><CR>")
    H.eq(ROW12 + 2, t.lua("return vim.fn.line('.')"), "on the next row after <C-j>")
    H.eq(3, cell_k(t), "in cell 3 of the next row")
    t.aligned(tag .. " after <C-j>")
    t.no_errors("W1")
  end)
end

case("W2 mdtable_cell_editor = false: i inserts in the line, no hint; a row that fits keeps i", 100, 20, function(t)
  t.open("needs.md", "vim.g.mdtable_cell_editor = false")
  t.cur(ROW12, t.col(ROW12, 3))
  H.ok(t.lua("return M._last_model(0).tall ~= nil"), "drawn raw")
  t.input("<Cmd>lua M.render(0, { force = true })<CR>")
  H.eq(nil, (screen_has(t, HINT)), "no hint")
  t.input("i")
  H.eq({ false, "i" }, { t.fl() ~= nil, t.lua("return vim.api.nvim_get_mode().mode") }, "builtin insert")
  t.input("<Esc>")
  -- the editor on, the hint off
  t.lua("vim.g.mdtable_cell_editor = nil; vim.g.mdtable_tall_hint = false")
  t.input("<Cmd>lua M.render(0, { force = true })<CR>")
  H.eq(nil, (screen_has(t, HINT)), "mdtable_tall_hint = false: no hint")
  t.input("i")
  H.ok(t.fl(), "the editor still opens")
  t.input("<Esc>q")
  t.no_errors("W2")
end)

case("W3 120x45: the row fits, i is the builtin insert", 120, 45, function(t)
  t.open("needs.md")
  t.cur(ROW12, t.col(ROW12, 3))
  H.eq(false, t.lua("return M._last_model(0).tall ~= nil"), "not raw")
  H.eq(nil, (screen_has(t, HINT)), "no hint")
  t.input("i")
  H.eq({ false, "i" }, { t.fl() ~= nil, t.lua("return vim.api.nvim_get_mode().mode") }, "builtin insert")
  t.input("<Esc>")
  t.no_errors("W3")
end)

case("W4 :MdTable edit opens; :MdTable disable and detach close it", 100, 30, function(t)
  t.open("needs.md")
  t.cur(ROW12, t.col(ROW12, 3))
  t.input(":MdTable edit<CR>")
  H.ok(t.fl(), ":MdTable edit opens")
  t.input("<Cmd>MdTable disable<CR>")
  H.eq({ 0, 0 }, t.left(), "closed by :MdTable disable")
  t.input("<Cmd>MdTable enable<CR>")
  t.cur(ROW12, t.col(ROW12, 3))
  t.input("\\te")
  H.ok(t.fl(), "open again")
  t.input("<Cmd>lua M.detach(BUF)<CR>")
  H.eq({ 0, 0 }, t.left(), "closed by detach")
  t.no_errors("W4")
end)

H.done()
