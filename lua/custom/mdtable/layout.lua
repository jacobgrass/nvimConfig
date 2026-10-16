-- custom.mdtable.layout: pure layout of a scanned pipe table (see scan.lua for
-- the input model). No buffer or window API: only width functions, string
-- operations and vim.fn.matchstr (one grapheme cluster, mid-word breaks only), so the same inputs always give the same outputs.
--
-- Data layout: words come from the scanner as parallel arrays (wb, we, ww)
-- and concealed ranges as (cs, ce); wrapping walks words and, only for a word
-- wider than its column, the bytes of that word with a conceal pointer. One
-- table per chunk (= per grid line of a cell), never one per character.
--
-- layout.columns(tbl, opts) -> { widths, natural, min }
-- layout.rows(tbl, columns, opts) -> per row { lines, kind, ragged?, cells =
--   { { chunks = { { s, e, width, pad_left, pad_right, fill? }, ... } }, ... } }
--   s, e: byte offsets into the line (break spaces between chunks are left
--   out); width: visible width (conceals removed, icon marks added);
--   fill = true for the empty chunks of a cell shorter than its row.
-- layout.table(tbl, opts) -> { columns, widths, rows, height }
-- layout.cached(tbl, opts): layout.table memoized by (tbl.sig = process-unique row ids, width,
--   separators, padding, min_width, max_word_cap), LRU of 32. Results are
--   shared: read-only.
-- opts: { width = usable window width, padding = 1, min_width = 3,
--   max_word_cap = 12, separators = false }
local L = {}
local strwidth = vim.api.nvim_strwidth

local function defaults(opts)
  opts = opts or {}
  return opts.width or 80, opts.padding or 1, opts.min_width or 3, opts.max_word_cap or 12
end

-- Proportional shrink of `nat` to `avail`, each column at least min(minw, nat).
local function proportional(nat, avail, minw)
  local n, w, total, sum = #nat, {}, 0, 0
  for j = 1, n do total = total + nat[j] end
  for j = 1, n do
    w[j] = math.max(math.min(minw, nat[j]), math.floor(nat[j] * avail / total))
    sum = sum + w[j]
  end
  while sum > avail do
    local m = 1
    for j = 2, n do if w[j] > w[m] then m = j end end
    if w[m] <= minw then break end
    w[m], sum = w[m] - 1, sum - 1
  end
  while sum < avail do
    local m, d = nil, 0
    for j = 1, n do if nat[j] - w[j] > d then m, d = j, nat[j] - w[j] end end
    if not m then break end
    w[m], sum = w[m] + 1, sum + 1
  end
  return w
end

function L.columns(tbl, opts)
  local width, padding, min_width, cap = defaults(opts)
  local n = tbl.ncols
  local nat, minw = {}, {}
  for j = 1, n do nat[j], minw[j] = 1, min_width end
  for _, row in ipairs(tbl.rows) do
    if row.kind ~= "delim" and not row.ragged then
      local header = row.kind == "header"
      for j = 1, n do
        local c = row.cells[j]
        if c.width > nat[j] then nat[j] = c.width end
        local lw = header and c.lw or math.min(c.lw, cap)
        if lw > minw[j] then minw[j] = lw end
      end
    end
  end
  local total, mintotal = 0, 0
  for j = 1, n do
    if minw[j] > nat[j] then minw[j] = nat[j] end
    total, mintotal = total + nat[j], mintotal + minw[j]
  end
  local avail = width - (tbl.indent or 0) - (n + 1) - 2 * padding * n
  local w = {}
  if total <= avail then
    for j = 1, n do w[j] = nat[j] end
  elseif mintotal > avail then
    w = proportional(nat, avail, min_width)
  else
    for j = 1, n do w[j] = nat[j] end
    while total > avail do -- water-filling: one cell from the widest shrinkable column, ties rightmost
      local m
      for j = 1, n do
        if w[j] > minw[j] and (not m or w[j] >= w[m]) then m = j end
      end
      w[m], total = w[m] - 1, total - 1
    end
  end
  return { widths = w, natural = nat, min = minw }
end

local function utf8len(b)
  if b < 0x80 then return 1 elseif b >= 0xF0 then return 4 elseif b >= 0xE0 then return 3 elseif b >= 0xC0 then return 2 end
  return 1
end

-- Walk bytes [a, b) of the cell's line and stop before the first visible
-- character that would make the width exceed `lim` (at least one visible
-- character is taken). Concealed bytes are free; an icon mark is counted
-- with the character at its `at` byte. Returns stop byte and width.
local function fit_bytes(line, cell, a, b, lim)
  local cs, ce, marks = cell.cs, cell.ce, cell.marks
  local k, nc, used, took = 1, #cs, 0, false
  local i = a
  while i < b do
    while k <= nc and ce[k] <= i do k = k + 1 end
    if k <= nc and cs[k] <= i then
      local stop = ce[k] < b and ce[k] or b
      local mw = 0 -- an icon on a concealed byte (render-markdown puts link icons on `[`) is still drawn
      for m = 1, #marks do
        if marks[m].at >= i and marks[m].at < stop then mw = mw + marks[m].width end
      end
      if mw > 0 then
        if took and used + mw > lim then return i, used end
        used, took = used + mw, true
      end
      i = stop
    else
      local by, nx = line:byte(i + 1, i + 2)
      local n, w = 1, 1
      if by >= 0x80 or (nx and nx >= 0x80) then
        -- one grapheme cluster (VS16, ZWJ sequences, combining marks): Vim's `.`
        local g = vim.fn.matchstr(line, ".", i)
        n = #g > 0 and #g or utf8len(by)
        if i + n > b then n = b - i end
        w = strwidth(line:sub(i + 1, i + n))
      end
      for m = 1, #marks do
        local at = marks[m].at
        if at >= i and at < i + n then w = w + marks[m].width end
      end
      if took and used + w > lim then return i, used end
      used, took, i = used + w, took or w > 0, i + n
    end
  end
  return b, used
end

local function chunk(s, e, w, cw, align)
  local free = cw - w
  if free < 0 then free = 0 end
  local pl = align == "right" and free or (align == "center" and math.floor(free / 2) or 0)
  return { s = s, e = e, width = w, pad_left = pl, pad_right = free - pl }
end

-- Word wrap of one cell into chunks of at most cw visible width.
local function wrap(line, cell, cw, align)
  local out = {}
  local wb, we, ww = cell.wb, cell.we, cell.ww
  local nw = #wb
  if nw == 0 then
    out[1] = chunk(cell.s, cell.e, cell.width, cw, align)
    return out
  end
  local i, pos = 1, wb[1]
  while i <= nw do
    local s, e, used = pos, nil, nil
    if pos == wb[i] and ww[i] <= cw then
      e, used = we[i], ww[i]
    else
      e, used = fit_bytes(line, cell, pos, we[i], cw)
    end
    if e < we[i] then -- word broken mid-word: the rest starts the next line
      out[#out + 1] = chunk(s, e, used, cw, align)
      pos = e
    else
      i = i + 1
      while i <= nw do
        local add = (wb[i] - we[i - 1]) + ww[i] -- visible spaces + next word
        if used + add > cw then break end
        used, e, i = used + add, we[i], i + 1
      end
      out[#out + 1] = chunk(s, e, used, cw, align)
      if i <= nw then pos = wb[i] end
    end
  end
  return out
end

local DELIM = { lines = 1, kind = "delim", cells = {} }

-- Per-row memo: a row model is immutable (scan keys it by its text), so its
-- grid lines depend only on the column widths, alignments and window width.
-- After a one-row edit only that row is wrapped again. Weak keys: rows evicted
-- by scan disappear with their memo.
local rowmemo = setmetatable({}, { __mode = "k" })

function L.rows(tbl, columns, opts)
  local width = defaults(opts)
  local widths, aligns = columns.widths, tbl.aligns
  local key = table.concat(widths, ",") .. "|" .. table.concat(aligns, ",") .. "|" .. width
  local out = {}
  for r, row in ipairs(tbl.rows) do
    local m = rowmemo[row.orig or row]
    if m and m.key == key then
      out[r] = m.value
    else
      local lr
      if row.kind == "delim" then
        lr = DELIM
      elseif row.ragged then
        lr = { lines = math.max(1, math.ceil((row.raw_width or 0) / math.max(width, 1))), kind = row.kind, ragged = true, cells = {} }
      else
        local cells, n = {}, 1
        for j = 1, tbl.ncols do
          local chunks = wrap(row.line, row.cells[j], widths[j], aligns[j])
          cells[j] = { chunks = chunks }
          if #chunks > n then n = #chunks end
        end
        for j = 1, tbl.ncols do
          local chunks, e = cells[j].chunks, row.cells[j].e
          for _ = #chunks + 1, n do
            chunks[#chunks + 1] = { s = e, e = e, width = 0, pad_left = 0, pad_right = widths[j], fill = true }
          end
        end
        lr = { lines = n, kind = row.kind, cells = cells }
      end
      rowmemo[row.orig or row] = { key = key, value = lr }
      out[r] = lr
    end
  end
  return out
end

function L.table(tbl, opts)
  local columns = L.columns(tbl, opts)
  local rows = L.rows(tbl, columns, opts)
  local h, nbody = 2, 0
  for r, lr in ipairs(rows) do
    h = h + lr.lines
    if tbl.rows[r].kind == "body" then nbody = nbody + 1 end
  end
  if opts and opts.separators and nbody > 1 then h = h + nbody - 1 end
  return { columns = columns, widths = columns.widths, rows = rows, height = h }
end

-- LRU memo of layout.table.
local memo, size, tick = {}, 0, 0
local LRU = 32

local function signature(tbl)
  if tbl.sig then return tbl.sig end
  local parts = {}
  for i, row in ipairs(tbl.rows) do parts[i] = row.line .. "\0" .. (row.suffix or "") end
  return table.concat(parts, "\1")
end

function L.cached(tbl, opts)
  local width, padding, min_width, cap = defaults(opts)
  local key = signature(tbl) .. "|" .. width .. "|" .. (opts and opts.separators and 1 or 0)
    .. "|" .. padding .. "|" .. min_width .. "|" .. cap
  tick = tick + 1
  local hit = memo[key]
  if hit then
    hit.used = tick
    return hit.value
  end
  if size >= LRU then
    local old, oldest = nil, math.huge
    for k, v in pairs(memo) do
      if v.used < oldest then old, oldest = k, v.used end
    end
    memo[old], size = nil, size - 1
  end
  local value = L.table(tbl, opts)
  memo[key], size = { value = value, used = tick }, size + 1
  return value
end

function L.cache_size() return size end
function L.cache_clear()
  memo, size = {}, 0
  rowmemo = setmetatable({}, { __mode = "k" })
end

return L
