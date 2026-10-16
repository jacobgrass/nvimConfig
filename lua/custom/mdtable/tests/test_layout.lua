local H = dofile(vim.fn.fnamemodify(_G.arg[0], ":p:h") .. "/helpers.lua")
local scan = require("custom.mdtable.scan")
local layout = require("custom.mdtable.layout")
local api = vim.api

local function first_table(lines, fn)
  H.with_buffer(lines, function(buf) fn(scan.tables(buf)[1], buf) end)
end

-- Every non-filler chunk list covers the cell text exactly once: chunks in
-- order, the first starts at s, the last ends at e, gaps are spaces only.
local function check_cover(row, cell, chunks, line)
  local real = {}
  for _, ch in ipairs(chunks) do if not ch.fill then real[#real + 1] = ch end end
  H.ok(#real >= 1, "at least one chunk")
  H.eq(cell.s, real[1].s, "first chunk starts at cell start")
  H.eq(cell.e, real[#real].e, "last chunk ends at cell end")
  for i = 1, #real do
    H.ok(real[i].s <= real[i].e, "chunk s <= e")
    if i > 1 then
      H.ok(real[i].s >= real[i - 1].e, "chunks do not overlap")
      local gap = line:sub(real[i - 1].e + 1, real[i].s)
      H.ok(gap:match("^ *$"), "gap between chunks is spaces only: [" .. gap .. "]")
    end
  end
end

H.run("columns: natural and minimum widths (inline.md)", function()
  first_table(H.read("inline.md"), function(t)
    local c = layout.columns(t, { width = 200 })
    H.eq({ 6, 18, 5 }, c.natural)
    H.eq({ 6, 10, 5 }, c.min, "min = max(header word, min(longest word (CJK, 10), 12), 3), at most natural")
    H.eq(c.natural, c.widths, "fits: natural widths")
  end)
end)

H.run("columns: water-filling on needs.md at width 115 keeps Raised/Status/Decision natural", function()
  first_table(H.read("needs.md"), function(t)
    local c = layout.columns(t, { width = 115 })
    for j = 5, 7 do H.eq(c.natural[j], c.widths[j], "column " .. j .. " natural") end
    local total = 0
    for j = 1, 7 do total = total + c.widths[j]; H.ok(c.widths[j] >= c.min[j], "above minimum") end
    H.eq(115, total + 8 + 14, "uses the full width")
  end)
end)

H.run("columns: shrink takes from the widest column, ties to the rightmost", function()
  first_table({ "| aaaa bbbb | cccc dddd |", "|---|---|", "| x | y |" }, function(t)
    -- natural 9 + 9; borders 3 + padding 4 = 7
    local c = layout.columns(t, { width = 7 + 17 })
    H.eq({ 9, 8 }, c.widths, "first unit from the rightmost of two equal columns")
    c = layout.columns(t, { width = 7 + 16 })
    H.eq({ 8, 8 }, c.widths)
  end)
end)

H.run("columns: proportional fallback when minimums do not fit", function()
  first_table(H.read("needs.md"), function(t)
    local c = layout.columns(t, { width = 60 })
    local total = 0
    for j = 1, 7 do total = total + c.widths[j]; H.ok(c.widths[j] >= math.min(3, c.natural[j]), "at least min_width") end
    H.ok(total + 8 + 14 <= 60, "fits: " .. total)
    H.ok(total + 8 + 14 > 60 - 7, "uses most of the width: " .. total)
    c = layout.columns(t, { width = 30 })
    H.eq({ 2, 3, 3, 3, 3, 3, 3 }, c.widths, "never below min(min_width, natural) even when it cannot fit")
  end)
end)

H.run("rows: chunk offsets cover every cell exactly once (needs.md, several widths)", function()
  first_table(H.read("needs.md"), function(t, buf)
    for _, W in ipairs({ 60, 115, 200, 2000 }) do
      local cols = layout.columns(t, { width = W })
      local rows = layout.rows(t, cols, { width = W })
      for i, row in ipairs(t.rows) do
        if row.kind ~= "delim" then
          local line = api.nvim_buf_get_lines(buf, row.lnum, row.lnum + 1, false)[1]
          local lr = rows[i]
          for j, cell in ipairs(row.cells) do
            local chunks = lr.cells[j].chunks
            H.eq(lr.lines, #chunks, "every cell has one chunk per grid line")
            check_cover(row, cell, chunks, line)
            for _, ch in ipairs(chunks) do
              H.ok(ch.width <= cols.widths[j], "chunk fits column")
              H.eq(cols.widths[j], ch.width + ch.pad_left + ch.pad_right, "padding fills the column")
            end
          end
        end
      end
    end
  end)
end)

H.run("rows: alignment markers set pad_left/pad_right", function()
  first_table(H.read("inline.md"), function(t)
    local cols = layout.columns(t, { width = 200 })
    local rows = layout.rows(t, cols, { width = 200 })
    local r = rows[3].cells -- body row "bold"
    local right = r[3].chunks[1]
    H.eq(1, right.width)
    H.eq(cols.widths[3] - right.width, right.pad_left, "right aligned: pad_left = width - chunk width")
    H.eq(0, right.pad_right)
    local center = r[2].chunks[1]
    H.eq({ 1, 8, 9 }, { center.width, center.pad_left, center.pad_right }, "centered **b** in 18")
    local left = r[1].chunks[1]
    H.eq({ 4, 0, 2 }, { left.width, left.pad_left, left.pad_right })
  end)
end)

H.run("rows: concealed ranges and icon marks counted in chunk widths", function()
  H.with_buffer(H.read("inline.md"), function(buf)
    local ns = api.nvim_create_namespace("test.icon")
    api.nvim_buf_set_extmark(buf, ns, 5, 9, { virt_text = { { "@@", "X" } }, virt_text_pos = "inline" })
    local t = scan.tables(buf)[1]
    local cols = layout.columns(t, { width = 200 })
    local rows = layout.rows(t, cols, { width = 200 })
    H.eq(6, rows[4].cells[2].chunks[1].width, "link: 4 visible + 2 icon")
    H.eq(10, rows[7].cells[2].chunks[1].width, "CJK 2 per char")
    H.eq(4, rows[8].cells[2].chunks[1].width, "emoji 2 each")
    H.eq(5, rows[9].cells[2].chunks[1].width, "\\| one char")
    -- narrow: the link wraps mid-word; widths still add up with the icon in the first piece
    cols.widths[2] = 3
    rows = layout.rows(t, cols, { width = 200 })
    local ch = rows[4].cells[2].chunks
    H.eq({ 3, 3 }, { ch[1].width, ch[2].width }, "icon 2 + d | o c s")
    local sum = 0
    for _, x in ipairs(ch) do sum = sum + x.width end
    H.eq(6, sum)
  end)
end)

H.run("rows: long words break mid-word, concealed markup stays attached", function()
  first_table({ "| h |", "|---|", "| abcdefghijklmnop |", "| **abcdefgh** |", "| ab cd |" }, function(t, buf)
    local opts = { width = 8, max_word_cap = 4 }
    local cols = layout.columns(t, opts)
    H.eq({ 4 }, cols.widths)
    local rows = layout.rows(t, cols, opts)
    local function texts(i)
      local line = api.nvim_buf_get_lines(buf, t.rows[i].lnum, t.rows[i].lnum + 1, false)[1]
      local out = {}
      for _, ch in ipairs(rows[i].cells[1].chunks) do out[#out + 1] = line:sub(ch.s + 1, ch.e) end
      return out
    end
    H.eq({ "abcd", "efgh", "ijkl", "mnop" }, texts(3))
    H.eq({ "**abcd", "efgh**" }, texts(4))
    H.eq({ "ab", "cd" }, texts(5))
    H.eq(4, rows[3].lines)
  end)
end)

H.run("rows: shorter cells get empty filler chunks", function()
  first_table({ "| a | b |", "|---|---|", "| one two three | x |" }, function(t)
    local opts = { width = 7 + 5 + 1, max_word_cap = 3 }
    local cols = layout.columns(t, opts)
    local rows = layout.rows(t, cols, opts)
    H.eq(3, rows[3].lines)
    local f = rows[3].cells[2].chunks
    H.eq(3, #f)
    H.eq({ true, 0, cols.widths[2] }, { f[2].fill, f[2].width, f[2].pad_right })
  end)
end)

H.run("rows: ragged rows are raw, delimiter is one line", function()
  H.with_buffer(H.read("edge.md"), function(buf)
    local t = scan.tables(buf)[2]
    local rows = layout.rows(t, layout.columns(t, { width = 80 }), { width = 80 })
    H.eq({ 1, 1, true, true }, { rows[2].lines, rows[3].lines, rows[3].ragged, rows[4].ragged })
    local rows4 = layout.rows(t, layout.columns(t, { width = 5 }), { width = 5 })
    H.eq(3, rows4[3].lines, "raw row of 13 cells at width 5 takes 3 screen lines")
  end)
end)

-- Row heights of the current renderer (parse.lua) for non-cursor rows.
local function current_heights(buf, W)
  local P = require("custom.mdtable.tests.parse")
  local parser = vim.treesitter.get_parser(buf, "markdown")
  parser:parse(true)
  local n = api.nvim_buf_line_count(buf)
  local tbls = P.tables(parser, buf, 0, n, P.conceals(parser, buf, 0, n))
  local out = {}
  for ti, t in ipairs(tbls) do
    local widths = P.widths(t, W)
    local lines = {}
    for i, row in ipairs(t.rows) do
      local m = 1
      if row.kind ~= "delim" and not row.ragged then
        for j, c in ipairs(row.cells) do m = math.max(m, #P.wrap(c.chars, widths[j])) end
      end
      lines[i] = m
    end
    out[ti] = { widths = widths, lines = lines }
  end
  return out
end

H.run("layout.table matches the current renderer's widths and row heights", function()
  for _, f in ipairs({ "needs.md", "ledger.md", "inline.md" }) do
    H.with_buffer(H.read(f), function(buf)
      for _, W in ipairs({ 60, 80, 115, 160, 300 }) do
        local cur = current_heights(buf, W)
        local tbls = scan.tables(buf)
        H.eq(#cur, #tbls, f .. " table count")
        for ti, t in ipairs(tbls) do
          local L = layout.table(t, { width = W, separators = true })
          H.eq(cur[ti].widths, L.columns.widths, f .. " widths at " .. W)
          local lines, nbody, sum = {}, 0, 0
          for i, r in ipairs(L.rows) do
            if not t.rows[i].ragged then lines[i] = r.lines else lines[i] = 1 end
            sum = sum + r.lines
            if t.rows[i].kind == "body" then nbody = nbody + 1 end
          end
          H.eq(cur[ti].lines, lines, f .. " row heights at " .. W)
          H.eq(2 + sum + (nbody - 1), L.height, "height with separators")
          H.eq(2 + sum, layout.table(t, { width = W }).height, "height without separators")
        end
      end
    end)
  end
end)

H.run("layout.table height of inline.md by hand", function()
  first_table(H.read("inline.md"), function(t)
    -- borders 2 + header 1 + delimiter 1 + 9 body rows, 8 separators
    H.eq(21, layout.table(t, { width = 200, separators = true }).height)
    H.eq(13, layout.table(t, { width = 200 }).height)
  end)
end)

H.run("determinism and cache", function()
  first_table(H.read("needs.md"), function(t, buf)
    local a = layout.table(t, { width = 115, separators = true })
    local b = layout.table(t, { width = 115, separators = true })
    H.eq(a, b, "same inputs, same outputs")
    local c1 = layout.cached(t, { width = 115, separators = true })
    H.eq(a, c1)
    H.ok(c1 == layout.cached(t, { width = 115, separators = true }), "hit returns the memoized result")
    H.ok(c1 ~= layout.cached(t, { width = 116, separators = true }), "width is part of the key")
    H.ok(c1 ~= layout.cached(t, { width = 115 }), "separators flag is part of the key")
    for w = 50, 100 do layout.cached(t, { width = w }) end
    H.ok(layout.cache_size() <= 32, "LRU bounded: " .. layout.cache_size())
    local t2 = scan.tables(buf)[1]
    H.ok(layout.cached(t2, { width = 100 }) == layout.cached(t, { width = 100 }), "same rows, same signature")
  end)
end)

H.run("cached: two buffers and a re-attached buffer never share a memo entry (F1)", function()
  local A = { "| short | x |", "|---|---|", "| s | y |" }
  local B = { "| a much much longer cell here | y |", "|---|---|", "| s | y |" }
  H.with_buffer(A, function(ba)
    local ta = scan.tables(ba)[1]
    local la = layout.cached(ta, { width = 80 })
    H.with_buffer(B, function(bb)
      local tb = scan.tables(bb)[1]
      H.eq(layout.table(tb, { width = 80 }).widths, layout.cached(tb, { width = 80 }).widths, "buffer B")
      H.eq({ 28, 1 }, layout.cached(tb, { width = 80 }).widths)
    end)
    H.eq(layout.table(ta, { width = 80 }).widths, la.widths, "buffer A")
    scan.detach(ba)
    vim.api.nvim_buf_set_lines(ba, 0, 1, false, { "| a much much longer cell here too | x |" })
    local t2 = scan.tables(ba)[1]
    H.eq(layout.table(t2, { width = 80 }).widths, layout.cached(t2, { width = 80 }).widths, "after re-attach")
  end)
end)

H.run("rows: mid-word breaks keep grapheme clusters whole (F2)", function()
  first_table({ "| h |", "|---|", "| xx❤️yy👨‍👩‍👧zzéww |" }, function(t, buf)
    local cell = t.rows[3].cells[1]
    H.eq(13, cell.width)
    local line = api.nvim_buf_get_lines(buf, 2, 3, false)[1]
    for cw = 3, 5 do
      local cols = layout.columns(t, { width = 200 })
      cols.widths[1] = cw
      local ch = layout.rows(t, cols, { width = 200 })[3].cells[1].chunks
      local sum = 0
      for _, c in ipairs(ch) do
        sum = sum + c.width
        H.ok(c.width <= cw, ("chunk %q width %d > %d"):format(line:sub(c.s + 1, c.e), c.width, cw))
        H.eq(c.width, api.nvim_strwidth(line:sub(c.s + 1, c.e)), "chunk width = its display width")
      end
      H.eq(13, sum, "chunk widths sum to the cell width at " .. cw)
    end
  end)
end)

H.done()
