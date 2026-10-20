-- custom.mdtable.scan: incremental, cached discovery of Markdown pipe tables.
--
-- scan.tables(buf, lo, hi) returns the table models that intersect rows
-- [lo, hi) (0-based, end-exclusive). Rows are cached by their line text, so
-- an unchanged row costs one table lookup and no allocation.
--
-- Data layout (struct of arrays: no table is ever built per character):
--   table  { start_row, end_row (exclusive: last row + 1), header_row,
--            delim_row, aligns = { "left"|"center"|"right"|"none", ... },
--            ncols, indent (display width before the header's first byte of
--            table content), sig (row ids joined by ","; layout cache key),
--            rows = { row, ... } }
--   row    { lnum, kind = "header"|"delim"|"body", ragged, id (unique per
--            cache entry), raw_width (display width of the whole line),
--            cells = { cell, ... }, line, suffix (cache key parts) }
--   cell   { s, e     byte offsets of the trimmed cell text in the line
--            text     line:sub(s + 1, e)
--            width    display width: concealed bytes removed, inline icons added
--            lw       width of the longest word
--            cs, ce   parallel arrays: concealed byte ranges [cs[i], ce[i]),
--                     absolute, sorted, merged
--            wb, we, ww parallel arrays: words (maximal byte runs that are
--                     not a visible ASCII space): start, end, visible width
--                     (icons included)
--            marks    { { col, at, text, hl, width }, ... } inline virt_text of
--                     other namespaces; `at` is the byte of the word the icon
--                     is counted in (layout attaches the icon to that byte)
--            align    (delimiter cells only) }
--   Cells without conceals, words or marks share the read-only table EMPTY.
--
-- Cache: per buffer, cache[line][suffix] = row, suffix = ncols .. "\0" ..
-- icon signature .. "\0" .. kind (the logical key is line \0 ncols \0 icons;
-- the kind is added because a header and a body row can share their text;
-- delimiter rows use suffix "d", their text alone defines them). Two levels
-- so a hit builds no key string from the (often 1 KB+) line. Rows also carry
-- `indent` (display width before the row's table content).
-- on_bytes evicts the rows an edit touched (by_row maps lnum -> row) and
-- shifts the map by the line delta.
--
-- Results are read-only and valid until the next scan.tables call on the
-- buffer: a cached row is returned itself with `lnum` set (a row whose text
-- occurs twice in one scan gets a shallow copy for the second occurrence).
local api = vim.api
local uv = vim.uv or vim.loop
local M = {}

local EMPTY = setmetatable({}, { __newindex = function() error("mdtable.scan: EMPTY is read-only") end })
M.EMPTY = EMPTY
local MAX_ENTRIES = 4096

local state = {} -- buf -> state
local next_id = 0 -- row ids are unique process-wide: layout.cached keys on them across buffers
local own_ns = {} -- ns id -> true: inline virt_text of these namespaces is ignored

function M.ignore_ns(id) own_ns[id] = true end

local hl_query

local function reset(st)
  st.cache, st.by_row, st.entries, st.max_entries = {}, {}, 0, MAX_ENTRIES
end

local function drop(st, row)
  row = row.orig or row
  local bucket = st.cache[row.line]
  if bucket and bucket[row.suffix] == row then
    bucket[row.suffix] = nil
    st.entries = st.entries - 1
    if next(bucket) == nil then st.cache[row.line] = nil end
  end
end

-- on_bytes: evict touched rows, shift the lnum map by the line delta.
local function on_edit(st, sr, sc, oer, oec, ner, nec)
  local first, last = sr, sr + oer
  if oer > 0 and oec == 0 then last = last - 1 end -- range ends at column 0 of a row it does not touch
  if oer == 0 and oec == 0 and sc == 0 and ner > 0 and nec == 0 then last = first - 1 end -- whole lines inserted
  local by_row = st.by_row
  for r = first, last do
    local row = by_row[r]
    if row then drop(st, row); by_row[r] = nil end
  end
  local delta = ner - oer
  if delta ~= 0 then
    local moved = {}
    local lim = sr + oer
    for r, row in pairs(by_row) do
      if r > lim or (r == lim and r > last) then moved[r + delta] = row elseif r < sr or r <= last then moved[r] = row end
    end
    st.by_row = moved
  end
end

function M.attach(buf)
  if buf == 0 then buf = api.nvim_get_current_buf() end
  if state[buf] then return state[buf] end
  local st = { gen = 0, hits = 0, misses = 0, total_hits = 0, total_misses = 0, parse_ms_last = 0 }
  reset(st)
  state[buf] = st
  api.nvim_buf_attach(buf, false, {
    on_bytes = function(_, b, _, sr, sc, _, oer, oec, _, ner, nec)
      if state[b] ~= st then return true end
      on_edit(st, sr, sc, oer, oec, ner, nec)
    end,
    on_reload = function(_, b)
      if state[b] == st then reset(st) end
    end,
    on_detach = function(_, b)
      if state[b] == st then state[b] = nil end
    end,
  })
  return st
end

function M.detach(buf)
  if buf == 0 then buf = api.nvim_get_current_buf() end
  state[buf] = nil -- the on_bytes callback sees the mismatch and detaches itself
end

function M.stats(buf)
  if buf == 0 then buf = api.nvim_get_current_buf() end
  local st = state[buf]
  if not st then return { hits = 0, misses = 0, parse_ms_last = 0, entries = 0, total_hits = 0, total_misses = 0 } end
  return { hits = st.hits, misses = st.misses, parse_ms_last = st.parse_ms_last, entries = st.entries,
    total_hits = st.total_hits, total_misses = st.total_misses }
end

-- Conceal-only port of the markdown_inline highlights query (nvim-treesitter,
-- ~/.local/share/nvim/site/queries/markdown_inline/highlights.scm): every
-- pattern that sets `conceal`. The full query costs ~10x more (thousands of
-- non-conceal captures with Lua predicates); tests/test_scan.lua checks that
-- both give the same ranges. conceallevel 3 hides replacement characters too,
-- so entity references count as fully concealed.
local CONCEAL_QUERY = [[
[(code_span_delimiter) (emphasis_delimiter)] @c
(inline_link ["[" "]" "(" (link_destination) ")"] @c)
(image ["!" "[" "]" "(" (link_destination) ")"] @c)
(full_reference_link ["[" "]" (link_label)] @c)
(collapsed_reference_link ["[" "]"] @c)
(shortcut_link ["[" "]"] @c)
(entity_reference) @entity
(backslash_escape) @esc
]]
local ENTITIES = { ["&nbsp;"] = true, ["&lt;"] = true, ["&gt;"] = true, ["&amp;"] = true, ["&quot;"] = true,
  ["&ensp;"] = true, ["&emsp;"] = true }
M.CONCEAL_QUERY = CONCEAL_QUERY

-- Concealed ranges of rows in [rlo, rhi]: row -> flat array { c1, c2, ... }.
-- `want` maps row -> line text of the rows that need them; an inline tree
-- whose text has none of the characters a conceal capture needs is skipped.
local function conceals(parser, buf, rlo, rhi, want)
  local out = {}
  local inl = parser:children().markdown_inline
  if not inl then return out end
  hl_query = hl_query or vim.treesitter.query.parse("markdown_inline", CONCEAL_QUERY)
  local q = hl_query
  inl:for_each_tree(function(tree)
    local root = tree:root()
    local sr, sc, er, ec = root:range()
    if er < rlo or sr > rhi then return end
    if sr == er then
      local line = want[sr]
      if not line or not line:sub(sc + 1, ec):find("[%*_`%[%]!&~\\]") then return end
    end
    for id, node in q:iter_captures(root, buf, math.max(rlo, sr), math.min(rhi, er) + 1) do
      local r1, c1, r2, c2 = node:range()
      if r1 == r2 and c2 > c1 and r1 >= rlo and r1 <= rhi
        and (q.captures[id] ~= "entity" or ENTITIES[vim.treesitter.get_node_text(node, buf)]) then
        local a = out[r1]
        if not a then a = {}; out[r1] = a end
        -- a backslash escape conceals its backslash only (the highlight
        -- query's #offset!), as Neovim draws it
        if q.captures[id] == "esc" then c2 = c1 + 1 end
        a[#a + 1] = c1
        a[#a + 1] = c2
      end
    end
  end)
  return out
end

-- Delimiter bytes of one row node (virtual bars for missing outer pipes),
-- guarded against node ranges past the current line (stale trees, B1).
local function bars_of(node, line)
  local ln = #line
  local bars = {}
  for ch in node:iter_children() do
    if ch:type() == "|" then
      local _, c = ch:start()
      if c < ln then bars[#bars + 1] = c end
    end
  end
  local _, sc = node:start()
  local _, ec = node:end_()
  if sc > ln then sc = ln end
  if ec > ln or ec == 0 then ec = ln end
  if #bars == 0 or line:sub(sc + 1, bars[1]):match("%S") then table.insert(bars, 1, sc - 1) end
  if line:sub(bars[#bars] + 2, ec):match("%S") then bars[#bars + 1] = ec end
  return bars, sc
end

local function trim(line, s, e)
  while s < e and line:sub(s + 1, s + 1):match("%s") do s = s + 1 end
  while e > s and line:sub(e, e):match("%s") do e = e - 1 end
  return s, e
end

-- Conceal ranges of cell [s, e) from the row's flat capture array plus the
-- backslash of every `\|` (GFM shows it as `|`): sorted, merged.
local function cell_conceals(line, s, e, flat)
  local cs, ce
  local function add(a, b)
    if a < s then a = s end
    if b > e then b = e end
    if b <= a then return end
    if not cs then cs, ce = {}, {} end
    local n = #cs
    local i = n + 1
    while i > 1 and cs[i - 1] > a do i = i - 1 end -- insertion sort: captures arrive almost sorted
    table.insert(cs, i, a)
    table.insert(ce, i, b)
  end
  if flat then
    for i = 1, #flat, 2 do add(flat[i], flat[i + 1]) end
  end
  local p = s
  while true do
    local f = line:find("\\|", p + 1, true)
    if not f or f > e then break end
    add(f - 1, f)
    p = f + 1
  end
  if not cs then return EMPTY, EMPTY end
  local ms, me = { cs[1] }, { ce[1] }
  for i = 2, #cs do
    if cs[i] <= me[#me] then
      if ce[i] > me[#me] then me[#me] = ce[i] end
    else
      ms[#ms + 1], me[#me + 1] = cs[i], ce[i]
    end
  end
  return ms, me
end

-- Words and widths of cell [s, e) given its conceal arrays.
local function words(line, s, e, cs, ce, ascii)
  local wb, we, ww = EMPTY, EMPTY, EMPTY
  local nw, width, i, k, nc = 0, 0, s, 1, #cs
  local cur -- start of the current word
  local curw = 0
  local nsp, nhb = -1, ascii and e or -1 -- next space / next byte >= 0x80 at or after i (0-based)
  while i < e do
    while k <= nc and ce[k] <= i do k = k + 1 end
    local hidden = k <= nc and cs[k] <= i
    if not hidden and line:byte(i + 1) == 32 then
      if cur then
        if nw == 0 then wb, we, ww = {}, {}, {} end
        nw = nw + 1
        wb[nw], we[nw], ww[nw] = cur, i, curw
        cur = nil
      end
      width, i = width + 1, i + 1
    else
      if not cur then cur, curw = i, 0 end
      if hidden then
        i = ce[k] < e and ce[k] or e
      else
        local stop = e
        if k <= nc and cs[k] < stop then stop = cs[k] end
        if nsp < i then nsp = (line:find(" ", i + 1, true) or (e + 1)) - 1 end
        if nsp < stop then stop = nsp end
        if nhb < i then nhb = (line:find("[\128-\255]", i + 1) or (e + 1)) - 1 end
        local w = nhb >= stop and (stop - i) or api.nvim_strwidth(line:sub(i + 1, stop))
        curw, width, i = curw + w, width + w, stop
      end
    end
  end
  if cur then
    if nw == 0 then wb, we, ww = {}, {}, {} end
    nw = nw + 1
    wb[nw], we[nw], ww[nw] = cur, e, curw
  end
  return wb, we, ww, width
end

local function virt_width(vt)
  local w = 0
  for _, ch in ipairs(vt) do w = w + api.nvim_strwidth(ch[1] or "") end
  return w
end

-- Build one header/body cell.
local function make_cell(line, s, e, flat, icons)
  local text = line:sub(s + 1, e)
  local ascii = not text:find("[\128-\255]")
  local cs, ce = cell_conceals(line, s, e, flat)
  local wb, we, ww, width = words(line, s, e, cs, ce, ascii)
  local marks = EMPTY
  if icons then
    for _, ic in ipairs(icons) do
      if ic.col >= s and ic.col <= e then
        -- the word the icon is counted in: the one containing col, else the next, else the last
        local at, wi = nil, nil
        for x = 1, #wb do
          if ic.col < we[x] then at, wi = math.max(ic.col, wb[x]), x; break end
        end
        if not wi and #wb > 0 then
          wi = #wb
          at = we[wi] - 1
          while at > wb[wi] and line:byte(at + 1) >= 0x80 and line:byte(at + 1) < 0xC0 do at = at - 1 end
        end
        if wi then ww[wi] = ww[wi] + ic.width end
        width = width + ic.width
        if marks == EMPTY then marks = {} end
        marks[#marks + 1] = { col = ic.col, at = at or s, text = ic.text, hl = ic.hl, width = ic.width }
      end
    end
  end
  local lw = 0
  for x = 1, #ww do if ww[x] > lw then lw = ww[x] end end
  return { s = s, e = e, text = text, width = width, lw = lw, cs = cs, ce = ce, wb = wb, we = we, ww = ww, marks = marks }
end

local function make_delim_cell(line, s, e)
  local text = line:sub(s + 1, e)
  local l, r = text:sub(1, 1) == ":", text:sub(-1) == ":"
  local align = (l and r) and "center" or (r and "right" or (l and "left" or "none"))
  return { s = s, e = e, text = text, width = e - s, lw = e - s, cs = EMPTY, ce = EMPTY,
    wb = EMPTY, we = EMPTY, ww = EMPTY, marks = EMPTY, align = align }
end

local function new_row(st, line, suffix, kind)
  next_id = next_id + 1
  return { id = next_id, line = line, suffix = suffix, kind = kind, raw_width = api.nvim_strwidth(line) }
end

-- Fill a header/body row from its node.
local function fill_row(row, node, line, ncols, flat, icons)
  local bars, sc = bars_of(node, line)
  local cells = {}
  for j = 1, #bars - 1 do
    local s, e = trim(line, bars[j] + 1, bars[j + 1])
    if s == e then s = math.min(bars[j] + 1, bars[j + 1]); e = s end
    cells[j] = make_cell(line, s, e, flat, icons)
  end
  row.cells = cells
  row.ragged = #cells ~= ncols
  row.indent = api.nvim_strwidth(line:sub(1, sc))
end

local function fill_delim(row, node, line)
  local bars, sc = bars_of(node, line)
  local cells, aligns = {}, {}
  for j = 1, #bars - 1 do
    local s, e = trim(line, bars[j] + 1, bars[j + 1])
    cells[j] = make_delim_cell(line, s, e)
    aligns[j] = cells[j].align
  end
  row.cells, row.aligns, row.ragged = cells, aligns, false
  row.indent = api.nvim_strwidth(line:sub(1, sc))
end

-- Inline virt_text marks of other namespaces in rows [r1, r2]: row -> list.
local function icons_in(buf, r1, r2)
  local out
  local ok, marks = pcall(api.nvim_buf_get_extmarks, buf, -1, { r1, 0 }, { r2, -1 }, { details = true, type = "virt_text" })
  if not ok then return nil end
  for _, m in ipairs(marks) do
    local d = m[4]
    if d and d.virt_text_pos == "inline" and d.virt_text and not own_ns[d.ns_id] then
      local w = virt_width(d.virt_text)
      if w > 0 then
        out = out or {}
        local l = out[m[2]]
        if not l then l = {}; out[m[2]] = l end
        local txt = {}
        for _, ch in ipairs(d.virt_text) do txt[#txt + 1] = ch[1] or "" end
        local hl = d.virt_text[1][2]
        if type(hl) == "table" then hl = hl[#hl] end
        l[#l + 1] = { col = m[3], text = table.concat(txt), hl = hl, width = w }
      end
    end
  end
  return out
end

local function sig_of(list)
  if not list then return "" end
  local parts = {}
  for _, ic in ipairs(list) do parts[#parts + 1] = ic.col .. ":" .. ic.text .. ":" .. tostring(ic.hl) end
  return table.concat(parts, ";")
end

local KIND = { pipe_table_header = "header", pipe_table_delimiter_row = "delim", pipe_table_row = "body" }
local KCH = { header = "h", body = "b" }
local scratch = {}

local function lookup(st, line, suffix)
  local bucket = st.cache[line]
  return bucket and bucket[suffix]
end

local function store(st, row)
  local bucket = st.cache[row.line]
  if not bucket then bucket = {}; st.cache[row.line] = bucket end
  bucket[row.suffix] = row
  st.entries = st.entries + 1
end

-- Assign lnum to a cached row for this scan (a copy for a second occurrence).
local function place(st, row, lnum)
  if row.gen == st.gen then
    local copy = {}
    for k, v in pairs(row) do copy[k] = v end
    copy.orig = row.orig or row
    row = copy
  end
  row.gen, row.lnum = st.gen, lnum
  st.by_row[lnum] = row
  return row
end

-- Table model of one pipe_table node, or nil. Misses are queued in `pending`.
local function build(st, buf, node, nlines, pending)
  local tr = node:start()
  local _, _, er, ec = node:range()
  if ec > 0 then er = er + 1 end
  if er > nlines then er = nlines end
  if tr >= nlines or er <= tr then return nil end
  local lines = api.nvim_buf_get_lines(buf, tr, er, false)
  -- pass 1: the delimiter row gives ncols and the alignments
  local delim, dl
  for child in node:iter_children() do
    if child:type() == "pipe_table_delimiter_row" then
      dl = child:start()
      local line = lines[dl - tr + 1]
      if not line then return nil end
      delim = lookup(st, line, "d")
      if delim then st.hits = st.hits + 1
      else
        st.misses = st.misses + 1
        delim = new_row(st, line, "d", "delim")
        fill_delim(delim, child, line)
        store(st, delim)
      end
      break
    end
  end
  if not delim then return nil end
  local ncols = #delim.cells
  local icons = icons_in(buf, tr, er - 1)
  local rows = {}
  local tbl = { rows = rows, delim_row = dl, aligns = delim.aligns, ncols = ncols }
  -- pass 2: rows in order
  for child in node:iter_children() do
    local kind = KIND[child:type()]
    if kind then
      local lnum = child:start()
      local line = lines[lnum - tr + 1]
      if line then
        if kind == "delim" then
          rows[#rows + 1] = place(st, delim, lnum)
        else
          if kind == "header" then tbl.header_row = lnum end
          local ic = icons and icons[lnum]
          local suffix = ncols .. "\0" .. (ic and sig_of(ic) or "") .. "\0" .. KCH[kind]
          local row = lookup(st, line, suffix)
          if row then
            st.hits = st.hits + 1
            rows[#rows + 1] = place(st, row, lnum)
          else
            st.misses = st.misses + 1
            rows[#rows + 1] = false
            pending[#pending + 1] = { rows = rows, idx = #rows, node = child, line = line, lnum = lnum,
              suffix = suffix, kind = kind, icons = ic, ncols = ncols }
          end
        end
      end
    end
  end
  if not tbl.header_row or #rows < 2 then return nil end
  return tbl
end

-- Block containers a pipe_table can sit in (tree-sitter-markdown block grammar).
local CONTAINER = { document = true, section = true, list = true, list_item = true, block_quote = true }

-- pipe_table nodes intersecting rows [lo, hi), in document order: a walk of
-- container children (cheaper than a query cursor, whose setup cost is paid on
-- every scan). A node intersects when it starts before hi and its last row
-- (end row, minus one when it ends at column 0) is at least lo.
local function find_tables(node, lo, hi, fn)
  for child in node:iter_children() do
    local sr, _, er, ec = child:range()
    if sr >= hi then return end
    local last = ec > 0 and er or er - 1
    if last >= lo then
      local ty = child:type()
      if ty == "pipe_table" then fn(child)
      elseif CONTAINER[ty] then find_tables(child, lo, hi, fn) end
    end
  end
end

function M.tables(buf, lo, hi)
  if buf == 0 then buf = api.nvim_get_current_buf() end
  local st = state[buf] or M.attach(buf)
  if st.entries > st.max_entries then
    -- drop entries no row maps to any more; if the live rows alone exceed the
    -- limit, raise it instead of thrashing
    local live = {}
    for _, row in pairs(st.by_row) do live[row.orig or row] = true end
    for line, bucket in pairs(st.cache) do
      for suffix, row in pairs(bucket) do
        if not live[row] then bucket[suffix] = nil; st.entries = st.entries - 1 end
      end
      if next(bucket) == nil then st.cache[line] = nil end
    end
    if st.entries > MAX_ENTRIES / 2 then st.max_entries = 2 * st.entries end
  end
  local nlines = api.nvim_buf_line_count(buf)
  lo = math.max(lo or 0, 0)
  hi = math.min(hi or nlines, nlines)
  if lo >= hi then return {} end
  st.gen = st.gen + 1
  st.hits, st.misses = 0, 0
  local ok, parser = pcall(vim.treesitter.get_parser, buf, "markdown")
  if not ok or not parser then return {} end
  local t0 = uv.hrtime()
  parser:parse({ lo, hi })
  st.parse_ms_last = (uv.hrtime() - t0) / 1e6
  local out, pending = {}, {}
  for _, tree in ipairs(parser:trees()) do
    find_tables(tree:root(), lo, hi, function(node)
      local tbl = build(st, buf, node, nlines, pending)
      if tbl then out[#out + 1] = tbl end
    end)
  end
  if #pending > 0 then
    local rlo, rhi = math.huge, -1
    for _, p in ipairs(pending) do
      if p.lnum < rlo then rlo = p.lnum end
      if p.lnum > rhi then rhi = p.lnum end
    end
    -- rows of a table that reaches outside [lo, hi) need their inline trees too
    if rlo < lo or rhi >= hi then parser:parse({ math.min(rlo, lo), math.max(rhi + 1, hi) }) end
    local want = {}
    for _, p in ipairs(pending) do want[p.lnum] = p.line end
    local conc = conceals(parser, buf, rlo, rhi, want)
    for _, p in ipairs(pending) do
      local row = new_row(st, p.line, p.suffix, p.kind)
      fill_row(row, p.node, p.line, p.ncols, conc[p.lnum], p.icons)
      store(st, row)
      p.rows[p.idx] = place(st, row, p.lnum)
    end
  end
  for _, tbl in ipairs(out) do
    local rows = tbl.rows
    tbl.start_row = rows[1].lnum
    tbl.end_row = rows[#rows].lnum + 1
    tbl.indent = rows[1].indent or 0
    for i = 1, #rows do scratch[i] = rows[i].id end
    tbl.sig = table.concat(scratch, ",", 1, #rows)
  end
  st.total_hits, st.total_misses = st.total_hits + st.hits, st.total_misses + st.misses
  return out
end

return M
