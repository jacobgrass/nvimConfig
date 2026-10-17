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
  local opts = { width = W, separators = true, tabstop = 8 }
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
      H.eq(#g.lines, #cr.above + (cr.used_sep and 1 or 0) + g.count[r] - #cr.extra + #cr.below,
        "row " .. r .. ": above + row + below")
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
    local seen = 0
    for _, l in ipairs({ 9, 10, 11, 12, 13, 12, 9, 7 }) do
      api.nvim_win_set_cursor(win, { l + 1, 10 })
      M.render(win)
      seen = seen + 1
      local c = M.stats.marks
      if seen > 1 then
        H.eq(0, c.set, "no new persistent marks on a move")
        H.eq(0, c.deleted_conceal, "no conceal_lines deletes")
        H.ok(c.updated <= 4, "updated " .. c.updated .. " <= 2 anchors + 2 conceal toggles")
      end
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
