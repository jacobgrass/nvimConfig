-- mdtable.parse: treesitter discovery of pipe tables, concealed ranges of inline
-- markup, per-character width model, column widths and word wrap.
local api = vim.api
local P = {}

local table_query
local function tq()
  table_query = table_query or vim.treesitter.query.parse("markdown", "(pipe_table) @t")
  return table_query
end

-- Concealed byte ranges per 0-based row in [lo, hi], from the markdown_inline
-- highlights query (captures carrying a `conceal` value). conceallevel 3 hides
-- them completely, replacement characters included.
function P.conceals(parser, buf, lo, hi)
  local out = {}
  local inl = parser:children().markdown_inline
  local query = inl and vim.treesitter.query.get("markdown_inline", "highlights")
  if not query then return out end
  inl:for_each_tree(function(tree)
    local root = tree:root()
    local sr, _, er = root:range()
    if er < lo or sr > hi then return end
    for id, node, md in query:iter_captures(root, buf, math.max(lo, sr), math.min(hi, er) + 1) do
      local m = md[id] or {}
      if m.conceal ~= nil or md.conceal ~= nil then
        local r1, c1, r2, c2
        if m.range then r1, c1, r2, c2 = unpack(m.range) else r1, c1, r2, c2 = node:range() end
        if r1 == r2 and c2 > c1 then
          out[r1] = out[r1] or {}
          table.insert(out[r1], { c1, c2 })
        end
      end
    end
  end)
  return out
end

local function utf8len(b)
  if b < 0x80 then return 1 elseif b >= 0xF0 then return 4 elseif b >= 0xE0 then return 3 elseif b >= 0xC0 then return 2 end
  return 1
end

-- Characters of line[s, e) (0-based bytes): b byte, n bytes, r raw width,
-- w visible width (0 when concealed), sp visible space, t text.
function P.chars(line, s, e, conc)
  local out, i = {}, s
  while i < e do
    local n = utf8len(line:byte(i + 1))
    local t = line:sub(i + 1, i + n)
    local r = n == 1 and 1 or api.nvim_strwidth(t)
    local hid = false
    if conc then
      for _, cr in ipairs(conc) do
        if i >= cr[1] and i < cr[2] then hid = true; break end
      end
    end
    out[#out + 1] = { b = i, n = n, r = r, w = hid and 0 or r, sp = not hid and t == " ", t = t, hid = hid }
    i = i + n
  end
  return out
end

-- Raw display width of line[s, e).
function P.rawwidth(line, s, e)
  if e <= s then return 0 end
  return api.nvim_strwidth(line:sub(s + 1, e))
end

-- Greedy word wrap of a char list. cw: visible width limit; rawlim(r): optional
-- raw-width limit of segment r. Breaks at visible spaces; a word longer than
-- the column breaks mid-word. Returns segments {i, j} (inclusive char indexes,
-- j < i for an empty segment), each with vis and raw widths.
function P.wrap(chars, cw, rawlim)
  local segs, n, i = {}, #chars, 1
  local function push(a, b)
    local v, r = 0, 0
    for x = a, b do v = v + chars[x].w; r = r + chars[x].r end
    segs[#segs + 1] = { i = a, j = b, vis = v, raw = r }
  end
  if n == 0 then push(1, 0); return segs end
  while i <= n do
    local lim = rawlim and rawlim(#segs + 1) or math.huge
    local vw, rw, j, lastsp = 0, 0, i - 1, nil
    while j < n do
      local c = chars[j + 1]
      if vw + c.w > cw or rw + c.r > lim then break end
      vw, rw, j = vw + c.w, rw + c.r, j + 1
      if c.sp then lastsp = j end
    end
    if j == n then push(i, n); break end
    local cut
    if chars[j + 1].sp then cut = j
    elseif lastsp and lastsp > i then cut = lastsp - 1
    else cut = j end
    if cut < i then cut = i end
    local e = cut
    while e > i and chars[e].sp do e = e - 1 end
    push(i, e)
    i = cut + 1
    while i <= n and chars[i].sp do i = i + 1 end
  end
  return segs
end

-- Visible text of chars[a..b].
function P.text(chars, a, b)
  local t = {}
  for x = a, b do if not chars[x].hid then t[#t + 1] = chars[x].t end end
  return table.concat(t)
end

local function trim_range(line, s, e)
  while s < e and line:sub(s + 1, s + 1):match("%s") do s = s + 1 end
  while e > s and line:sub(e, e):match("%s") do e = e - 1 end
  return s, e
end

-- One row: bars (0-based byte of each delimiter; virtual bars for missing
-- outer pipes) and cells {bar, s, e} (trimmed text range).
local function parse_row(node, line)
  local bars = {}
  for ch in node:iter_children() do
    if ch:type() == "|" then
      local _, c = ch:start()
      bars[#bars + 1] = c
    end
  end
  local _, sc = node:start()
  local _, ec = node:end_()
  local ln = #line
  if ec > ln or ec == 0 then ec = ln end
  if #bars == 0 or line:sub(sc + 1, bars[1]):match("%S") then table.insert(bars, 1, sc - 1) end
  if line:sub(bars[#bars] + 2, ec):match("%S") then bars[#bars + 1] = ec end
  local cells = {}
  for j = 1, #bars - 1 do
    local s, e = trim_range(line, bars[j] + 1, bars[j + 1])
    if s == e then s = math.min(bars[j] + 1, bars[j + 1]); e = s end
    cells[j] = { bar = bars[j], s = s, e = e }
  end
  return cells
end

-- All pipe tables intersecting rows [lo, hi] (0-based).
function P.tables(parser, buf, lo, hi, conc)
  local out = {}
  for _, tree in ipairs(parser:trees()) do
    for _, node in tq():iter_captures(tree:root(), buf, lo, hi + 1) do
      local t = { rows = {}, align = {} }
      for child in node:iter_children() do
        local ty = child:type()
        local r = child:start()
        local line = api.nvim_buf_get_lines(buf, r, r + 1, false)[1] or ""
        if ty == "pipe_table_delimiter_row" then
          t.delim = { lnum = r, line = line, kind = "delim", cells = parse_row(child, line) }
          t.rows[#t.rows + 1] = t.delim
          local j = 0
          for dc in child:iter_children() do
            if dc:type() == "pipe_table_delimiter_cell" then
              j = j + 1
              local l, rt = false, false
              for x in dc:iter_children() do
                if x:type() == "pipe_table_align_left" then l = true end
                if x:type() == "pipe_table_align_right" then rt = true end
              end
              t.align[j] = (l and rt) and "center" or (rt and "right" or "left")
            end
          end
        elseif ty == "pipe_table_header" or ty == "pipe_table_row" then
          local row = { lnum = r, line = line, kind = ty == "pipe_table_header" and "head" or "row", cells = parse_row(child, line) }
          for _, c in ipairs(row.cells) do
            c.chars = P.chars(line, c.s, c.e, conc[r])
            local v = 0
            for _, ch in ipairs(c.chars) do v = v + ch.w end
            c.vis = v
          end
          t.rows[#t.rows + 1] = row
        end
      end
      if t.delim and #t.rows > 1 then
        t.ncols = #t.delim.cells
        for _, row in ipairs(t.rows) do
          row.ragged = row.kind ~= "delim" and #row.cells ~= t.ncols
          row.conc = conc[row.lnum]
        end
        local hl = t.rows[1].line
        t.indent = api.nvim_strwidth(hl:match("^%s*"))
        out[#out + 1] = t
      end
    end
  end
  return out
end

local function longest_word(chars)
  local best, cur = 0, 0
  for _, ch in ipairs(chars) do
    if ch.sp then cur = 0 else cur = cur + ch.w; best = math.max(best, cur) end
  end
  return best
end

-- Proportional shrink to `avail`, minimum 3 (fallback when minimums do not fit).
local function proportional(nat, avail)
  local n, w, total, sum = #nat, {}, 0, 0
  for j = 1, n do total = total + nat[j] end
  for j = 1, n do w[j] = math.max(math.min(3, nat[j]), math.floor(nat[j] * avail / total)); sum = sum + w[j] end
  while sum > avail do
    local m = 1
    for j = 2, n do if w[j] > w[m] then m = j end end
    if w[m] <= 3 then break end
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

-- Column widths: natural width (max visible width over all non-ragged rows),
-- shrunk by water-filling to fit the window: repeatedly take one cell from the
-- widest column (ties: the rightmost) that is above its minimum. Minimum =
-- max(longest header word, longest cell word capped at 12, 3), at most the
-- natural width. If even the minimums do not fit, shrink proportionally.
function P.widths(t, W)
  local nat, minw, total = {}, {}, 0
  for j = 1, t.ncols do nat[j], minw[j] = 1, 3 end
  for _, row in ipairs(t.rows) do
    if row.kind ~= "delim" and not row.ragged then
      for j, c in ipairs(row.cells) do
        nat[j] = math.max(nat[j], c.vis)
        local lw = longest_word(c.chars)
        minw[j] = math.max(minw[j], row.kind == "head" and lw or math.min(lw, 12))
      end
    end
  end
  local mintotal = 0
  for j = 1, t.ncols do
    minw[j] = math.min(minw[j], nat[j])
    total, mintotal = total + nat[j], mintotal + minw[j]
  end
  local avail = W - t.indent - 1 - 3 * t.ncols
  if total <= avail then return nat end
  if mintotal > avail then return proportional(nat, avail) end
  local w = vim.deepcopy(nat)
  while total > avail do
    local m
    for j = 1, t.ncols do
      if w[j] > minw[j] and (not m or w[j] >= w[m]) then m = j end
    end
    w[m], total = w[m] - 1, total - 1
  end
  return w
end

return P
