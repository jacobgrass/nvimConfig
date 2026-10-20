-- Headless screen harness for mdtable (`nvim -l`): opens a buffer in a window
-- of the given size, drives keys, dumps the screen with `redraw!` +
-- screenstring() (extmarks render headless) and checks table alignment.
-- MDTABLE_OLD=<dir> runs the same tests against an older module tree (its
-- renders are vim.schedule'd, so the harness then spins the event loop).
local H = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h") .. "/helpers.lua")
local old = os.getenv("MDTABLE_OLD")
if old and old ~= "" then vim.opt.rtp:prepend(old) end
local api = vim.api
local S = { H = H, old = old ~= nil and old ~= "" }

S.notes = {}
local orig_notify = vim.notify
vim.notify = function(msg, level, o)
  S.notes[#S.notes + 1] = { msg = tostring(msg), level = level }
  if level and level >= vim.log.levels.ERROR then io.stdout:write("NOTIFY " .. tostring(msg) .. "\n") end
  return orig_notify and nil
end

local function flush()
  if S.old then vim.wait(40, function() return false end) end
end
S.flush = flush

-- Fresh tab showing `lines` (list) or a fixture name. Runs in a child nvim
-- with a UI attached (tests/uidriver.lua), which sets the screen size.
function S.open(src, setup)
  vim.o.laststatus, vim.o.showtabline, vim.o.cmdheight = 0, 0, 1
  vim.o.ruler, vim.o.showmode, vim.o.shortmess = false, false, "aoOstTWIcCF"
  vim.o.more = false
  local lines = type(src) == "table" and src or H.read(src)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_set_current_buf(buf)
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].expandtab, vim.bo[buf].shiftwidth, vim.bo[buf].tabstop = true, 2, 8
  local win = api.nvim_get_current_win()
  vim.wo[win].wrap, vim.wo[win].linebreak, vim.wo[win].number = true, false, false
  vim.wo[win].conceallevel, vim.wo[win].concealcursor = 3, "nvic"
  vim.wo[win].scrolloff = 0
  pcall(vim.treesitter.start, buf, "markdown") -- the highlighter parses on every change, as in the editor
  if setup then setup(buf, win) end
  require("custom.mdtable").attach(buf)
  flush()
  return buf, win
end

-- WP-K: the logical cursor (the active row's line and column while the
-- cursor is parked on the table's park line), 1-based line / 0-based col
function _G.LL() local m = package.loaded["custom.mdtable"]; return m and m.logical_cursor and m.logical_cursor(0)[1] or vim.fn.line(".") end
function _G.LC() local m = package.loaded["custom.mdtable"]; return m and m.logical_cursor and m.logical_cursor(0)[2] or vim.fn.col(".") - 1 end

function S.keys(k, stay_insert)
  api.nvim_feedkeys(api.nvim_replace_termcodes(k, true, false, true), stay_insert and "xt!" or "xt", false)
  flush()
end

function S.cursor(lnum, col) -- 0-based line, byte col
  api.nvim_win_set_cursor(0, { lnum + 1, col })
  api.nvim_exec_autocmds("CursorMoved", { buffer = api.nvim_get_current_buf() })
  flush()
end

-- Byte of the first non-blank character of cell j of line lnum (0-based),
-- splitting on unescaped pipes (fixture rows have a leading pipe).
function S.vis_col(lnum, j)
  local c = S.cell_col(lnum, j)
  local line = api.nvim_buf_get_lines(0, lnum, lnum + 1, false)[1]
  while line:sub(c + 1, c + 1):match("[`*_%[]") do c = c + 1 end
  return c
end

function S.cell_col(lnum, j)
  local line = api.nvim_buf_get_lines(0, lnum, lnum + 1, false)[1]
  local bars, i = {}, 0
  while true do
    local f = line:find("|", i + 1, true)
    if not f then break end
    if line:sub(f - 1, f - 1) ~= "\\" then bars[#bars + 1] = f - 1 end
    i = f
  end
  local s = bars[j] + 1
  while line:sub(s + 1, s + 1) == " " do s = s + 1 end
  return s
end

-- Screen rows of window `win` (default current) as strings.
function S.screen(win)
  win = (win == nil or win == 0) and api.nvim_get_current_win() or win
  vim.cmd("redraw!")
  local pos = api.nvim_win_get_position(win)
  local w, h = api.nvim_win_get_width(win), api.nvim_win_get_height(win)
  local out = {}
  for r = 1, h do
    local t = {}
    for c = 1, w do
      local ch = vim.fn.screenstring(pos[1] + r, pos[2] + c)
      t[c] = ch == "" and "\1" or ch -- right half of a wide character
    end
    out[r] = table.concat(t)
  end
  return out
end

local function cols_of(s, set)
  local out, c = {}, 0
  for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    c = c + 1
    if set[ch] then out[#out + 1] = c end
  end
  return out
end
local BARS = { ["│"] = true, ["├"] = true, ["┼"] = true, ["┤"] = true, ["┌"] = true, ["┬"] = true, ["┐"] = true,
  ["└"] = true, ["┴"] = true, ["┘"] = true }

-- Alignment check: in every rendered table block (┌ .. └), every line's bar
-- columns equal the top border's; no raw `| ... |` row inside or outside a
-- block (allow_raw: number of raw rows tolerated, e.g. ragged rows).
-- A clip marker line (`│ … N more rows … │`) has only the outer bars, at the
-- block's outer columns; it starts a block (top clipped) or ends one.
-- Returns errors, blocks ({ top, bottom, cols, markers }).
local function is_marker(s) -- " … N more rows … ", or "…N…" / "…" in a narrow table
  return s:find("…", 1, true) ~= nil and (s:find("more row", 1, true) ~= nil or s:match("│%s*…%d*…?%s*│%s*$") ~= nil)
end
S.is_marker = is_marker
local function outer(cc) return #cc > 0 and (cc[1] .. "," .. cc[#cc]) or "" end
function S.check(rows, allow_raw)
  local errs, blocks = {}, {}
  local cur
  local raw = 0
  local in_raw = false -- after a tolerated raw row: its wrapped screen rows (no box characters)
  -- (the first row that is not the note above a virtual row, WP-J: the
  -- window's top for a grid scrolled off at the top)
  local top_i = 1
  while rows[top_i] and rows[top_i]:find("tall row: Ctrl-hjkl select a cell", 1, true) do top_i = top_i + 1 end
  for i, s in ipairs(rows) do
    -- the note init.lua draws above a virtual (tall) row (WP-J; before it,
    -- the hint above a row drawn raw) is not a grid line
    if s:find("row too tall to render here", 1, true) or s:find("tall row: Ctrl-hjkl select a cell", 1, true) then goto continue end
    local first = s:match("^%s*(%S)")
    local marker = is_marker(s)
    local cc = cols_of(s, BARS)
    if in_raw and #cc == 0 and not marker then goto continue end
    local after_raw = in_raw -- a raw line at the window top: the grid under it starts a block
    in_raw = false
    local starts = s:find("┌", 1, true) or (i == top_i and not cur and (BARS[s:match("^%s*([\226][\128-\191][\128-\191])") or ""]))
      or (marker and not (cur and cur.cols)) or (after_raw and not cur and #cc > 0)
    if starts then -- a block starts at its top border or a top marker, or at row 1 when the top is scrolled off
      cur = { top = i, cols = not marker and table.concat(cc, ",") or nil, outer = outer(cc), markers = marker and 1 or 0,
        clipped = i == top_i and not s:find("┌", 1, true) }
      if marker and #cc ~= 2 then errs[#errs + 1] = ("row %d: marker with %d bars: %q"):format(i, #cc, s) end
      blocks[#blocks + 1] = cur
      if after_raw and s:find("└", 1, true) then cur.bottom = i; cur = nil end -- a raw row's closing border
    elseif not cur and first == "|" and raw < (allow_raw or 0) then
      -- a tolerated raw row at the window top, its hint scrolled off (WP-I:
      -- rows are raw per row, so also in cell 1 after G)
      raw, first, in_raw = raw + 1, nil, true
    elseif cur and first == "|" and raw < (allow_raw or 0) then
      raw = raw + 1 -- a ragged row (or a row taller than the window) drawn raw inside the block
      first = nil
      in_raw = true
    elseif cur then
      local c = table.concat(cc, ",")
      local nxt = rows[i + 1]
      if nxt and nxt:find("tall row: Ctrl-hjkl select a cell", 1, true) then nxt = rows[i + 2] end -- (the note, WP-J)
      if marker and nxt and cur.cols ~= "" and (table.concat(cols_of(nxt, BARS), ",") == cur.cols
          or (nxt:match("^%s*|") and raw < (allow_raw or 0))) then -- or a tolerated raw row continues the grid
        -- mid-block marker (the sticky header float carries the clip marker
        -- under its delimiter): outer bars only, the grid continues below
        if #cc ~= 2 or outer(cc) ~= cur.outer then
          errs[#errs + 1] = ("row %d: marker bars at %s, block outer bars at %s: %q"):format(i, c, cur.outer, s)
        end
        cur.markers = cur.markers + 1
      elseif marker then -- bottom marker: outer bars only, closes the block
        if #cc ~= 2 or outer(cc) ~= cur.outer then
          errs[#errs + 1] = ("row %d: marker bars at %s, block outer bars at %s: %q"):format(i, c, cur.outer, s)
        end
        cur.markers, cur.bottom = cur.markers + 1, i
        cur = nil
      elseif not cur.cols then -- first line under a top marker
        if c == "" then
          errs[#errs + 1] = ("row %d: no table line under a marker: %q"):format(i, s)
        elseif outer(cc) ~= cur.outer then
          errs[#errs + 1] = ("row %d: outer bars at %s, marker's at %s: %q"):format(i, outer(cc), cur.outer, s)
        end
        cur.cols = c
      elseif c ~= cur.cols and not (c == "" and s:match("^%s*$")) then
        errs[#errs + 1] = ("row %d: bars at %s, header at %s: %q"):format(i, c, cur.cols, s)
      end
      if cur and s:find("└", 1, true) then cur.bottom = i; cur = nil end
    end
    if first == "|" then
      raw = raw + 1
      if raw > (allow_raw or 0) then errs[#errs + 1] = ("row %d: raw table row %q"):format(i, s) else in_raw = true end
    end
    ::continue::
  end
  return errs, blocks
end

function S.dump(rows, label)
  print("---- " .. (label or "screen"))
  for i, s in ipairs(rows) do print(("%2d|%s"):format(i, s)) end
end

-- Assert aligned; on failure dump the screen and raise.
function S.aligned(label, allow_raw, win)
  local rows = S.screen(win)
  local errs, blocks = S.check(rows, allow_raw)
  if #errs > 0 or #blocks == 0 then
    S.dump(rows, label)
    error(label .. ": " .. (#blocks == 0 and "no rendered table" or table.concat(errs, "\n")), 2)
  end
  return rows, blocks
end

function S.errors()
  local e = {}
  for _, n in ipairs(S.notes) do
    if n.level and n.level >= vim.log.levels.ERROR then e[#e + 1] = n.msg end
  end
  return e
end

return S
