-- ORACLE: project.lua as of 582e4ae (before WP-G), kept for the old-vs-new
-- blank-row and height sweep in test_project.lua. Not loaded by the plugin.
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
--   Concealed bytes that do not fit add spill rows, drawn as blank bordered
--   rows (above the grid when the prefix before the cell is too wide, below
--   it otherwise).
-- * Covered row (project.covered_row): an anchor line with no real cell (the
--   header while the cursor is outside the table, or the delimiter row under
--   the cursor). The whole line is concealed and every screen row it occupies
--   carries the next grid line as an overlay, so it adds no blank rows.
--
-- Mark specs: { col, opts } (the row is the anchor line, supplied by draw).
local M = {}
local strwidth = vim.api.nvim_strwidth

M.HL = { fill = "MdTableFill", head_b = "MdTableHead", row_b = "MdTableRow", head_t = "@markup.heading", row_t = "Normal",
  more = "MdTableMore" }
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
    blank = full_line(tbl, widths, nil, nil, 1), W = W, slices = {}, proj = {} }
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
local clipmemo = setmetatable({}, { __mode = "k" })
function M.clip(g, tbl, block, keep, side)
  local n = #block
  if n <= keep then return block end
  local per = clipmemo[block]
  if not per then per = {}; clipmemo[block] = per end
  local key = side .. keep
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
    while s2 <= n and ro[block[s2]] and ro[block[s2]] == ro[block[s2 - 1]] do s2 = s2 + 1 end
    if s2 <= n then s = s2 end
    for i = 1, s - 1 do hide(block[i]) end
    res[1] = M.marker(g, tbl, cnt)
    for i = s, n do res[#res + 1] = block[i] end
  else
    local e = keep - 1 -- last kept line
    local e2 = e
    while e2 >= 1 and ro[block[e2]] and ro[block[e2]] == ro[block[e2 + 1]] do e2 = e2 - 1 end
    if e2 >= 1 then e = e2 end
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
  local res = { marks = marks, rows = #starts + 1, from = from, consumed = consumed,
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

-- Cursor row r with the real cell k. opts: { width = W, separators, tabstop }.
-- Returns { marks, extra (virtual lines that follow the row), above, below,
-- rows (screen rows of the line incl. spill), spill_above, spill_below,
-- used_sep, height (grid height incl. separator and own lines), nav }.
-- nav[li] = { b = {}, n = {}, w = {}, col = {} }: visible characters of the
-- real cell per grid line and their columns inside the cell.
function M.cursor_row(tbl, lay, r, k, opts)
  local g = M.grid(tbl, lay, opts)
  local key = r .. ":" .. k
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
  local NL = math.max(n, lr.lines)
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
  local marks = {}
  conceal(marks, 0, c.s)
  conceal(marks, c.e, #line)
  for i = 1, #c.cs do conceal(marks, c.cs[i], c.ce[i]) end -- incl. the backslash of `\|`
  local sepline = g.sep[r] and g.lines[g.sep[r]] or nil
  local used_sep, spill_above = false, 0
  -- row 1: the concealed prefix 1..ia-1 must fit in front of the grid; the rest spills above
  local ap1 = segs[1].pad
  local s0 = 1
  local A = sum(R, 1, ia - 1)
  local cap = W - (lwb + ap1) - raw_lead - segs[1].raw
  if n == 1 then -- keep the trailing bytes on the grid line when they fit (cursor on the last bar stays in the cell)
    local tail = sum(R, ice + 1, nL)
    if cap - tail >= 0 then cap = cap - tail end
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
    overlay(marks, 0, 0, sepline or g.blank)
    used_sep = sepline ~= nil
    local starts = place(L, 1, s0 - 1, padw, W)
    for _, b in ipairs(starts) do overlay(marks, b, 0, g.blank) end
    spill_above = 1 + #starts
  end
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
    local left, right = parts(li)
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
      local rr = n + 1
      local starts = place(L, math.max(sg.J, ics - 1) + 1, nL, used, W)
      for _, b in ipairs(starts) do
        overlay(marks, b, 0, rr <= NL and gridline(rr) or g.blank)
        if rr > NL then spill_below = spill_below + 1 end
        rr = rr + 1
      end
      suffix_rows = #starts
      for y = rr, NL do extra[#extra + 1] = gridline(y) end
    end
  end
  local above = M.slice(g, 1, (g.sep[r] or g.first[r]) - 1)
  if sepline and not used_sep then above = M.slice(g, 1, g.sep[r]) end
  local below_from = g.first[r] + g.count[r]
  local below = concat_slice(g, extra, below_from, #g.lines)
  -- screen rows of the line: spill above + real lines + concealed-suffix rows
  local rows = spill_above + n + suffix_rows
  local is_last = r == #tbl.rows
  local res = {
    marks = marks, extra = extra, above = above, below = below, rows = rows, segs = segs,
    spill_above = spill_above, spill_below = spill_below, used_sep = used_sep, k = k, n = n,
    nav = nav, nextbar = bars[k + 1],
    -- the grid of the row: separator above it, its screen rows, its own extra
    -- lines, and the bottom border when it is the last row (scroll-to-fit)
    height = ((sepline and not used_sep) and 1 or 0) + rows + #extra + (is_last and 1 or 0),
    sep_above = (sepline and not used_sep) and 1 or 0,
  }
  g.proj[key] = res
  return res
end

return M
