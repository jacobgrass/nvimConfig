-- custom.mdtable.celledit: floating editor for one Markdown table cell.
--
-- For rows taller than the window (7 columns of 300-700 characters at 120
-- columns or fewer) in-place editing cannot keep the grid: the table stays
-- rendered (the row virtual, its active cell highlighted, WP-J) and the
-- cell is edited in a float over it.
--
--   celledit.open(win, lnum, k, opts)  edit cell k (1-based) of line lnum
--                                      (0-based) of window win's buffer;
--                                      opts.col: byte offset in the cell
--                                      text for the float's cursor,
--                                      opts.insert: "i"|"a"|"I"|"A"
--   celledit.open_at_cursor(opts)      the cell under the cursor (false when
--                                      the cursor is not on a table cell);
--                                      opts.at_cursor: the float's cursor at
--                                      the cursor's offset in the cell
--   celledit.apply()                   write the float's text to the cell
--   celledit.close(apply)              close (apply first when true)
--   celledit.close_all()               close without applying (:MdTable
--                                      disable, VimLeavePre)
--   celledit.close_buf(buf)            close an editor on buf (detach)
--   celledit.is_open()
--   celledit.move(dir)                 dir h/j/k/l: apply, then edit the
--                                      neighbouring cell (same row prev/next
--                                      cell, or the same column in the
--                                      prev/next row; the header counts, the
--                                      delimiter is skipped; clamped)
--
-- Cell data comes from scan.tables (byte offsets s, e of the trimmed cell
-- text); the float shows the text with `\|` unescaped. Apply joins the
-- float's lines with one space (whitespace at the joins collapsed), trims,
-- re-escapes `|` and replaces bytes [s, e) of the line with one
-- nvim_buf_set_text call (one undo step), then re-renders the window.
--
-- Main window while the float is open: the renderer's normal drawing of the
-- cursor row; a row taller than the window is the virtual row with the
-- edited cell highlighted (the parent's cursor is on the cell, so the
-- highlight follows Ctrl-hjkl in the float and stays after closing).
--
-- Keys in the float: <C-s> and :w apply and keep it open; normal <CR>
-- applies and closes; normal <Esc> closes, applying when the text changed;
-- normal q closes, discarding a change ("cell edit discarded");
-- <C-h>/<C-j>/<C-k>/<C-l> (normal and insert) apply and move.
-- From a table: :MdTableCellEdit (:MdTable edit), <leader>te (the mdtable
-- section of lua/core/mappings.lua, calling open_at_cursor: a notice outside
-- a table), and i/a/I/A/s/c/<CR> on a virtual (tall) row
-- (nav.lua; vim.g.mdtable_cell_editor = false turns that off).
local api = vim.api
local scan = require("custom.mdtable.scan")
local project = require("custom.mdtable.project")

local C = {}
C.KEY = "<leader>te"
C.WRAP = 60 -- the float's width: the cell text wrapped at this many columns

local S -- the open editor: { win, buf, pwin, pbuf, lnum, k, orig, group }
local seq = 0

-- Pure helpers (unit tested) ------------------------------------------------

function C.unescape(text) return (text:gsub("\\|", "|")) end
function C.escape(text) return (text:gsub("|", "\\|")) end

-- Lines joined with one space; whitespace is collapsed at the joins only.
function C.join(lines)
  local out = lines[1] or ""
  for i = 2, #lines do
    out = (out:gsub("%s+$", "")) .. " " .. (lines[i]:gsub("^%s+", ""))
  end
  return vim.trim(out)
end

-- Cell text of the float's lines.
function C.text_of(lines) return C.escape(C.join(lines)) end

-- Display width of the longest line of text word-wrapped at `at` columns.
function C.wrap_width(text, at)
  local longest, cur = 0, 0
  for word in text:gmatch("%S+") do
    local w = api.nvim_strwidth(word)
    if cur == 0 then
      cur = w
    elseif cur + 1 + w <= at then
      cur = cur + 1 + w
    else
      longest = math.max(longest, cur)
      cur = w
    end
  end
  return math.max(longest, cur)
end

-- Float width for the text in a window `winw` columns wide.
function C.width_for(text, winw)
  return math.max(1, math.min(math.max(C.wrap_width(text, C.WRAP), 20), winw - 6))
end

local function truncate(s, max)
  if api.nvim_strwidth(s) <= max then return s end
  local n = vim.fn.strchars(s)
  while n > 0 and api.nvim_strwidth(vim.fn.strcharpart(s, 0, n)) > max - 1 do n = n - 1 end
  return vim.fn.strcharpart(s, 0, n) .. "…"
end

-- " <header text> · row <n> " (n: body row number, 1-based; "header" for the header row)
function C.title(tbl, r, k, width)
  local hc = tbl.rows[1].cells[k]
  local h = hc and C.unescape(hc.text) or ""
  if h == "" then h = "column " .. k end
  local which = r == 1 and "header" or ("row " .. (r - 2))
  local tail = " · " .. which .. " "
  h = truncate(h, math.max(width - api.nvim_strwidth(tail) - 1, 1))
  return " " .. h .. tail
end

-- Cell model --------------------------------------------------------------

-- The table containing line lnum of buf and the row's index in it.
local function locate(buf, lnum)
  for _, tbl in ipairs(scan.tables(buf, lnum, lnum + 1)) do
    if lnum >= tbl.start_row and lnum < tbl.end_row then
      local r = lnum - tbl.start_row + 1
      if tbl.rows[r] and tbl.rows[r].lnum == lnum then return tbl, r end
    end
  end
end

-- { tbl, r, row, k, cell } for cell k of line lnum, or nil, reason.
local function cell_of(buf, lnum, k)
  local tbl, r = locate(buf, lnum)
  if not tbl then return nil, "not in a table" end
  local row = tbl.rows[r]
  if row.kind == "delim" then return nil, "the delimiter row has no cells to edit" end
  if #row.cells == 0 then return nil, "the row has no cells" end
  k = math.max(1, math.min(k or 1, #row.cells))
  return { tbl = tbl, r = r, row = row, k = k, cell = row.cells[k] }
end
C._cell_of = cell_of

-- Cell under the cursor of win: lnum, k, byte offset in the cell text.
function C.cell_under_cursor(win)
  win = (win == nil or win == 0) and api.nvim_get_current_win() or win
  local buf = api.nvim_win_get_buf(win)
  if vim.b[buf].mdtable_celledit then return nil end
  -- (WP-K: while parked, the active row's line and cell)
  local m = package.loaded["custom.mdtable"]
  local cur = (m and m.logical_cursor) and m.logical_cursor(win) or api.nvim_win_get_cursor(win)
  local lnum, col = cur[1] - 1, cur[2]
  local tbl, r = locate(buf, lnum)
  if not tbl then return nil end
  local row = tbl.rows[r]
  if row.kind == "delim" or #row.cells == 0 then return nil end
  local k = project.cell_at(row, col)
  local c = row.cells[k]
  return lnum, k, math.max(0, math.min(col - c.s, c.e - c.s))
end

-- Editor ------------------------------------------------------------------

local function core() return package.loaded["custom.mdtable"] end

local function rerender(win)
  local m = core()
  if m and api.nvim_win_is_valid(win) and m.attached(api.nvim_win_get_buf(win)) then m.render(win) end
end

local function dirty()
  if not S or not api.nvim_buf_is_valid(S.buf) then return false end
  return C.text_of(api.nvim_buf_get_lines(S.buf, 0, -1, false)) ~= S.orig
end
C.dirty = dirty

local function fill(b, text)
  local ul = vim.bo[b].undolevels
  vim.bo[b].undolevels = -1 -- the change below clears the undo history (of a previous cell)
  api.nvim_buf_set_lines(b, 0, -1, false, { text })
  vim.bo[b].undolevels = ul
  vim.bo[b].modified = false
end

-- Size and centre the float over its parent window.
local function place()
  local fw, pwin = S.win, S.pwin
  local W, Hh = api.nvim_win_get_width(pwin), api.nvim_win_get_height(pwin)
  local text = table.concat(api.nvim_buf_get_lines(S.buf, 0, -1, false), " ")
  local width = C.width_for(text, W)
  local cfg = { relative = "win", win = pwin, width = width, height = 1, row = 0, col = 0, border = "rounded",
    title = S.title_for(width), title_pos = "left" }
  api.nvim_win_set_config(fw, cfg)
  local th = api.nvim_win_text_height(fw, {}).all
  cfg.height = math.max(1, math.min(th, Hh - 4))
  cfg.row = math.max(0, math.floor((Hh - cfg.height - 2) / 2))
  cfg.col = math.max(0, math.floor((W - width - 2) / 2))
  api.nvim_win_set_config(fw, cfg)
end
C._place = function() if S then place() end end

local close_impl

-- Autocmds tied to the parent window and buffer (recreated per target).
local function watch()
  S.group = api.nvim_create_augroup("mdtable_celledit_open", { clear = true })
  local g, fw, pwin, pbuf = S.group, S.win, S.pwin, S.pbuf
  local function involuntary()
    -- inside WinClosed/BufWinLeave the layout may be locked: retry later
    if not pcall(close_impl, false, true) then vim.schedule(function() pcall(close_impl, false, true) end) end
  end
  api.nvim_create_autocmd("WinClosed", { group = g, pattern = tostring(fw), callback = function()
    vim.schedule(function() if S and S.win == fw then pcall(close_impl, false, false) end end)
  end })
  api.nvim_create_autocmd("WinClosed", { group = g, pattern = tostring(pwin), callback = involuntary })
  api.nvim_create_autocmd({ "BufWinLeave", "BufUnload" }, { group = g, buffer = pbuf, callback = involuntary })
  api.nvim_create_autocmd("TabLeave", { group = g, callback = involuntary })
  api.nvim_create_autocmd("WinResized", { group = g, callback = function()
    if S and api.nvim_win_is_valid(S.win) and api.nvim_win_is_valid(S.pwin) then pcall(place) end
  end })
end

-- Point the open float at cell k of line lnum of pwin's buffer.
local function retarget(pwin, lnum, k, opts)
  local pbuf = api.nvim_win_get_buf(pwin)
  local c, why = cell_of(pbuf, lnum, k)
  if not c then return false, why end
  S.pwin, S.pbuf, S.lnum, S.k, S.orig = pwin, pbuf, lnum, c.k, c.cell.text
  local tbl, r, kk = c.tbl, c.r, c.k
  S.title_for = function(width) return C.title(tbl, r, kk, width) end
  fill(S.buf, C.unescape(c.cell.text))
  vim.wo[S.win].conceallevel = vim.wo[pwin].conceallevel
  place()
  -- the parent's cursor on the edited cell: the background shows its row
  -- (cursor(): nvim_win_set_cursor validates against the old marks at once,
  -- and the row's line is concealed while parked; the render parks again)
  api.nvim_win_call(pwin, function() vim.fn.cursor(lnum + 1, c.cell.s + 1) end)
  rerender(pwin)
  watch()
  -- the float's cursor: opts.col is a byte offset in the escaped cell text
  local text = c.cell.text
  local off = math.max(0, math.min(opts and opts.col or 0, #text))
  local fcol = #C.unescape(text:sub(1, off))
  local line = api.nvim_buf_get_lines(S.buf, 0, 1, false)[1] or ""
  local ins = opts and opts.insert
  if ins == "I" then fcol = 0 end
  if ins == "a" and fcol < #line then fcol = fcol + #vim.fn.strcharpart(line:sub(fcol + 1), 0, 1) end
  if ins == "A" then fcol = #line end
  api.nvim_win_set_cursor(S.win, { 1, math.min(fcol, #line) })
  if ins then
    if fcol >= #line and #line > 0 then vim.cmd("startinsert!") else vim.cmd("startinsert") end
  end
  return true
end

local function new_buf()
  seq = seq + 1
  local b = api.nvim_create_buf(false, true)
  vim.b[b].mdtable_celledit = true
  vim.bo[b].buftype = "acwrite" -- :w runs BufWriteCmd (apply)
  vim.bo[b].bufhidden = "wipe"
  vim.bo[b].swapfile = false
  api.nvim_buf_set_name(b, "mdtable-cell://" .. seq)
  vim.bo[b].filetype = "markdown" -- render-markdown's inline highlights
  local m = core()
  if m then m.detach(b) end -- the config attaches the table renderer to every markdown buffer: not here
  local function map(modes, lhs, fn)
    vim.keymap.set(modes, lhs, fn, { buffer = b, nowait = true, silent = true, desc = "mdtable cell editor" })
  end
  map({ "n", "i" }, "<C-s>", function() C.apply() end)
  map("n", "<CR>", function() C.close(true) end)
  map("n", "<Esc>", function() C.close(dirty()) end)
  map("n", "q", function()
    local d = dirty()
    C.close(false)
    if d then vim.notify("cell edit discarded", vim.log.levels.INFO) end
  end)
  for _, d in ipairs({ "h", "j", "k", "l" }) do
    map({ "n", "i" }, "<C-" .. d .. ">", function() C.move(d) end)
  end
  api.nvim_create_autocmd("BufWriteCmd", { buffer = b, callback = function() C.apply() end })
  api.nvim_create_autocmd("BufWipeout", { buffer = b, callback = function()
    if S and S.buf == b then vim.schedule(function() if S and S.buf == b then pcall(close_impl, false, false) end end) end
  end })
  return b
end

function C.is_open()
  return S ~= nil and api.nvim_win_is_valid(S.win)
end

function C.state() return S end

function C.open(win, lnum, k, opts)
  win = (win == nil or win == 0) and api.nvim_get_current_win() or win
  if S and not C.is_open() then close_impl(false, false) end
  if S and win == S.win then return false end
  local pbuf = api.nvim_win_get_buf(win)
  local c, why = cell_of(pbuf, lnum, k)
  if not c then
    vim.notify("mdtable cell editor: " .. why, vim.log.levels.WARN)
    return false
  end
  if S then -- already open: apply the current cell, then edit the new one in the same float
    C.apply()
    if S.pwin ~= win then
      close_impl(false, false)
    else
      api.nvim_set_current_win(S.win)
      return retarget(win, lnum, k, opts)
    end
  end
  local b = new_buf()
  local fw = api.nvim_open_win(b, true, { relative = "win", win = win, width = 20, height = 1, row = 0, col = 0,
    style = "minimal", border = "rounded", title = " ", title_pos = "left", zindex = 60 })
  vim.wo[fw].wrap, vim.wo[fw].linebreak = true, true
  S = { win = fw, buf = b }
  local ok, err = pcall(retarget, win, lnum, k, opts)
  if not ok then
    close_impl(false, false)
    error(err, 0)
  end
  return true
end

function C.open_at_cursor(opts)
  local win = api.nvim_get_current_win()
  local lnum, k, off = C.cell_under_cursor(win)
  if not lnum then
    vim.notify("mdtable cell editor: not in a table (the cursor is not on a table cell)", vim.log.levels.WARN)
    return false
  end
  -- the float's cursor at the start of the text (opts.at_cursor: at the
  -- cursor's offset in the cell, for i/a/I/A on a raw row)
  opts = opts or {}
  if opts.at_cursor and opts.col == nil then opts = vim.tbl_extend("force", opts, { col = off }) end
  return C.open(win, lnum, k, opts)
end

-- Break the undo sequence of buf before an apply: every apply is its own
-- undo step (API changes to a buffer that is not current would join).
local function undo_break(buf)
  local ul = vim.bo[buf].undolevels
  vim.bo[buf].undolevels = ul
end

function C.apply()
  if not S or not api.nvim_buf_is_valid(S.buf) then return false end
  if not api.nvim_buf_is_valid(S.pbuf) then return false end
  local text = C.text_of(api.nvim_buf_get_lines(S.buf, 0, -1, false))
  local c = cell_of(S.pbuf, S.lnum, S.k)
  if not c or c.k ~= S.k or c.cell.text ~= S.orig then
    vim.notify("mdtable cell editor: the cell changed outside the editor; not applied", vim.log.levels.WARN)
    return false
  end
  if text ~= c.cell.text then
    local s, e, line = c.cell.s, c.cell.e, c.row.line
    local ins = text
    if s == e and text ~= "" then -- an empty cell: keep a space next to the bars
      if line:sub(s, s) == "|" then ins = " " .. ins end
      if line:sub(e + 1, e + 1) == "|" then ins = ins .. " " end
    end
    -- in the parent window: the undo step records its cursor (the cell),
    -- not the float's (u would jump to the float's line and column)
    local pbuf, lnum = S.pbuf, S.lnum
    local function set()
      undo_break(pbuf)
      if api.nvim_get_current_buf() == pbuf then vim.fn.cursor(lnum + 1, s + 1) end
      api.nvim_buf_set_text(pbuf, lnum, s, lnum, e, { ins })
    end
    if api.nvim_win_is_valid(S.pwin) and api.nvim_win_get_buf(S.pwin) == pbuf then api.nvim_win_call(S.pwin, set) else set() end
    S.orig = text
    rerender(S.pwin)
  end
  vim.bo[S.buf].modified = false
  return true
end

-- Close the editor. apply: apply first. involuntary: the parent went away
-- (a change is discarded with a notice).
close_impl = function(apply, involuntary)
  if not S then return end
  if apply then C.apply() end
  local st = S
  local discarded = involuntary and dirty()
  S = nil
  pcall(api.nvim_del_augroup_by_name, "mdtable_celledit_open")
  if api.nvim_win_is_valid(st.win) then
    if api.nvim_get_current_win() == st.win then
      if api.nvim_get_mode().mode:sub(1, 1) == "i" then vim.cmd("stopinsert") end
      if st.pwin and api.nvim_win_is_valid(st.pwin) then pcall(api.nvim_set_current_win, st.pwin) end
    end
    local ok, err = pcall(api.nvim_win_close, st.win, true)
    if not ok then S = st; error(err, 0) end
  end
  if api.nvim_buf_is_valid(st.buf) then pcall(api.nvim_buf_delete, st.buf, { force = true }) end
  if discarded then vim.notify("cell edit discarded", vim.log.levels.INFO) end
  if st.pwin then rerender(st.pwin) end
end

function C.close(apply)
  local ok, err = pcall(close_impl, apply, false)
  C._err = not ok and tostring(err) or nil
  if not ok then
    vim.schedule(function() pcall(close_impl, false, false) end)
  end
end

function C.close_all()
  if S then C.close(false) end
end

-- Close an editor open on buffer buf (the renderer detaches from it).
function C.close_buf(buf)
  if S and S.pbuf == buf then C.close(false) end
end

-- The open key as typed, for the renderer's hint ("<Space>te", "\te").
function C.key_label()
  local l = vim.g.mapleader
  if l == nil then l = "\\" end
  if l == " " then l = "<Space>" end
  return (C.KEY:gsub("<[Ll]eader>", function() return l end))
end

function C.move(dir)
  if not S then return false end
  if not C.apply() then return false end
  local tbl, r = locate(S.pbuf, S.lnum)
  if not tbl then return false end
  local nr, nk = r, S.k
  if dir == "l" then
    nk = S.k + 1
  elseif dir == "h" then
    nk = S.k - 1
  elseif dir == "j" or dir == "k" then
    local step = dir == "j" and 1 or -1
    local x = r + step
    while tbl.rows[x] and tbl.rows[x].kind == "delim" do x = x + step end
    if tbl.rows[x] then nr = x end
  end
  nk = math.max(1, math.min(nk, #tbl.rows[nr].cells))
  if nr == r and nk == S.k then return false end -- at the table's edge
  return retarget(S.pwin, tbl.start_row + nr - 1, nk)
end

-- Opening from a table ----------------------------------------------------

local ag = api.nvim_create_augroup("mdtable_celledit", { clear = true })
api.nvim_create_autocmd("VimLeavePre", { group = ag, callback = function() C.close_all() end })

api.nvim_create_user_command("MdTableCellEdit", function() C.open_at_cursor() end,
  { desc = "Edit the Markdown table cell under the cursor in a float" })

return C
