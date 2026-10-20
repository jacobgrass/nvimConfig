-- custom.mdtable.project: pure projection of a laid-out table onto marks.
-- No buffer or window API: inputs are the scan model (scan.lua), the layout
-- (layout.lua) and the window text width; outputs are plain mark specs that
-- draw.lua applies. Results are memoized per layout object (weak keys) and
-- are read-only.
--
-- Rendering model (spike E2, kept):
-- * Rows that are not the anchor line are hidden with `conceal_lines` and drawn
--   as virtual grid lines (`virt_lines`).
-- * Anchor rule (project.anchors): every table has exactly one visible line,
--   its anchor. With the cursor inside the table the anchor is the cursor
--   line; otherwise it is the table's first line (the header), never a line
--   outside the table. The grid lines before the anchor row hang above it
--   (`virt_lines_above`), the ones after it below it (`virt_lines`).
-- * Cursor row (project.cursor_row): only the cursor's cell is real text. All
--   other bytes are concealed and redrawn: an inline spacer moves the real
--   text to its column and a `virt_text_win_col` overlay paints the grid on
--   the spacer; a second overlay paints the grid right of the text. Soft-wrap
--   breaks at RAW width (concealed bytes count), so inline padding puts each
--   break exactly at the window edge: one grid line = one screen line.
--   Concealed bytes that do not fit add spill rows (above the grid when the
--   prefix before the cell is too wide, below it otherwise). opts.spill
--   (vim.g.mdtable_spill) picks what the k spill rows above carry:
--   "flow" (default): the last k grid lines above the row (its separator,
--   the previous rows, the delimiter, header and top border near the top),
--   taken off the block drawn above, so nothing moves and no blank row
--   appears; rows beyond the lines above fall back to "cell". Spill rows
--   below likewise carry the first lines of the block below.
--   "row": blank bordered rows above the whole row (the first one carries
--   the row's separator). "cell": the row's own grid lines 1..k with only
--   the edited cell's column empty, its text starting on line k + 1.
-- * Per row (WP-I): moving between the cells of a row moves nothing on
--   screen. project.row_info() gives the row-level values: every cell is
--   drawn with the row's grid lines (nl), the raw decision (init.lua: the
--   tallest cell's line taller than the window), the clip cuts, the sticky
--   header rule and scroll-to-fit use the row's values, and init.lua keeps
--   topfill following lines_in_line when the cursor line is at the window
--   top. The screen text is the same in every cell too (WP-I round 3):
--   "flow" spill rows beyond the table's lines above carry the buffer lines
--   above the table (opts.ext: concealed and redrawn while the cursor is on
--   that row; empty rows above the table's top border when the buffer has
--   too few lines above it), never the row's own lines; a "flow" row whose
--   frame (the rows that show every cell's line from one view: max
--   lines_in_line + max depth) is taller than the window is drawn raw (the
--   round-2 "cell" spill fallback moved the edited column's text). "row"
--   and "cell" keep their blank spill rows, so their rows may still change
--   height by cell. "flow" rows past the table's end are empty rows,
--   matched by empty virtual lines in the other cells.
-- * Covered row (project.covered_row): an anchor line with no real cell (the
--   header while the cursor is outside the table, or the delimiter row under
--   the cursor). The whole line is concealed and every screen row it occupies
--   carries the next grid line as an overlay, so it adds no blank rows.
-- * Virtual cursor row (project.tall_row, WP-J): a row taller than the
--   window (init.lua's predicate) is drawn like a covered row while the
--   cursor is on it, on the grid of hl_grid (the active cell and its header
--   cell highlighted, the text identical), so moving between its cells
--   changes highlights only. `off` scrolls inside the row: the first `off`
--   lines of the row move from the line to the block above (init.lua keeps
--   the view, so every screen row moves by one line per step).
--
-- Mark specs: { col, opts } (the row is the anchor line, supplied by draw).
local M = {}
local strwidth = vim.api.nvim_strwidth

M.HL = { fill = "MdTableFill", head_b = "MdTableHead", row_b = "MdTableRow", head_t = "@markup.heading", row_t = "Normal",
  more = "MdTableMore", active = "MdTableActiveCell", active_col = "MdTableActiveCol" }
local HL = M.HL

local function emit(out, text, hl)
  if text == "" then return out end
  local last = out[#out]
  if last and last[2] == hl then last[1] = last[1] .. text else out[#out + 1] = { text, hl } end
  return out
end
M._emit = emit

local function utf8len(b)
  if b < 0x80 then return 1 elseif b >= 0xF0 then return 4 elseif b >= 0xE0 then return 3 elseif b >= 0xC0 then return 2 end
  return 1
end

-- Visible text of bytes [s, e) of a cell: concealed ranges removed, icon
-- marks inserted before their `at` byte.
local function pieces(out, line, cell, s, e, hl)
  local cs, ce, marks = cell.cs, cell.ce, cell.marks
  local nm, mi, nc, k, p = #marks, 1, #cs, 1, s
  while mi <= nm and marks[mi].at < s do mi = mi + 1 end
  while k <= nc and ce[k] <= p do k = k + 1 end
  while p < e do
    if k <= nc and cs[k] <= p then
      local stop = ce[k] < e and ce[k] or e
      while mi <= nm and marks[mi].at < stop do emit(out, marks[mi].text, marks[mi].hl or hl); mi = mi + 1 end
      p, k = stop, k + 1
    else
      local stop = e
      if k <= nc and cs[k] < stop then stop = cs[k] end
      while mi <= nm and marks[mi].at < stop do
        local at = marks[mi].at
        if at > p then emit(out, line:sub(p + 1, at), hl); p = at end
        emit(out, marks[mi].text, marks[mi].hl or hl)
        mi = mi + 1
      end
      emit(out, line:sub(p + 1, stop), hl)
      p = stop
    end
  end
  return out
end

local function hls(kind)
  if kind == "header" then return HL.head_b, HL.head_t end
  return HL.row_b, HL.row_t
end

-- Cells j1..j2 of grid line li: " " pad text pad " " "│" each.
local function cells_into(out, tbl, widths, row, lr, li, j1, j2, hb, ht)
  for j = j1, j2 do
    local ch = lr and lr.cells[j] and lr.cells[j].chunks[li]
    if ch then
      emit(out, " " .. string.rep(" ", ch.pad_left), ht)
      if ch.e > ch.s then pieces(out, row.line, row.cells[j], ch.s, ch.e, ht) end
      emit(out, string.rep(" ", ch.pad_right) .. " ", ht)
    else
      emit(out, string.rep(" ", widths[j] + 2), ht)
    end
    emit(out, "│", hb)
  end
  return out
end

local function border(tbl, widths, l, m, r, hl)
  local parts = {}
  for j, w in ipairs(widths) do parts[j] = string.rep("─", w + 2) end
  local out = emit({}, string.rep(" ", tbl.indent or 0), HL.fill)
  return emit(out, l .. table.concat(parts, m) .. r, hl)
end

local function full_line(tbl, widths, row, lr, li)
  local hb, ht = hls(row and row.kind)
  local out = emit({}, string.rep(" ", tbl.indent or 0), HL.fill)
  emit(out, "│", hb)
  return cells_into(out, tbl, widths, row, lr, li, 1, tbl.ncols, hb, ht)
end

-- Raw text of a ragged row split into window-wide virtual lines.
local function raw_lines(line, W, n)
  local out, cur, cw, i = {}, {}, 0, 0
  while i < #line do
    local nb = utf8len(line:byte(i + 1))
    local ch = line:sub(i + 1, i + nb)
    local w = nb == 1 and 1 or strwidth(ch)
    if cw + w > W and cw > 0 then out[#out + 1] = { { table.concat(cur), "Normal" } }; cur, cw = {}, 0 end
    cur[#cur + 1], cw, i = ch, cw + w, i + nb
  end
  out[#out + 1] = { { table.concat(cur), "Normal" } }
  while #out < n do out[#out + 1] = { { "", "Normal" } } end
  return out
end

-- The table's full virtual grid, memoized per layout object:
--   lines  flat list of grid lines (chunk lists) from top to bottom border
--   first[r], count[r]  index in `lines` of row r's first line, line count
--   sep[r]  index of the separator line above body row r (separators on)
--   left[k] display column where cell k's content area starts
--   blank   a blank bordered body line
local gmemo = setmetatable({}, { __mode = "k" })
-- grid lines of one row, by (row id, column widths, indent, width): typing
-- in one row re-renders only that row's virtual lines
local rowmemo, rowmemo_n = {}, 0
-- Visible text of bytes [s, e) of a cell (icons included), as chunks.
function M.text_of(row, cell, s, e) return pieces({}, row.line, cell, s, e, HL.row_t) end

function M.grid(tbl, lay, opts)
  local g = gmemo[lay]
  if g then return g end
  local W = opts and opts.width or 80
  local seps = opts and opts.separators
  local widths = lay.widths
  local lines, first, count, sep = {}, {}, {}, {}
  local wsig = table.concat(widths, ",") .. "|" .. (tbl.indent or 0) .. "|" .. W
  local function cached_border(kind, l, m, r, hl)
    local bk = kind .. "|" .. wsig
    local b = rowmemo[bk]
    if not b then b = border(tbl, widths, l, m, r, hl); rowmemo[bk], rowmemo_n = b, rowmemo_n + 1 end
    return b
  end
  lines[1] = cached_border("top", "┌", "┬", "┐", HL.head_b)
  local first_body = true
  for r, row in ipairs(tbl.rows) do
    local lr = lay.rows[r]
    if row.kind == "delim" then
      lines[#lines + 1] = cached_border("mid", "├", "┼", "┤", HL.row_b)
      first[r], count[r] = #lines, 1
    else
      if row.kind == "body" then
        if not first_body and seps then
          lines[#lines + 1] = cached_border("mid", "├", "┼", "┤", HL.row_b)
          sep[r] = #lines
        end
        first_body = false
      end
      first[r] = #lines + 1
      local rk = row.id and (row.id .. "|" .. wsig)
      local rl = rk and rowmemo[rk]
      if not rl then
        if row.ragged then
          rl = raw_lines(row.line, W, lr.lines)
        else
          rl = {}
          for li = 1, lr.lines do rl[li] = full_line(tbl, widths, row, lr, li) end
        end
        if rk then
          if rowmemo_n > 2048 then rowmemo, rowmemo_n = {}, 0 end
          rowmemo[rk], rowmemo_n = rl, rowmemo_n + 1
        end
      end
      for _, l in ipairs(rl) do lines[#lines + 1] = l end
      count[r] = #lines - first[r] + 1
    end
  end
  lines[#lines + 1] = cached_border("bottom", "└", "┴", "┘", HL.row_b)
  local left, x = {}, (tbl.indent or 0) + 1
  for k = 1, tbl.ncols do left[k] = x + 1; x = x + widths[k] + 3 end
  g = { lines = lines, first = first, count = count, sep = sep, left = left, widths = widths,
    blank = full_line(tbl, widths, nil, nil, 1), empty = { { "", HL.fill } }, W = W, slices = {}, proj = {} }
  gmemo[lay] = g
  return g
end

-- Signature of a block: the identities of its lines (row lines and borders
-- are memoized across layouts, so an unchanged block keeps its signature
-- after an edit elsewhere in the table). Memoized per block.
local sigmemo = setmetatable({}, { __mode = "k" })
function M.block_sig(block)
  local sg = sigmemo[block]
  if not sg then
    local t = {}
    for i, l in ipairs(block) do t[i] = tostring(l):sub(8) end
    sg = table.concat(t, ",")
    sigmemo[block] = sg
  end
  return sg
end

-- lines[a..b] as a list, memoized so an unchanged block keeps its identity.
function M.slice(g, a, b)
  if b < a then a, b = 1, 0 end
  local key = a .. ":" .. b
  local s = g.slices[key]
  if not s then
    s = {}
    for i = a, b do s[#s + 1] = g.lines[i] end
    g.slices[key] = s
  end
  return s
end

local function concat_slice(g, extra, a, b)
  if #extra == 0 then return M.slice(g, a, b) end
  local key = "x" .. tostring(extra) .. ":" .. a .. ":" .. b
  local s = g.slices[key]
  if not s then
    s = {}
    for _, l in ipairs(extra) do s[#s + 1] = l end
    for i = a, b do s[#s + 1] = g.lines[i] end
    g.slices[key] = s
  end
  return s
end

-- Anchor rule (see header). cursor_row: 0-based cursor line or nil.
-- Cursor below the table: the anchor is the table's LAST line (grid tail on
-- its screen rows, the rest above it), so nothing hangs below the table.
-- Neovim counts virt_lines below the header (filler of the concealed next
-- line) as filler of the first visible line after the table; with more of it
-- than the window is tall, `k`/`:N` from below cannot reach that line
-- (reproduced with plain extmarks, wpB/dbg/gk3.lua).
function M.anchors(tbl, cursor_row)
  local inside = cursor_row ~= nil and cursor_row >= tbl.start_row and cursor_row < tbl.end_row
  local below = cursor_row ~= nil and cursor_row >= tbl.end_row
  local anchor = inside and cursor_row or (below and tbl.end_row - 1 or tbl.start_row)
  local conceal = {}
  for l = tbl.start_row, tbl.end_row - 1 do
    if l ~= anchor then conceal[#conceal + 1] = l end
  end
  return { anchor = anchor, inside = inside, below = below, row = anchor - tbl.start_row + 1, conceal = conceal }
end

-- Virtual blocks around row `exclude` (nil: the covered header). Returns
-- { above, sep, below_from } where above = lines before the row (without its
-- separator), sep = the separator line above it (or nil), below_from = index
-- of the first line after the row.
function M.virtual_rows(tbl, lay, exclude, opts)
  local g = M.grid(tbl, lay, opts)
  local r = exclude or 1
  local a = g.sep[r] or g.first[r]
  return { above = M.slice(g, 1, a - 1), sep = g.sep[r] and g.lines[g.sep[r]] or nil,
    below_from = g.first[r] + g.count[r], below = M.slice(g, g.first[r] + g.count[r], #g.lines), grid = g }
end

-- Viewport clipping (init.lua decides `keep` from the window height and
-- view): Neovim mislands the cursor when a line's filler is taller than the
-- window, so no block may exceed the window. A clipped block keeps the lines
-- nearest its anchor (the end of an "above" block, the start of a "below"
-- one) and carries a marker line `│ … N more rows … │` on the far side.

-- The marker line across the grid's full width (N = table rows left out).
function M.marker(g, tbl, n)
  g.markers = g.markers or {}
  local mk = g.markers[n]
  if mk then return mk end
  local inner = -1
  for _, w in ipairs(g.widths) do inner = inner + w + 3 end
  local text = (" … %d more row%s … "):format(n, n == 1 and "" or "s")
  if strwidth(text) > inner then text = ("…%d…"):format(n) end
  if strwidth(text) > inner then text = "…" end
  local tw = strwidth(text)
  local lpad = math.floor((inner - tw) / 2)
  mk = emit({}, string.rep(" ", tbl.indent or 0), HL.fill)
  emit(mk, "│", HL.row_b)
  emit(mk, string.rep(" ", lpad), HL.row_t)
  emit(mk, text, HL.more)
  emit(mk, string.rep(" ", inner - tw - lpad), HL.row_t)
  emit(mk, "│", HL.row_b)
  g.markers[n] = mk
  return mk
end

-- grid line object -> table row index (header/body rows only)
local function rowof(g, tbl)
  local ro = g.rowof
  if ro then return ro end
  ro = {}
  for r, row in ipairs(tbl.rows) do
    if row.kind ~= "delim" and g.first[r] then
      for i = g.first[r], g.first[r] + g.count[r] - 1 do ro[g.lines[i]] = r end
    end
  end
  g.rowof = ro
  return ro
end

-- `block` cut to at most `keep` (>= 1) lines including the marker; the cut
-- falls on a row boundary when the kept part has one. Memoized per block, so
-- an unchanged clip keeps its identity (and draw.lua leaves its mark alone).
-- lim (>= 0): the boundary search leaves out the lim lines next to the
-- anchor, which other cells of the cursor row draw on the line itself
-- (WP-I: the same cut, so the same screen rows and marker, in every cell).
local clipmemo = setmetatable({}, { __mode = "k" })
function M.clip(g, tbl, block, keep, side, lim)
  local n = #block
  if n <= keep then return block end
  local per = clipmemo[block]
  if not per then per = {}; clipmemo[block] = per end
  lim = math.max(lim or 0, 0)
  local key = side .. keep .. ":" .. lim
  if per[key] then return per[key] end
  local ro = rowof(g, tbl)
  local hidden, cnt = {}, 0
  local function hide(l)
    local r = ro[l]
    if r and not hidden[r] then hidden[r], cnt = true, cnt + 1 end
  end
  local res = {}
  if side == "above" then
    local s = n - keep + 2 -- first kept line
    local s2 = s
    while s2 <= n - lim and ro[block[s2]] and ro[block[s2]] == ro[block[s2 - 1]] do s2 = s2 + 1 end
    if s2 <= n - lim then s = s2 end
    for i = 1, s - 1 do hide(block[i]) end
    res[1] = M.marker(g, tbl, cnt)
    for i = s, n do res[#res + 1] = block[i] end
  else
    local e = keep - 1 -- last kept line
    local e2 = e
    while e2 >= 1 + lim and ro[block[e2]] and ro[block[e2]] == ro[block[e2 + 1]] do e2 = e2 - 1 end
    if e2 >= 1 + lim then e = e2 end
    for i = 1, e do res[i] = block[i] end
    for i = e + 1, n do hide(block[i]) end
    res[#res + 1] = M.marker(g, tbl, cnt)
  end
  per[key] = res
  return res
end

-- Bar byte before each cell (the `|`, or a virtual one), memoized per row.
local bmemo = setmetatable({}, { __mode = "k" })
function M.bars(row)
  local b = bmemo[row]
  if b then return b end
  b = {}
  local line, cells = row.line, row.cells
  for j, c in ipairs(cells) do
    local lo = j > 1 and cells[j - 1].e or 0
    local x = c.s - 1
    while x >= lo and line:byte(x + 1) ~= 124 do x = x - 1 end
    if x < lo then x = c.s - 1 end
    b[j] = x
  end
  bmemo[row] = b
  return b
end

-- The cursor's cell: the first j whose next bar is right of col (old rule).
function M.cell_at(row, col)
  local bars = M.bars(row)
  for j = 1, #row.cells - 1 do
    if col < bars[j + 1] then return j end
  end
  return #row.cells
end

-- Characters of a line as parallel arrays B (byte), N (bytes), R (raw width),
-- V (visible width: only inside [vs, ve) and not concealed by `cell`), with
-- zero-byte pseudo characters for the icon marks of every cell.
local function line_chars(row, cell, vs, ve, ts)
  local line = row.line
  local marks = {}
  for _, c in ipairs(row.cells) do
    for _, m in ipairs(c.marks) do marks[#marks + 1] = m end
  end
  table.sort(marks, function(a, b) return a.col < b.col end)
  local B, N, R, V = {}, {}, {}, {}
  local n, mi, i, len, col = 0, 1, 0, #line, 0
  local cs, ce = cell and cell.cs or {}, cell and cell.ce or {}
  local kc, nc = 1, #cs
  while true do
    while marks[mi] and marks[mi].col <= i do
      n = n + 1
      B[n], N[n], R[n], V[n] = i, 0, marks[mi].width, marks[mi].width
      col, mi = col + marks[mi].width, mi + 1
    end
    if i >= len then break end
    local b = line:byte(i + 1)
    local nb, w
    if b < 0x80 then
      nb = 1
      w = b == 9 and (ts - col % ts) or 1
    else
      nb = utf8len(b)
      w = strwidth(line:sub(i + 1, i + nb))
    end
    n = n + 1
    B[n], N[n], R[n] = i, nb, w
    local vis = 0
    if i >= vs and i < ve then
      while kc <= nc and ce[kc] <= i do kc = kc + 1 end
      if not (kc <= nc and cs[kc] <= i) then vis = w end
    end
    V[n] = vis
    i, col = i + nb, col + w
  end
  return { B = B, N = N, R = R, V = V, n = n }
end

local function sum(arr, a, b)
  local s = 0
  for x = a, b do s = s + arr[x] end
  return s
end

-- Screen rows of chars a..b starting at column col: the first byte of each
-- new screen row.
local function place(L, a, b, col, W)
  local starts = {}
  local R, B = L.R, L.B
  for x = a, b do
    if col + R[x] > W and col > 0 then starts[#starts + 1] = B[x]; col = 0 end
    col = col + R[x]
  end
  return starts, col
end

local function align_pad(align, cw, vis)
  local free = math.max(cw - vis, 0)
  if align == "right" then return free end
  if align == "center" then return math.floor(free / 2) end
  return 0
end

local function conceal(marks, a, b)
  if b > a then marks[#marks + 1] = { a, { end_col = b, conceal = "" } } end
end
local function inline(marks, col, w)
  if w > 0 then
    marks[#marks + 1] = { col, { virt_text = { { string.rep(" ", w), HL.fill } }, virt_text_pos = "inline" } }
  end
end
local function overlay(marks, col, wincol, chunks)
  marks[#marks + 1] = { col, { virt_text = chunks, virt_text_win_col = wincol, virt_text_hide = true } }
end

-- Covered row r: the whole line concealed; its screen rows carry grid lines
-- g.lines[from], g.lines[from + 1], ... Returns { marks, consumed, rows }.
function M.covered_row(tbl, lay, r, opts)
  local g = M.grid(tbl, lay, opts)
  local key = "c" .. r
  if g.proj[key] then return g.proj[key] end
  local row = tbl.rows[r]
  local W = opts.width
  local from = g.sep[r] or g.first[r]
  local L = line_chars(row, nil, 0, 0, opts.tabstop or 8)
  local marks = {}
  conceal(marks, 0, #row.line)
  local starts = place(L, 1, L.n, 0, W)
  local last = #g.lines
  overlay(marks, 0, 0, g.lines[from])
  for i, b in ipairs(starts) do
    if from + i <= last then overlay(marks, b, 0, g.lines[from + i]) end
  end
  local consumed = math.min(#starts + 1, last - from + 1)
  local res = { marks = marks, rows = #starts + 1, from = from, consumed = consumed, starts = starts,
    above = M.slice(g, 1, from - 1), below = M.slice(g, from + consumed, last), height = #starts + 1 }
  g.proj[key] = res
  return res
end

-- Covered last row (cursor below the table): the line's screen rows carry
-- the LAST grid lines (ending with the bottom border); everything else hangs
-- above it. Returns { marks, above, below = {}, rows }.
function M.covered_tail(tbl, lay, opts)
  local g = M.grid(tbl, lay, opts)
  if g.proj.tail then return g.proj.tail end
  local r = #tbl.rows
  local row = tbl.rows[r]
  local L = line_chars(row, nil, 0, 0, opts.tabstop or 8)
  local starts = place(L, 1, L.n, 0, opts.width)
  local S = #starts + 1
  local last = #g.lines
  local from = math.max(1, last - S + 1)
  local marks = {}
  conceal(marks, 0, #row.line)
  overlay(marks, 0, 0, g.lines[from])
  for i, b in ipairs(starts) do
    if from + i <= last then overlay(marks, b, 0, g.lines[from + i]) end
  end
  local res = { marks = marks, rows = S, from = from, above = M.slice(g, 1, from - 1), below = M.slice(g, 1, 0) }
  g.proj.tail = res
  return res
end

-- Grid line li of row `row` with cell k's content (pad and text) in hlk;
-- the bars keep the row's group.
local function hl_line(tbl, widths, row, lr, li, k, hlk)
  local hb, ht = hls(row.kind)
  local out = emit({}, string.rep(" ", tbl.indent or 0), HL.fill)
  emit(out, "│", hb)
  cells_into(out, tbl, widths, row, lr, li, 1, k - 1, hb, ht)
  cells_into(out, tbl, widths, row, lr, li, k, k, hb, hlk)
  return cells_into(out, tbl, widths, row, lr, li, k + 1, tbl.ncols, hb, ht)
end

-- The grid of M.grid with the active cell (row r, cell k) in HL.active and
-- the header cell of column k in HL.active_col (WP-J). Same text and line
-- count; only those rows' lines are new objects (block signatures of the
-- rest stay). Memoized on the grid per (r, k); own slices and projections.
function M.hl_grid(tbl, lay, opts, r, k)
  local g = M.grid(tbl, lay, opts)
  g.hl = g.hl or {}
  local key = r .. ":" .. k
  local hg = g.hl[key]
  if hg then return hg end
  local lines = {}
  for i, l in ipairs(g.lines) do lines[i] = l end
  local function paint(x, hlk)
    local row, lr = tbl.rows[x], lay.rows[x]
    if not (row and lr and g.first[x]) or row.kind == "delim" or row.ragged or k > #row.cells then return end
    for li = 1, g.count[x] do lines[g.first[x] + li - 1] = hl_line(tbl, lay.widths, row, lr, li, k, hlk) end
  end
  for x, row in ipairs(tbl.rows) do if row.kind == "header" then paint(x, HL.active_col) end end
  paint(r, HL.active)
  hg = { lines = lines, first = g.first, count = g.count, sep = g.sep, left = g.left, widths = g.widths, blank = g.blank,
    empty = g.empty, W = g.W, slices = {}, proj = {}, base = g }
  g.hl[key] = hg
  return hg
end

-- Virtual cursor row r (WP-J), active cell k: the line is a covered row
-- (every byte concealed; each of its screen rows carries a grid line as an
-- overlay, as the header does while the cursor is outside the table) over
-- the "tape" of hl_grid: the cursor stays on its own visible line, and the
-- screen text is the same in every cell. off (clamped to the row's lines):
-- in-row scroll, the row's first off lines move to the block above. hint
-- (a virtual line or nil): a note drawn right above the row (its
-- separator). Memoized per (r, k, off, hint). Returns { marks, above,
-- below, rows (screen rows of the line), consumed (tape lines on it), s
-- (tape index on its first screen row), from_t (the row's separator or
-- first line), first_t, last_t (the row's lines), ntape, off, k, g }.
function M.tall_row(tbl, lay, r, k, off, opts, hint)
  local hg = M.hl_grid(tbl, lay, opts, r, k)
  local from = hg.sep[r] or hg.first[r]
  local tg = hg
  if hint then
    hg.tapes = hg.tapes or {}
    tg = hg.tapes[hint]
    if not tg then
      local lines = {}
      for i = 1, from - 1 do lines[i] = hg.lines[i] end
      lines[from] = hint
      for i = from, #hg.lines do lines[i + 1] = hg.lines[i] end
      tg = { lines = lines, slices = {} }
      hg.tapes[hint] = tg
    end
  end
  local d = hint and 1 or 0
  local from_t, first_t = from + d, hg.first[r] + d
  local last_t = first_t + hg.count[r] - 1
  off = math.max(0, math.min(off or 0, last_t - from_t))
  local key = "T" .. r .. ":" .. k .. ":" .. off .. (hint and (":" .. tostring(hint)) or "")
  local res = hg.proj[key]
  if res then return res end
  local cov = M.covered_row(tbl, lay, r, opts)
  local tape, row = tg.lines, tbl.rows[r]
  local s = from_t + off
  local marks = {}
  conceal(marks, 0, #row.line)
  overlay(marks, 0, 0, tape[s] or hg.empty)
  for i, b in ipairs(cov.starts) do overlay(marks, b, 0, tape[s + i] or hg.empty) end
  local consumed = math.max(0, math.min(cov.rows, #tape - s + 1))
  res = { marks = marks, rows = cov.rows, consumed = consumed, s = s, from_t = from_t, first_t = first_t, last_t = last_t,
    ntape = #tape, off = off, k = k, g = hg, above = M.slice(tg, 1, s - 1), below = M.slice(tg, s + consumed, #tape) }
  hg.proj[key] = res
  return res
end

-- Cursor row r with the real cell k. opts: { width = W, separators, tabstop }.
-- Returns { marks, extra (virtual lines that follow the row), above, below,
-- rows (screen rows of the line incl. spill), spill_above, spill_below,
-- used_sep, height (grid height incl. separator and own lines), nav, nl }.
-- nav[li] = { b = {}, n = {}, w = {}, col = {} }: visible characters of the
-- real cell per grid line and their columns inside the cell.
-- nlmin (optional): draw the row with at least nlmin grid lines (nl), so
-- every cell of a row has the same height (row_info().nl, WP-I); the extra
-- lines are the row's blank grid lines, after the cell's text.
-- after (optional, "flow"): screen rows past the table's end that the row's
-- longest line takes (row_info().after); a cell whose line ends sooner gets
-- empty virtual lines after the table instead, so text below stays put.
function M.cursor_row(tbl, lay, r, k, opts, nlmin, after)
  local g = M.grid(tbl, lay, opts)
  local mode = (opts.spill == "row" or opts.spill == "cell") and opts.spill or "flow"
  local key = r .. ":" .. k .. ":" .. mode .. (opts.ext and (":e" .. tostring(opts.ext)) or "")
  if after then
    local nat = M.cursor_row(tbl, lay, r, k, opts, nlmin)
    if mode ~= "flow" or after <= nat.blank_below then return nat end
    key = key .. ":p" .. (nlmin or 0) .. ":a" .. after
    if g.proj[key] then return g.proj[key] end
    local res = setmetatable({}, { __index = nat })
    local below = vim.list_slice(nat.below)
    for _ = nat.blank_below + 1, after do below[#below + 1] = g.empty end
    res.below = below
    g.proj[key] = res
    return res
  end
  if nlmin then
    local nat = M.cursor_row(tbl, lay, r, k, opts)
    if nat.nl >= nlmin then return nat end
    key = key .. ":p" .. nlmin
  end
  if g.proj[key] then return g.proj[key] end
  local W = opts.width
  local row, lr = tbl.rows[r], lay.rows[r]
  local widths = lay.widths
  local hb, ht = hls(row.kind)
  local line = row.line
  local c, cw = row.cells[k], widths[k]
  local align = tbl.aligns[k]
  local bars = M.bars(row)
  -- the first line's spacer sits on the byte just before the text (a
  -- concealed space or the bar): the whitespace between the bar and the text
  -- belongs to the prefix (which may spill above), so a cell typed against
  -- the far bar of a padded row cannot overflow its screen row, and an
  -- insert-mode cursor on the text's first byte is drawn after the spacer
  local anchor1 = math.max(c.s - 1, 0)
  local L = line_chars(row, c, c.s, c.e, opts.tabstop or 8)
  local B, N, R, V, nL = L.B, L.N, L.R, L.V, L.n
  local function first_at(b)
    for x = 1, nL do if B[x] >= b then return x end end
    return nL + 1
  end
  local ia, ics = first_at(anchor1), first_at(c.s)
  local ice = ics - 1
  for x = ics, nL do
    if B[x] < c.e or (N[x] == 0 and B[x] == c.e) then ice = x else break end
  end
  local lwb = g.left[k]
  local raw_lead, vis_lead = sum(R, ia, ics - 1), sum(V, ia, ics - 1)
  -- segments: the layout's chunks of the real cell, split further only when a
  -- chunk's raw width (concealed bytes count) cannot fit its screen row
  local segs = {}
  local chunks = lr.cells[k].chunks
  local x = ics
  local nreal = 0
  for _, ch in ipairs(chunks) do if not ch.fill then nreal = nreal + 1 end end
  for ci = 1, nreal do
    local ch = chunks[ci]
    while x <= ice and B[x] < ch.s do x = x + 1 end
    local I, J = x, x - 1
    while J + 1 <= ice and (B[J + 1] < ch.e or (ci == nreal and N[J + 1] == 0 and B[J + 1] == ch.e)) do J = J + 1 end
    if ci == nreal then J = ice end
    x = J + 1
    local raw = sum(R, I, J)
    local lim = W - lwb - (#segs == 0 and raw_lead or 0) - 1
    if raw <= lim or I > J then
      segs[#segs + 1] = { I = I, J = J, vis = ch.width, raw = raw, pad = ch.pad_left, s0 = ch.s }
    else
      local a = I
      while a <= J do
        lim = W - lwb - (#segs == 0 and raw_lead or 0) - 1
        local b, acc = a, R[a]
        while b + 1 <= J and acc + R[b + 1] <= lim do b = b + 1; acc = acc + R[b] end
        if b < J then -- prefer a break at the last visible space of the piece
          local sp
          for y = b + 1, a + 1, -1 do
            if N[y] == 1 and V[y] > 0 and line:byte(B[y] + 1) == 32 then sp = y; break end
          end
          if sp then
            local nb = sp - 1
            while nb > a and V[nb] > 0 and line:byte(B[nb] + 1) == 32 do nb = nb - 1 end
            acc = sum(R, a, nb)
            local pieces_end = nb
            segs[#segs + 1] = { I = a, J = pieces_end, vis = sum(V, a, pieces_end), raw = acc,
              pad = align_pad(align, cw, sum(V, a, pieces_end)) }
            a = sp
            while a <= J and N[a] == 1 and line:byte(B[a] + 1) == 32 do a = a + 1 end
            goto continue
          end
        end
        local vis = sum(V, a, b)
        segs[#segs + 1] = { I = a, J = b, vis = vis, raw = acc, pad = align_pad(align, cw, vis) }
        a = b + 1
        ::continue::
      end
    end
  end
  if #segs == 0 then segs[1] = { I = ics, J = ics - 1, vis = 0, raw = 0, pad = align_pad(align, cw, 0), s0 = c.s } end
  for _, sg in ipairs(segs) do
    if sg.I <= sg.J then sg.sb, sg.se = B[sg.I], B[sg.J] + N[sg.J] else sg.sb, sg.se = sg.s0 or c.s, sg.s0 or c.s end
  end
  local n = #segs
  local function parts(li)
    local left = emit({}, string.rep(" ", tbl.indent or 0), HL.fill)
    emit(left, "│", hb)
    cells_into(left, tbl, widths, row, lr, li, 1, k - 1, hb, ht)
    emit(left, " ", ht)
    local right = emit({}, " ", ht)
    emit(right, "│", hb)
    cells_into(right, tbl, widths, row, lr, li, k + 1, tbl.ncols, hb, ht)
    return left, right
  end
  local function gridline(li)
    if li <= lr.lines then return g.lines[g.first[r] + li - 1] end
    return g.blank
  end
  -- grid line li of the row with the real cell's column empty ("cell" spill)
  local function cellblank(li)
    local left, right = parts(li)
    emit(left, string.rep(" ", cw), ht)
    for _, y in ipairs(right) do emit(left, y[1], y[2]) end
    return left
  end
  local marks = {}
  conceal(marks, 0, c.s)
  conceal(marks, c.e, #line)
  for i = 1, #c.cs do conceal(marks, c.cs[i], c.ce[i]) end -- incl. the backslash of `\|`
  local sepline = g.sep[r] and g.lines[g.sep[r]] or nil
  local used_sep, spill_above = false, 0
  local off = 0 -- "cell" spill: grid lines of the row drawn on the spill rows above
  local ab_end = g.first[r] - 1 -- the last grid line above the row (separator, delimiter or top border)
  local below_from = g.first[r] + g.count[r]
  local lil, fb = 0, 0 -- grid lines from above / below drawn on the line's spill rows ("flow")
  local blank_above, blank_below = 0, 0
  -- row 1: the concealed prefix 1..ia-1 must fit in front of the grid; the rest spills above
  local ap1 = segs[1].pad
  local s0 = 1
  local A = sum(R, 1, ia - 1)
  local cap = W - (lwb + ap1) - raw_lead - segs[1].raw
  if n == 1 then -- keep the trailing bytes on the grid line when they fit (cursor on the last bar stays in the cell)
    -- ... unless that shows more blank rows than letting it wrap: a spill
    -- row above is blank unless it carries the separator (or, "flow", a line
    -- from above); a wrapped tail lands on the row's next grid line, else on
    -- a blank row below (or, "flow", a line from below). Ties: keep it only
    -- when it adds no spill row (WP-G review F1)
    local tail = sum(R, ice + 1, nL)
    if cap - tail >= 0 then
      local function need(c) return A > c and math.ceil((A - c) / W) or 0 end
      local nk, nd = need(cap - tail), need(cap)
      local freeA = mode == "flow" and math.huge or (sepline and 1 or 0)
      local freeB = math.max(lr.lines - n, 0) + (mode == "flow" and (#g.lines - below_from + 1) or 0)
      local slack = cap - math.min(A, cap)
      local t = tail > slack and math.ceil((tail - slack) / W) or 0
      local bk = math.max(nk - freeA, 0)
      local bd = math.max(nd - freeA, 0) + math.max(t - freeB, 0)
      if bk < bd or (bk == bd and nk == nd) then cap = cap - tail end
    end
  end
  if A > cap then
    local keep = 0
    s0 = ia
    for y = ia - 1, 1, -1 do
      if keep + R[y] > cap then break end
      keep, s0 = keep + R[y], y
    end
    local Pw = A - keep
    local padw = math.ceil(Pw / W) * W - Pw
    inline(marks, 0, padw)
    used_sep = sepline ~= nil
    local starts = place(L, 1, s0 - 1, padw, W)
    spill_above = 1 + #starts
    -- what each spill row carries (header comment)
    local slots = {}
    if mode == "flow" then
      -- opts.ext: screen rows of the buffer lines above the table (nearest
      -- last), concealed and redrawn while the cursor is on this row (WP-I
      -- round 3), so the spill rows never fall back to "cell" near the top
      local ne = opts.ext and #opts.ext or 0
      lil = math.min(spill_above, ab_end + ne)
      for i = 1, lil do
        local j = ab_end + ne - lil + i
        slots[i] = j <= ne and opts.ext[j] or g.lines[j - ne]
      end
    elseif sepline then
      lil, slots[1] = 1, sepline
    end
    for i = #slots + 1, spill_above do
      if mode == "row" then
        slots[i] = g.blank
        blank_above = blank_above + 1
      else
        off = off + 1
        slots[i] = cellblank(off)
        if off > lr.lines then blank_above = blank_above + 1 end
      end
    end
    overlay(marks, 0, 0, slots[1])
    for i, b in ipairs(starts) do overlay(marks, b, 0, slots[i + 1]) end
  end
  local NL = math.max(n + off, lr.lines, nlmin or 0)
  local carry = sum(R, s0, ia - 1) - sum(V, s0, ia - 1) -- concealed part; the visible part is under the overlay
  local before1 = sum(V, s0, ia - 1) + vis_lead
  local extra, nav, spill_below, suffix_rows = {}, {}, 0, 0
  local spacer_at -- byte that carries the next grid line's spacer (B6: not the segment's first byte)
  for li = 1, n do
    local sg = segs[li]
    local apad = sg.pad
    local lw = lwb + apad
    local spacer = li == 1 and math.max(lw - before1, 0) or lw
    local used = carry + (li == 1 and (before1 + raw_lead - vis_lead) or 0) + spacer + sg.raw
    if used > W and apad > 0 then
      local d = math.min(apad, used - W)
      apad, lw, spacer, used = apad - d, lw - d, spacer - d, used - d
    end
    local nv = { b = {}, n = {}, w = {}, col = {} }
    local cx = apad
    for i = sg.I, sg.J do
      if N[i] > 0 and V[i] > 0 then
        local m = #nv.b + 1
        nv.b[m], nv.n[m], nv.w[m], nv.col[m] = B[i], N[i], V[i], cx
      end
      cx = cx + V[i]
    end
    nav[li] = nv
    local left, right = parts(li + off)
    emit(left, string.rep(" ", apad), ht)
    local at = li == 1 and anchor1 or (spacer_at or sg.sb)
    inline(marks, at, spacer)
    -- overlays of lines 2.. anchor on the segment's second char when it has
    -- one (always on this screen row), else on the spacer's byte
    local oat = (li > 1 and sg.J > sg.I) and B[sg.I + 1] or at
    overlay(marks, oat, 0, left)
    local rch = emit({}, string.rep(" ", math.max(cw - sg.vis - apad, 0)), ht)
    for _, y in ipairs(right) do emit(rch, y[1], y[2]) end
    overlay(marks, li > 1 and oat or (sg.sb < sg.se and sg.sb or at), lw + sg.vis, rch)
    if li < n then
      local nx = segs[li + 1]
      local brk = sum(R, sg.J + 1, nx.I - 1)
      -- the next spacer goes on the last concealed byte before the next
      -- segment, so an insert-mode cursor on that segment's first byte is not
      -- drawn before the spacer (B6); mid-word breaks have no such byte
      local post = 0
      spacer_at = nil
      if nx.I - 1 > sg.J and N[nx.I - 1] > 0 then
        spacer_at, post = B[nx.I - 1], R[nx.I - 1]
      end
      local pre = brk - post
      inline(marks, sg.se, math.max(W - used - pre, 0))
      conceal(marks, sg.se, nx.sb)
      carry = math.max(used + pre - W, 0) + post
    else
      -- last real line: the concealed suffix wraps into further screen rows,
      -- which carry the remaining grid lines, then blank spill rows
      local rr = n + off + 1
      local starts = place(L, math.max(sg.J, ics - 1) + 1, nL, used, W)
      for _, b in ipairs(starts) do
        local ln
        if rr <= NL then
          ln = gridline(rr)
        elseif mode == "flow" and below_from + fb <= #g.lines then
          fb = fb + 1
          ln = g.lines[below_from + fb - 1]
        else -- "flow": past the table's end, an empty row
          ln, blank_below = mode == "flow" and g.empty or g.blank, blank_below + 1
        end
        overlay(marks, b, 0, ln)
        if rr > NL then spill_below = spill_below + 1 end
        rr = rr + 1
      end
      suffix_rows = #starts
      for y = rr, NL do extra[#extra + 1] = gridline(y) end
    end
  end
  local above = M.slice(g, 1, ab_end - lil)
  if opts.ext and mode == "flow" then -- the copies above the table belong to the block above too
    local ne = #opts.ext
    above = {}
    for j = 1, ne + ab_end - lil do above[j] = j <= ne and opts.ext[j] or g.lines[j - ne] end
  end
  local below = concat_slice(g, extra, below_from + fb, #g.lines)
  -- screen rows of the line: spill above + real lines + concealed-suffix rows
  local rows = spill_above + n + suffix_rows
  local is_last = r == #tbl.rows
  local res = {
    marks = marks, extra = extra, above = above, below = below, rows = rows, segs = segs,
    spill_above = spill_above, spill_below = spill_below, used_sep = used_sep, k = k, n = n,
    nav = nav, nextbar = bars[k + 1], nl = NL,
    -- the grid of the row: separator above it, its screen rows, its own extra
    -- lines, and the bottom border when it is the last row (scroll-to-fit)
    -- (the whole line counts, lines from below on its spill rows included:
    -- Neovim keeps a line that fits the window whole, so a fit that leaves
    -- them out lets Neovim move the cursor to the next line)
    height = ((sepline and lil == 0) and 1 or 0) + rows + #extra + ((is_last and fb == 0) and 1 or 0),
    sep_above = (sepline and lil == 0) and 1 or 0,
    -- grid lines from above (the separator, "flow": more) drawn on the
    -- line's first spill rows: still above the row's grid for scroll-to-fit
    -- and the sticky header (they may go under the float, WP-G)
    lines_in_line = lil, lines_below_in_line = fb,
    -- "flow" drew the delimiter (so the header's end) on the line: the
    -- header is on screen whenever the cursor line is (no sticky float)
    header_in_line = lil > 0 and tbl.rows[2] and tbl.rows[2].kind == "delim" and ab_end - lil + 1 <= g.first[2] or false,
    blank_above = blank_above, blank_below = blank_below, mode = mode,
    -- measurement (tests): raw width before the cell's text, the text's
    -- display column in the grid, the first segment's raw width
    dbg = { P = sum(R, 1, ics - 1), lw = lwb + ap1, seg1 = segs[1].raw, W = W },
  }
  g.proj[key] = res
  return res
end

-- Row-level values of cursor row r over all of its cells (WP-I: moving
-- between the cells of a row moves nothing on screen, so whatever sizes the
-- screen is decided per row, never per cell). Memoized per grid.
-- { nl: grid lines of the row (cursor_row's nlmin for every cell),
--   rows: the tallest line (the raw decision: a line taller than the window),
--   lil: most grid lines from above drawn on the line,
--   sep: 1 when a cell draws the separator in the block above (sepmin: 1
--     when every cell does),
--   depth: most screen rows from the row's first own grid line to the end of
--     the line or of the row's grid (scroll-to-fit),
--   hl: most screen rows of height - lines_in_line (sticky header rule),
--   after: "flow", most screen rows of a line past the table's end,
--   rl: most screen rows of the line below its lines from above (clip),
--   header_in_line: a cell draws the delimiter on the line (header_all:
--     every cell does),
--   frame: screen rows the row needs so that every cell's line is on screen
--     with G on one screen row: max(lil, sep) + depth (>= rows) }
-- The row's first own grid line (G) is at the same screen row in every cell:
-- the block above has #above + lines_in_line constant (clip keep per row).
-- A "flow" row whose frame is taller than the window is drawn with the
-- "cell" spill instead (init.lua), opts.fill: nl covers every cell's line
-- (no blank spill row below the grid), so its frame is about its tallest
-- line; taller than the window, it is drawn raw.
function M.row_info(tbl, lay, r, opts)
  local g = M.grid(tbl, lay, opts)
  local mode = (opts.spill == "row" or opts.spill == "cell") and opts.spill or "flow"
  local key = "R" .. r .. ":" .. mode .. (opts.fill and ":f" or "") .. (opts.ext and (":e" .. tostring(opts.ext)) or "")
  local ri = g.proj[key]
  if ri then return ri end
  local cells = #tbl.rows[r].cells
  local nl, rows, spill = lay.rows[r].lines, 0, 0
  for k = 1, cells do
    local c = M.cursor_row(tbl, lay, r, k, opts)
    nl, rows, spill = math.max(nl, c.nl), math.max(rows, c.rows), math.max(spill, c.spill_above)
    if opts.fill then nl = math.max(nl, c.rows - c.lines_in_line) end
  end
  ri = { nl = nl, rows = rows, lil = 0, sep = 0, depth = 0, hl = 0, rl = 0, after = 0, sepmin = 1, header_in_line = false, header_all = true }
  for k = 1, cells do
    local c = M.cursor_row(tbl, lay, r, k, opts, nl)
    local lil = c.lines_in_line
    ri.lil, ri.sep = math.max(ri.lil, lil), math.max(ri.sep, c.sep_above)
    ri.depth = math.max(ri.depth, c.height - c.sep_above - lil)
    ri.hl = math.max(ri.hl, c.height - lil)
    ri.sepmin = math.min(ri.sepmin, c.sep_above)
    if mode == "flow" then ri.after = math.max(ri.after, c.blank_below) end
    ri.rl = math.max(ri.rl, c.rows - lil)
    ri.header_in_line = ri.header_in_line or c.header_in_line
    ri.header_all = ri.header_all and c.header_in_line and true or false
  end
  ri.frame = math.max(ri.lil, ri.sep) + ri.depth
  ri.spill = spill -- most spill rows above the line (opts.ext: how many rows above the table it needs)
  g.proj[key] = ri
  return ri
end

return M
