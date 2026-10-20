local H = dofile(vim.fn.fnamemodify(_G.arg[0], ":p:h") .. "/helpers.lua")
local scan = require("custom.mdtable.scan")
local api = vim.api

local function ranges(tbls)
  local r = {}
  for i, t in ipairs(tbls) do r[i] = { t.start_row, t.end_row, t.ncols } end
  return r
end

local function row_at(t, lnum)
  for _, r in ipairs(t.rows) do if r.lnum == lnum then return r end end
end

H.run("table count and ranges: needs.md", function()
  H.with_buffer(H.read("needs.md"), function(buf)
    local t = scan.tables(buf)
    H.eq({ { 7, 14, 7 } }, ranges(t))
    H.eq(7, t[1].header_row); H.eq(8, t[1].delim_row)
    H.eq({ "header", "delim", "body" }, { t[1].rows[1].kind, t[1].rows[2].kind, t[1].rows[3].kind })
  end)
end)

H.run("table count and ranges: ledger.md", function()
  H.with_buffer(H.read("ledger.md"), function(buf)
    H.eq({ { 5, 14, 5 }, { 16, 19, 4 } }, ranges(scan.tables(buf)))
  end)
end)

H.run("table count and ranges: inline.md", function()
  H.with_buffer(H.read("inline.md"), function(buf)
    H.eq({ { 2, 13, 3 } }, ranges(scan.tables(buf)))
  end)
end)

H.run("table count and ranges: edge.md (one column, ragged, two tables one blank apart, list item, EOF)", function()
  H.with_buffer(H.read("edge.md"), function(buf)
    local t = scan.tables(buf)
    H.eq({ { 0, 4, 1 }, { 5, 9, 2 }, { 10, 13, 2 }, { 16, 19, 2 }, { 20, 23, 2 } }, ranges(t))
    H.eq(2, t[4].indent, "list item table indent")
    H.eq(0, t[1].indent)
    H.eq(23, api.nvim_buf_line_count(buf))
  end)
end)

H.run("range filter returns only intersecting tables", function()
  H.with_buffer(H.read("ledger.md"), function(buf)
    H.eq({ { 16, 19, 4 } }, ranges(scan.tables(buf, 15, 17)))
    H.eq({}, ranges(scan.tables(buf, 0, 5)))
    H.eq({ { 5, 14, 5 } }, ranges(scan.tables(buf, 13, 14)))
    H.eq({}, ranges(scan.tables(buf, 30, 10)), "inverted range")
    H.eq({}, ranges(scan.tables(buf, 500, 600)), "range past the end")
    H.eq({}, ranges(scan.tables(buf, 6, 6)), "empty range")
  end)
end)

H.run("cell s/e/text", function()
  H.with_buffer(H.read("inline.md"), function(buf)
    local t = scan.tables(buf)[1]
    local link = row_at(t, 5).cells[2]
    H.eq({ 9, 38, "[docs](https://example.com/x)" }, { link.s, link.e, link.text })
    local h = row_at(t, 2).cells
    H.eq({ 2, 6, "Kind" }, { h[1].s, h[1].e, h[1].text })
    H.eq({ 18, 23, "Right" }, { h[3].s, h[3].e, h[3].text })
    local empty = row_at(t, 11).cells[2]
    H.eq(empty.s, empty.e, "empty cell has s == e")
    H.eq("", empty.text)
  end)
  H.with_buffer(H.read("needs.md"), function(buf)
    local t = scan.tables(buf)[1]
    local c = row_at(t, 7).cells
    H.eq({ 2, 3, "#" }, { c[1].s, c[1].e, c[1].text })
    H.eq("Matchadd", c[7].text)
    local b = row_at(t, 9).cells[1]
    H.eq("65", b.text)
  end)
end)

H.run("alignments from delimiter markers", function()
  H.with_buffer(H.read("inline.md"), function(buf)
    H.eq({ "left", "center", "right" }, scan.tables(buf)[1].aligns)
  end)
  H.with_buffer(H.read("edge.md"), function(buf)
    H.eq({ "none", "none" }, scan.tables(buf)[2].aligns)
  end)
end)

H.run("concealed widths of inline markup", function()
  H.with_buffer(H.read("inline.md"), function(buf)
    local t = scan.tables(buf)[1]
    local want = { [4] = 1, [5] = 4, [6] = 1, [7] = 4, [8] = 10, [9] = 4, [10] = 5, [11] = 0, [12] = 18 }
    for lnum, w in pairs(want) do
      local c = row_at(t, lnum).cells[2]
      H.eq(w, c.width, "width of " .. c.text)
    end
    local code = row_at(t, 6).cells[2]
    H.eq({ { 9, 11 }, { 10, 12 } }, { { code.cs[1], code.cs[2] }, { code.ce[1], code.ce[2] } }, "code conceal arrays")
    local pipe = row_at(t, 10).cells[2]
    H.eq("a \\| b", pipe.text)
    H.eq({ { 11 }, { 12 } }, { pipe.cs, pipe.ce }, "\\| conceals the backslash")
    local link = row_at(t, 5).cells[2]
    H.eq({ 9, 14 }, { link.cs[1], link.cs[2] })
    H.eq({ 10, 38 }, { link.ce[1], link.ce[2] }, "link: [ and ](url) concealed, merged")
    H.eq(4, row_at(t, 12).cells[2].lw, "longest word of mixed cell: bold/code/here")
  end)
end)

H.run("inline icon of another namespace counts; own namespace ignored", function()
  H.with_buffer(H.read("inline.md"), function(buf)
    local other = api.nvim_create_namespace("test.other")
    local mine = api.nvim_create_namespace("test.mine")
    scan.ignore_ns(mine)
    api.nvim_buf_set_extmark(buf, other, 5, 9, { virt_text = { { "@@", "TestIcon" } }, virt_text_pos = "inline" })
    api.nvim_buf_set_extmark(buf, mine, 5, 9, { virt_text = { { "###", "X" } }, virt_text_pos = "inline" })
    api.nvim_buf_set_extmark(buf, other, 5, 9, { virt_text = { { "eol", "X" } }, virt_text_pos = "eol" })
    local t = scan.tables(buf)[1]
    local c = row_at(t, 5).cells[2]
    H.eq(6, c.width, "link text 4 + icon 2")
    H.eq(1, #c.marks)
    H.eq({ 9, "@@", "TestIcon", 2 }, { c.marks[1].col, c.marks[1].text, c.marks[1].hl, c.marks[1].width })
    H.eq(6, c.ww[1])
  end)
end)

H.run("ragged rows flagged, cells still filled", function()
  H.with_buffer(H.read("edge.md"), function(buf)
    local t = scan.tables(buf)[2]
    H.eq(false, row_at(t, 5).ragged)
    H.eq(true, row_at(t, 7).ragged); H.eq(3, #row_at(t, 7).cells)
    H.eq(true, row_at(t, 8).ragged); H.eq(1, #row_at(t, 8).cells)
    H.eq("3", row_at(t, 7).cells[3].text)
  end)
end)

H.run("cache: second scan all hits; editing one line evicts only that row", function()
  local lines = H.read("needs.md")
  H.with_buffer(lines, function(buf)
    scan.tables(buf)
    H.eq({ 0, 7, 7 }, { scan.stats(buf).hits, scan.stats(buf).misses, scan.stats(buf).entries })
    scan.tables(buf)
    H.eq({ 7, 0 }, { scan.stats(buf).hits, scan.stats(buf).misses })
    api.nvim_buf_set_lines(buf, 11, 12, false, { lines[12]:gsub("Impossibly", "ImposSIBLY", 1) .. "" })
    local t = scan.tables(buf)
    H.eq({ 6, 1, 7 }, { scan.stats(buf).hits, scan.stats(buf).misses, scan.stats(buf).entries }, "one miss, old entry evicted")
    H.ok(row_at(t[1], 11).cells[2].text:find("ImposSIBLY"), "edited text visible")
    api.nvim_buf_set_lines(buf, 11, 12, false, { lines[12] })
    scan.tables(buf)
    H.eq({ 6, 1, 7 }, { scan.stats(buf).hits, scan.stats(buf).misses, scan.stats(buf).entries }, "original was evicted")
    H.ok(scan.stats(buf).parse_ms_last >= 0)
  end)
end)

H.run("cache: inserting lines above shifts rows, all hits", function()
  H.with_buffer(H.read("needs.md"), function(buf)
    scan.tables(buf)
    api.nvim_buf_set_lines(buf, 0, 0, false, { "new first line", "" })
    local t = scan.tables(buf)
    H.eq({ 7, 0 }, { scan.stats(buf).hits, scan.stats(buf).misses })
    H.eq({ { 9, 16, 7 } }, ranges(t))
    for i, r in ipairs(t[1].rows) do H.eq(8 + i, r.lnum) end
  end)
end)

H.run("duplicate rows get their own lnum", function()
  H.with_buffer({ "| a | b |", "|---|---|", "| x | y |", "| x | y |" }, function(buf)
    local t = scan.tables(buf)[1]
    H.eq({ 0, 1, 2, 3 }, { t.rows[1].lnum, t.rows[2].lnum, t.rows[3].lnum, t.rows[4].lnum })
    t = scan.tables(buf)[1]
    H.eq({ 2, 3 }, { t.rows[3].lnum, t.rows[4].lnum })
    H.ok(t.rows[3] ~= t.rows[4])
  end)
end)

H.run("stale-range guard: J two rows then scan, no error", function()
  H.with_buffer(H.read("needs.md"), function(buf)
    scan.tables(buf)
    vim.bo[buf].undolevels = vim.bo[buf].undolevels -- undo break: keep the buffer content out of the J undo block
    api.nvim_win_set_cursor(0, { 11, 0 })
    vim.cmd("normal! J")
    vim.cmd("normal! J")
    local ok, t = pcall(scan.tables, buf)
    H.ok(ok, tostring(t))
    H.eq(1, #t)
    H.eq(12, t[1].end_row, "two rows joined into one")
    for _, r in ipairs(t[1].rows) do
      for _, c in ipairs(r.cells) do H.ok(c.e <= #api.nvim_buf_get_lines(buf, r.lnum, r.lnum + 1, false)[1]) end
    end
    vim.cmd("silent normal! u")
    H.eq(1, #scan.tables(buf))
  end)
end)

H.run("detach then re-scan works", function()
  H.with_buffer(H.read("inline.md"), function(buf)
    scan.tables(buf)
    scan.detach(buf)
    H.eq(0, scan.stats(buf).entries)
    scan.tables(buf)
    H.eq(11, scan.stats(buf).misses)
  end)
end)

-- Merge [a, b) pairs clipped to [s, e) into two sorted arrays.
local function merged(pairs_, s, e)
  local list = {}
  for _, p in ipairs(pairs_) do
    local a, b = math.max(p[1], s), math.min(p[2], e)
    if b > a then list[#list + 1] = { a, b } end
  end
  table.sort(list, function(x, y) return x[1] < y[1] end)
  local cs, ce = {}, {}
  for _, p in ipairs(list) do
    if #cs > 0 and p[1] <= ce[#ce] then ce[#ce] = math.max(ce[#ce], p[2]) else cs[#cs + 1], ce[#ce + 1] = p[1], p[2] end
  end
  return cs, ce
end

H.run("conceal-only query gives the same ranges as the full highlights query", function()
  local P = require("custom.mdtable.tests.parse") -- read-only use of the current module's full-query scan
  local gen = dofile(vim.fn.fnamemodify(_G.arg[0], ":p:h") .. "/gen.lua")
  local sets = { H.read("inline.md"), H.read("needs.md"), H.read("ledger.md"), H.read("edge.md"), gen.big_table() }
  local checked = 0
  for _, lines in ipairs(sets) do
    H.with_buffer(lines, function(buf)
      local tbls = scan.tables(buf)
      local parser = vim.treesitter.get_parser(buf, "markdown")
      local full = P.conceals(parser, buf, 0, #lines)
      for _, t in ipairs(tbls) do
        for _, row in ipairs(t.rows) do
          if row.kind ~= "delim" then
            local line = lines[row.lnum + 1]
            for _, c in ipairs(row.cells) do
              local cs, ce = merged(full[row.lnum] or {}, c.s, c.e)
              -- scan adds the backslash of `\|`, and (WP-I round 3) of every
              -- backslash escape, as Neovim draws it (highlights.scm conceals
              -- it with #offset!); this full-query oracle conceals neither
              local ms, me = {}, {}
              for i = 1, #c.cs do
                if not (c.ce[i] == c.cs[i] + 1 and line:sub(c.cs[i] + 1, c.cs[i] + 1) == "\\"
                    and line:sub(c.cs[i] + 2, c.cs[i] + 2):match("%p")) then
                  ms[#ms + 1], me[#me + 1] = c.cs[i], c.ce[i]
                end
              end
              H.eq({ cs, ce }, { ms, me }, "row " .. row.lnum .. " cell " .. c.text:sub(1, 30))
              checked = checked + #cs
            end
          end
        end
      end
    end)
  end
  H.ok(checked > 1000, "compared " .. checked .. " ranges")
end)

H.run("entity references are concealed (conceallevel 3)", function()
  H.with_buffer({ "| a | b |", "|---|---|", "| x &amp; y | &copy; |" }, function(buf)
    local c = scan.tables(buf)[1].rows[3].cells
    H.eq(4, c[1].width, "x  y: &amp; hidden")
    H.eq(6, c[2].width, "&copy; is not in the conceal list")
  end)
end)

H.run("container walk finds the same tables as a (pipe_table) query for every window", function()
  local q = vim.treesitter.query.parse("markdown", "(pipe_table) @t")
  local nested = { "> | q | r |", "> |---|---|", "> | 1 | 2 |", "", "- a", "  - b", "", "    | s | t |", "    |---|---|",
    "    | 3 | 4 |", "", "text" }
  local sets = { H.read("inline.md"), H.read("needs.md"), H.read("ledger.md"), H.read("edge.md"), nested }
  local n = 0
  for _, lines in ipairs(sets) do
    H.with_buffer(lines, function(buf)
      local parser = vim.treesitter.get_parser(buf, "markdown")
      parser:parse(true)
      local nl = vim.api.nvim_buf_line_count(buf)
      for lo = 0, nl - 1 do
        for hi = lo + 1, nl do
          local want = {}
          for _, node in q:iter_captures(parser:trees()[1]:root(), buf, lo, hi) do
            want[#want + 1] = node:start()
          end
          local got = {}
          for _, t in ipairs(scan.tables(buf, lo, hi)) do got[#got + 1] = t.start_row end
          H.eq(want, got, ("window [%d, %d)"):format(lo, hi))
          n = n + 1
        end
      end
    end)
  end
  H.ok(n > 1000, n .. " windows")
end)

H.run("tables in a block quote and a nested list item", function()
  H.with_buffer({ "> | q | r |", "> |---|---|", "> | 1 | 2 |", "", "- a", "  - b", "", "    | s | t |", "    |---|---|",
    "    | 3 | 4 |", "", "text" }, function(buf)
    local t = scan.tables(buf)
    H.eq({ { 0, 3, 2 }, { 7, 10, 2 } }, ranges(t))
    H.eq({ 2, 4 }, { t[1].indent, t[2].indent })
    H.eq("3", t[2].rows[3].cells[1].text)
  end)
end)

H.done()
