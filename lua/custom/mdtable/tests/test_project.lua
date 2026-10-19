-- Unit tests for project.lua (pure) and the draw diff (draw.lua via init).
local H = dofile(vim.fn.fnamemodify(_G.arg[0], ":p:h") .. "/helpers.lua")
local scan = require("custom.mdtable.scan")
local layout = require("custom.mdtable.layout")
local project = require("custom.mdtable.project")
local api = vim.api

local function text(chunks)
  local t = {}
  for _, c in ipairs(chunks) do t[#t + 1] = c[1] end
  return table.concat(t)
end

-- The invariant behind "the edited row lines up": for every grid line of the
-- cursor row, left overlay .. real text .. right overlay == the virtual line,
-- and the right overlay sits right after the real text.
local function check_row(tbl, lay, r, k, W)
  -- "row" spill: every real line is the virtual row's line (cell/flow
  -- fallback shift the text down; tested below)
  local opts = { width = W, separators = true, tabstop = 8, spill = "row" }
  local g = project.grid(tbl, lay, opts)
  local res = project.cursor_row(tbl, lay, r, k, opts)
  local row = tbl.rows[r]
  local lefts, rights, wc0 = {}, {}, {}
  for _, m in ipairs(res.marks) do
    local o = m[2]
    if o.virt_text_win_col == 0 then wc0[#wc0 + 1] = o.virt_text
    elseif o.virt_text_win_col then
      lefts[#lefts + 1] = wc0[#wc0]
      rights[#rights + 1] = { col = o.virt_text_win_col, chunks = o.virt_text }
    end
  end
  H.eq(res.n, #rights, ("row %d cell %d: one right overlay per real line"):format(r, k))
  local split = res.n > lay.rows[r].lines
  for li = 1, res.n do
    local sg = res.segs[li]
    local real = sg.sb < sg.se and text(project.text_of(row, row.cells[k], sg.sb, sg.se)) or ""
    local left, right = text(lefts[li]), text(rights[li].chunks)
    H.eq(api.nvim_strwidth(left) + api.nvim_strwidth(real), rights[li].col,
      ("row %d cell %d line %d: right overlay column"):format(r, k, li))
    if not split then
      H.eq(text(g.lines[g.first[r] + li - 1]), left .. real .. right,
        ("row %d cell %d line %d: cursor row == virtual row"):format(r, k, li))
    end
  end
  return res
end

for _, fx in ipairs({ "needs.md", "ledger.md", "inline.md" }) do
  for _, W in ipairs({ 120, 80 }) do
    H.run(("cursor_row matches the virtual rows: %s at %d (every row, every cell)"):format(fx, W), function()
      H.with_buffer(H.read(fx), function(buf)
        local n = 0
        for _, tbl in ipairs(scan.tables(buf, 0, api.nvim_buf_line_count(buf))) do
          local lay = layout.cached(tbl, { width = W, separators = true })
          for r, row in ipairs(tbl.rows) do
            if row.kind ~= "delim" and not row.ragged then
              for k = 1, tbl.ncols do check_row(tbl, lay, r, k, W); n = n + 1 end
            end
          end
        end
        H.ok(n > 10, "cells checked: " .. n)
      end)
    end)
  end
end

-- WP-G: blank rows a cursor row shows (spill rows above or below that carry
-- nothing). "row" mode against the renderer before WP-G (tests/project_old.lua,
-- the 582e4ae projection kept as an oracle): never more blank rows, never a
-- taller row (review F1: blank above + below, and height). "flow" (the
-- default): no blank row whenever the table has lines to carry (spill rows
-- above <= grid lines above the row, below <= lines below it), else never
-- more than "row" (the header row at a narrow width, the last row).
local OLD = dofile(vim.fn.fnamemodify(_G.arg[0], ":p:h") .. "/project_old.lua")
local function old_blank(cr, g)
  local b = 0
  for _, mk in ipairs(cr.marks) do if mk[2].virt_text == g.blank then b = b + 1 end end
  return b
end
local function spill_min(cr)
  local d = cr.dbg
  return math.max(0, math.ceil((d.P + d.lw + d.seg1) / d.W) - 1)
end
local SWEEP = { "needs.md", "needs-live.md", "ledger.md", "inline.md", "soft.md", "edge.md" }
H.run("cursor_row: blank rows and height vs the pre-WP-G renderer (row), none where lines exist (flow); fixtures x widths", function()
  local bad, n, better, fzero, fcap = {}, 0, 0, 0, 0
  for _, fx in ipairs(SWEEP) do
    H.with_buffer(H.read(fx), function(buf)
      for _, tbl in ipairs(scan.tables(buf, 0, api.nvim_buf_line_count(buf))) do
        for _, W in ipairs({ 60, 80, 100, 115, 135 }) do
          local ro = { width = W, separators = true, tabstop = 8, spill = "row" }
          local fo = { width = W, separators = true, tabstop = 8, spill = "flow" }
          local lay = layout.cached(tbl, ro)
          local g = project.grid(tbl, lay, ro)
          local og = OLD.grid(tbl, lay, ro)
          for r, row in ipairs(tbl.rows) do
            if row.kind ~= "delim" and not row.ragged then
              for k = 1, #row.cells do
                local tag = ("%s W=%d row %d cell %d"):format(fx, W, r, k)
                local cr, oc = project.cursor_row(tbl, lay, r, k, ro), OLD.cursor_row(tbl, lay, r, k, ro)
                local fc = project.cursor_row(tbl, lay, r, k, fo)
                n = n + 1
                local nb, ob = cr.blank_above + cr.blank_below, old_blank(oc, og)
                if nb > ob or cr.height > oc.height then
                  bad[#bad + 1] = ("row %s: blank %d (old %d), height %d (old %d)"):format(tag, nb, ob, cr.height, oc.height)
                end
                if nb < ob then better = better + 1 end
                local fb = fc.blank_above + fc.blank_below
                local room = fc.spill_above <= g.first[r] - 1 and fc.spill_below <= #g.lines - (g.first[r] + g.count[r]) + 1
                if room then
                  fcap = fcap + 1
                  if fb ~= 0 then bad[#bad + 1] = ("flow %s: %d blank rows with lines to carry"):format(tag, fb) end
                  if fc.spill_above + fc.spill_below > 0 then fzero = fzero + 1 end
                elseif fb > nb then
                  bad[#bad + 1] = ("flow %s: %d blank rows, row mode %d"):format(tag, fb, nb)
                end
              end
            end
          end
        end
      end
    end)
  end
  print(("INFO sweep: %d cells; row mode fewer blank rows than before in %d; flow spilling cells with no blank row: %d")
    :format(n, better, fzero))
  H.ok(n > 1000 and fzero > 50, "cells checked: " .. n)
  H.eq({}, bad, "regressions")
end)

H.run("cursor_row row mode: the one-line-cell tail rule (WP-G cases and review F1 regressions)", function()
  -- found by the sweep: spill 1 where the minimum is 0 (no separator to carry)
  for _, c in ipairs({ { "ledger.md", 135, 3, 2 }, { "ledger.md", 80, 1, 3 } }) do
    H.with_buffer(H.read(c[1]), function(buf)
      local tbl = scan.tables(buf, 0, api.nvim_buf_line_count(buf))[1]
      local opts = { width = c[2], separators = true, tabstop = 8, spill = "row" }
      local lay = layout.cached(tbl, opts)
      local cr = check_row(tbl, lay, c[3], c[4], c[2])
      H.eq(0, cr.blank_above + cr.blank_below, ("%s W=%d row %d cell %d: no blank row"):format(unpack(c)))
    end)
  end
  -- review F1: the spill row above carries the separator, so keeping the
  -- tail beside the cell shows no blank row; wrapping it drew one below
  for _, c in ipairs({ { "inline.md", 60, 4, 2 }, { "inline.md", 60, 6, 3 } }) do
    H.with_buffer(H.read(c[1]), function(buf)
      local tbl = scan.tables(buf, 0, api.nvim_buf_line_count(buf))[1]
      local opts = { width = c[2], separators = true, tabstop = 8, spill = "row" }
      local lay = layout.cached(tbl, opts)
      local cr = check_row(tbl, lay, c[3], c[4], c[2])
      local tag = ("%s W=%d row %d cell %d"):format(unpack(c))
      H.eq(2, cr.height, tag .. ": height (separator on the spill row + the cell's line)")
      H.eq(0, cr.spill_below, tag .. ": no spill row below")
      H.eq(0, cr.blank_above + cr.blank_below, tag .. ": no blank row")
    end)
  end
end)

-- WP-G: vim.g.mdtable_spill = "cell". The spill rows above carry the row's
-- own grid lines 1..off with only the real cell's column empty (the first one
-- the separator when the row has one); the real text starts on grid line
-- off + 1, every line keeps the grid's bar columns, the spill count is the
-- "row" mode's.
local function chars(t) return vim.fn.split(t, "\\zs") end
local function bar_cols(t)
  local out, c = {}, 0
  for _, ch in ipairs(chars(t)) do
    if ch == "│" then out[#out + 1] = c end
    c = c + api.nvim_strwidth(ch)
  end
  return table.concat(out, ",")
end
local function mask(t, a, b)
  local o, c = {}, 0
  for _, ch in ipairs(chars(t)) do
    local w = api.nvim_strwidth(ch)
    o[#o + 1] = (c >= a and c < b) and string.rep(" ", w) or ch
    c = c + w
  end
  return table.concat(o)
end
H.run("cursor_row spill=cell/flow: spill rows carry the row's lines (cell) or the lines above (flow); bars aligned", function()
  local n, spilled = 0, 0
  local flowed = 0
  for _, fx in ipairs({ "needs.md", "needs-live.md", "ledger.md", "inline.md" }) do
    H.with_buffer(H.read(fx), function(buf)
      for _, tbl in ipairs(scan.tables(buf, 0, api.nvim_buf_line_count(buf))) do
        for _, W in ipairs({ 80, 115, 135 }) do
          local ropts = { width = W, separators = true, tabstop = 8, spill = "row" }
          local copts = { width = W, separators = true, tabstop = 8, spill = "cell" }
          local fopts = { width = W, separators = true, tabstop = 8, spill = "flow" }
          local lay = layout.cached(tbl, ropts)
          local g = project.grid(tbl, lay, ropts)
          local bars = bar_cols(text(g.blank))
          for r, row in ipairs(tbl.rows) do
            if row.kind ~= "delim" and not row.ragged then
              for k = 1, #row.cells do
                local rr = project.cursor_row(tbl, lay, r, k, ropts)
                local cc = project.cursor_row(tbl, lay, r, k, copts)
                local tag = ("%s W=%d row %d cell %d"):format(fx, W, r, k)
                n = n + 1
                H.eq(rr.spill_above, cc.spill_above, tag .. ": same spill rows as row mode")
                H.ok(rr ~= cc, tag .. ": modes memoized apart")
                local wc0 = {}
                for _, mk in ipairs(cc.marks) do
                  if mk[2].virt_text_win_col == 0 then wc0[#wc0 + 1] = text(mk[2].virt_text) end
                end
                local off = 0
                for li = 1, cc.spill_above do
                  local got = wc0[li]
                  if li == 1 and cc.used_sep then
                    H.eq(text(g.lines[g.sep[r]]), got, tag .. ": first spill row carries the separator")
                  else
                    off = off + 1
                    local gl = off <= lay.rows[r].lines and text(g.lines[g.first[r] + off - 1]) or text(g.blank)
                    H.eq(mask(gl, g.left[k], g.left[k] + g.widths[k]), got, tag .. ": spill row " .. li .. " = grid line " .. off .. ", cell emptied")
                    H.eq(bars, bar_cols(got), tag .. ": spill row bars")
                  end
                end
                if off > 0 then spilled = spilled + 1 end
                -- the real cell's lines: left .. text .. right keeps the bars
                local lefts, rights = {}, {}
                local last0
                for _, mk in ipairs(cc.marks) do
                  local o = mk[2]
                  if o.virt_text_win_col == 0 then last0 = text(o.virt_text)
                  elseif o.virt_text_win_col then lefts[#lefts + 1] = last0; rights[#rights + 1] = text(o.virt_text) end
                end
                for li = 1, cc.n do
                  local sg = cc.segs[li]
                  local real = sg.sb < sg.se and text(project.text_of(row, row.cells[k], sg.sb, sg.se)) or ""
                  H.eq(bars, bar_cols(lefts[li] .. real .. rights[li]), tag .. ": text line " .. li .. " bars")
                end
                -- flow: the spill rows carry the last lines above the row, the
                -- above block loses them; the rest falls back to cell mode
                local fc = project.cursor_row(tbl, lay, r, k, fopts)
                H.eq(rr.spill_above, fc.spill_above, tag .. ": flow: same spill rows")
                local ab_end = g.first[r] - 1
                local lil = math.min(fc.spill_above, ab_end)
                H.eq(lil, fc.lines_in_line, tag .. ": flow: lines from above")
                H.eq(ab_end - lil, #fc.above, tag .. ": flow: the above block lost them")
                local fw = {}
                for _, mk in ipairs(fc.marks) do
                  if mk[2].virt_text_win_col == 0 then fw[#fw + 1] = text(mk[2].virt_text) end
                end
                for i = 1, lil do
                  H.eq(text(g.lines[ab_end - lil + i]), fw[i], tag .. ": flow: spill row " .. i)
                end
                for i = lil + 1, fc.spill_above do H.eq(bars, bar_cols(fw[i]), tag .. ": flow fallback row bars") end
                if fc.spill_above <= ab_end and fc.spill_below == 0 then
                  H.eq(0, fc.blank_above + fc.blank_below, tag .. ": flow: no blank row")
                end
                if lil > 0 then flowed = flowed + 1 end
              end
            end
          end
        end
      end
    end)
  end
  H.ok(n > 300 and spilled > 20 and flowed > 20, ("cells checked: %d, with cell-mode spill rows: %d, flowed: %d"):format(n, spilled, flowed))
end)

H.run("cursor_row: icon mark width is part of the real cell and its virtual copy (B4)", function()
  local lines = { "| A | B |", "|---|---|", "| a | see [docs](x) and more |" }
  H.with_buffer(lines, function(buf)
    local ns = api.nvim_create_namespace("test.icons")
    api.nvim_buf_set_extmark(buf, ns, 2, lines[3]:find("[", 1, true) - 1, { virt_text = { { "󰖟 ", "Special" } }, virt_text_pos = "inline" })
    local tbl = scan.tables(buf, 0, 3)[1]
    local lay = layout.cached(tbl, { width = 60, separators = true })
    local g = project.grid(tbl, lay, { width = 60, separators = true })
    H.ok(text(g.lines[g.first[3]]):find("see 󰖟 docs", 1, true), "virtual row shows the icon")
    check_row(tbl, lay, 3, 2, 60)
  end)
end)

H.run("anchors: cursor above, in header, delimiter, each body row, below; EOF; two adjacent tables", function()
  local t1 = { start_row = 2, end_row = 6 } -- header 2, delim 3, body 4, 5
  local t2 = { start_row = 7, end_row = 9 } -- one blank line (6) between
  local function a(t, c) local x = project.anchors(t, c); return { x.anchor, x.inside, table.concat(x.conceal, ",") } end
  H.eq({ 2, false, "3,4,5" }, a(t1, nil), "no cursor")
  H.eq({ 2, false, "3,4,5" }, a(t1, 0), "cursor above: header is the anchor")
  H.eq({ 2, true, "3,4,5" }, a(t1, 2), "cursor in header")
  H.eq({ 3, true, "2,4,5" }, a(t1, 3), "cursor on the delimiter")
  H.eq({ 4, true, "2,3,5" }, a(t1, 4), "cursor in body row 1")
  H.eq({ 5, true, "2,3,4" }, a(t1, 5), "cursor in the last row")
  H.eq({ 5, false, "2,3,4" }, a(t1, 6), "cursor below: the last line, never a line after the table")
  H.eq({ 7, false, "8" }, a(t2, 5), "second table keeps its own header anchor")
  H.eq({ 5, false, "2,3,4" }, a(t1, 7), "cursor in the next table: last line of this one")
  local eof = { start_row = 10, end_row = 13 } -- table ends at the last buffer line
  H.eq({ 12, true, "10,11" }, a(eof, 12), "table at EOF, cursor on the last line")
  H.eq({ 10, false, "11,12" }, a(eof, 3), "table at EOF, cursor above")
end)

H.run("virtual_rows/covered_row: blocks partition the grid around the anchor", function()
  H.with_buffer(H.read("needs.md"), function(buf)
    local tbl = scan.tables(buf, 0, api.nvim_buf_line_count(buf))[1]
    local opts = { width = 120, separators = true }
    local lay = layout.cached(tbl, opts)
    local g = project.grid(tbl, lay, opts)
    local cov = project.covered_row(tbl, lay, 1, opts)
    H.eq(#g.lines, #cov.above + cov.consumed + #cov.below, "covered header: above + drawn on the line + below")
    H.eq(1, #cov.above, "only the top border hangs above the header")
    local tail = project.covered_tail(tbl, lay, opts)
    H.eq(0, #tail.below, "cursor below: nothing hangs below the table")
    H.eq(#g.lines, #tail.above + math.min(tail.rows, #g.lines), "tail: above + drawn on the last line")
    for r = 3, #tbl.rows do
      local cr = project.cursor_row(tbl, lay, r, 2, opts)
      -- (lines from above / below drawn on the line's spill rows: lines_in_line, lines_below_in_line)
      H.eq(#g.lines, #cr.above + cr.lines_in_line + g.count[r] - #cr.extra + #cr.below + cr.lines_below_in_line,
        "row " .. r .. ": above + row + below")
      local rc = project.cursor_row(tbl, lay, r, 2, { width = 120, separators = true, spill = "row" })
      H.eq(#g.lines, #rc.above + (rc.used_sep and 1 or 0) + g.count[r] - #rc.extra + #rc.below, "row " .. r .. " (row mode): above + row + below")
      local vr = project.virtual_rows(tbl, lay, r, opts)
      H.eq(vr.below_from, g.first[r] + g.count[r], "virtual_rows below start")
    end
  end)
end)

-- draw diff, through the real render path in a window
local M = require("custom.mdtable")
H.run("draw: a cursor move touches only cursor-row marks, 2 anchors and 2 conceal toggles; no conceal deletes", function()
  H.with_buffer(H.read("needs.md"), function(buf)
    vim.wo.conceallevel, vim.wo.concealcursor = 3, "nvic"
    M.attach(buf)
    local win = api.nvim_get_current_win()
    local seen, was_tall = 0, false
    for _, l in ipairs({ 9, 10, 11, 12, 13, 12, 9, 7 }) do
      api.nvim_win_set_cursor(win, { l + 1, 10 })
      M.render(win)
      seen = seen + 1
      local c = M.stats.marks
      if seen > 1 then
        H.eq(0, c.set, "no new persistent marks on a move")
        H.eq(0, c.deleted_conceal, "no conceal_lines deletes")
        -- entering or leaving a row drawn raw (taller than the window) also
        -- adds or drops the cell-editor hint line above it: one more update
        local tall = M._last_model(win).tall ~= nil
        local allow = 4 + ((tall or was_tall) and 1 or 0)
        H.ok(c.updated <= allow, ("updated %d <= 2 anchors + 2 conceal toggles%s"):format(c.updated,
          allow > 4 and " + the hint" or ""))
      end
      was_tall = M._last_model(win).tall ~= nil
    end
    -- a move within the same cell changes nothing at all
    api.nvim_win_set_cursor(win, { 11, 11 }); M.render(win)
    api.nvim_win_set_cursor(win, { 11, 12 }); M.render(win)
    local c = M.stats.marks
    H.eq({ 0, 0, 0, 0 }, { c.set, c.updated, c.deleted, c.cursor }, "same cell: nothing touched")
    M.detach(buf)
  end)
end)

H.run("draw: a text edit of the cursor row changes only that row's entries (and its anchors)", function()
  -- the cursor row must fit the window (80x22 here), else it is drawn raw
  -- (WP-E E2): ledger.md's first body row, not needs.md's 28-row row 3
  H.with_buffer(H.read("ledger.md"), function(buf)
    vim.wo.conceallevel, vim.wo.concealcursor = 3, "nvic"
    M.attach(buf)
    local win = api.nvim_get_current_win()
    api.nvim_win_set_cursor(win, { 8, 3 }); M.render(win)
    H.ok(M._last_model(win).tall == nil and M._last_model(win).cursor ~= nil, "cursor row drawn as a grid (fits the window)")
    api.nvim_buf_set_text(buf, 7, 3, 7, 3, { "x" })
    M.render(win)
    local c = M.stats.marks
    H.eq(0, c.set, "no new persistent marks")
    H.eq(0, c.deleted, "no deletes")
    H.ok(c.updated <= 2, "only the two anchor blocks updated: " .. c.updated)
    H.ok(c.cursor > 0, "cursor row redrawn")
    M.detach(buf)
  end)
end)

H.done()
