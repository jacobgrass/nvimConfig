-- Vertical-jitter probe (WP-I). Load in any nvim showing a rendered table
-- (Jacob's config in tmux, or a test child): `dofile(path).run(opts)`.
-- Invariant: moving between the cells of one row changes nothing on screen
-- but the cursor and the glyphs inside that row's grid (topline, topfill,
-- the header float, the row's screen span and grid lines, every other
-- screen row incl. the `… N more rows …` markers; the cursor stays on the
-- row's line). Row moves (Ctrl-j): unless scroll-to-fit scrolled (the
-- entering row was clipped at the bottom: counted, scrolls), the screen rows
-- above both rows stay (the entering row grows downward); rows below them
-- shift only as a block by the two rows' own height change (counted:
-- shifted).
-- run(opts) -> { violations, cell_violations, row_violations = { strings },
--   steps = n, rowmoves = n, scrolls = n, shifted = n, reanchored = n }
-- opts: table = 1 (index in the model), rows = list of table row indices
-- (default: header, the next two rows, the middle and the last row).
local P = {}
local api = vim.api

local function termkey(k) return api.nvim_replace_termcodes(k, true, false, true) end

-- the current window's text area (number column, signs, tabline and
-- statusline left out: relative numbers change with the cursor line)
function P.dump()
  local info = vim.fn.getwininfo(api.nvim_get_current_win())[1]
  local t, cells = {}, {}
  for r = info.winrow, info.winrow + info.height - 1 do
    local s = {}
    for c = info.wincol + info.textoff, info.wincol + info.width - 1 do s[#s + 1] = vim.fn.screenstring(r, c) end
    t[#t + 1] = table.concat(s)
    cells[#cells + 1] = s
  end
  return t, info.winrow - 1, cells, info.wincol + info.textoff - 1
end

-- the screen text with the given text-area cells ({ row, col } 1-based) blanked
local function blanked(cells, at)
  local out = {}
  for r, s in ipairs(cells) do
    local c = s
    for _, p in ipairs(at) do
      if p[1] == r and s[p[2]] then c = vim.list_slice(c); c[p[2]] = " " end
    end
    out[r] = table.concat(c)
  end
  return out
end
P.blanked = blanked

local function border(s) return s:find("─", 1, true) and (s:find("├", 1, true) or s:find("┌", 1, true) or s:find("└", 1, true)) end
local function marker(s) return s:find("more row", 1, true) or s:find("…", 1, true) end

-- screen rows [a, b] of the grid row holding screen row srow (between borders)
local function span(rows, srow)
  if not rows[srow] then return srow, srow end
  local a, b = srow, srow
  while a > 1 and not border(rows[a - 1]) do a = a - 1 end
  while b < #rows and not border(rows[b + 1]) do b = b + 1 end
  return a, b
end

function P.snap()
  local win = api.nvim_get_current_win()
  vim.cmd("redraw")
  -- what the main loop does before the next key: WinScrolled after Neovim's
  -- own scroll (this probe runs inside one Lua call)
  local Mo = require("custom.mdtable")
  if Mo._on_scrolled then Mo._on_scrolled(win); vim.cmd("redraw") end
  local v = vim.fn.winsaveview()
  local cur = api.nvim_win_get_cursor(win)
  local real = cur -- (WP-K: parked, the real cursor is on the park line; the row is the active row)
  cur = require("custom.mdtable").logical_cursor(win)
  local M = require("custom.mdtable")
  local m = M._last_model(win)
  local floats = {}
  local ok, HD = pcall(require, "custom.mdtable.header")
  if ok and HD._floats and HD._floats[win] and api.nvim_win_is_valid(HD._floats[win].win) then
    local c = api.nvim_win_get_config(HD._floats[win].win)
    floats = { row = c.row, height = c.height, hidden = c.hide or false }
  end
  local rows, top, cells, left = P.dump()
  local pos = vim.fn.screenpos(win, real[1], real[2] + 1)
  pos.row = pos.row - top
  pos.col = pos.col - left
  local a, b = span(rows, pos.row)
  -- WP-J: a virtual (tall) cursor row: the cursor sits on its covered line
  -- at the active cell's first byte, so its screen row changes by cell; the
  -- row's span comes from the model (the row's first and last tape lines)
  local vr = m and m.vrow and m.vrow.lnum == cur[1] - 1 and m.vrow or nil
  if vr and vr.pre then
    a = math.max(1, vr.pre + 1 + (vr.proj.first_t - vr.proj.s))
    b = math.min(#rows, vr.pre + 1 + (vr.proj.last_t - vr.proj.s))
  end
  return { topline = v.topline, topfill = v.topfill, skipcol = v.skipcol or 0, lnum = cur[1] - 1, col = cur[2], srow = pos.row,
    k = m and m.cursor and m.cursor.k or (vr and vr.k) or (m and m.tall and "raw") or 0, tall = m and m.tall and true or false,
    virtual = vr ~= nil, float = vim.inspect(floats, { newline = "" }), rows = rows, a = a, b = b, cells = cells, pcol = pos.col,
    height = m and m.cursor and m.cursor.proj.rows or (vr and vr.proj.rows) or (m and m.tall and m.tall.rows) or -1,
    nl = m and m.cursor and m.cursor.proj.nl or (vr and vr.ri.nl) or -1, lil = m and m.cursor and m.cursor.proj.lines_in_line or 0 }
end

local function cmp_cell(base, s, tag, out)
  local function bad(what) out[#out + 1] = tag .. ": " .. what end
  if s.lnum ~= base.lnum then bad(("cursor left the row's line (%d -> %d)"):format(base.lnum, s.lnum)) return end
  -- the cursor line at the window top: topfill follows the lines from
  -- above drawn on the line (init.lua compensation), the screen does not move
  local tf, btf = s.topfill, base.topfill
  if s.topline - 1 == s.lnum then tf, btf = tf + s.lil, btf + base.lil end
  if s.topline ~= base.topline or tf ~= btf or s.skipcol ~= base.skipcol then
    bad(("view %d/%d/%d -> %d/%d/%d"):format(base.topline, base.topfill, base.skipcol, s.topline, s.topfill, s.skipcol))
  end
  if s.float ~= base.float then bad("header float " .. base.float .. " -> " .. s.float) end
  if s.tall ~= base.tall then bad(("raw %s -> %s"):format(tostring(base.tall), tostring(s.tall))) end
  if s.a ~= base.a or s.b ~= base.b then bad(("row span %d..%d -> %d..%d"):format(base.a, base.b, s.a, s.b)) end
  if s.nl ~= base.nl then bad(("row grid lines %d -> %d"):format(base.nl, s.nl)) end
  local diff = {}
  for i = 1, math.max(#base.rows, #s.rows) do
    if (i < base.a or i > base.b) and base.rows[i] ~= s.rows[i] then diff[#diff + 1] = i end
  end
  if #diff > 0 then
    local d = diff[1]
    bad(("screen rows outside the row %d..%d changed: %s; row %d %q -> %q"):format(base.a, base.b, table.concat(diff, ",", 1, math.min(#diff, 12)),
      d, vim.fn.strcharpart(base.rows[d] or "", 0, 60), vim.fn.strcharpart(s.rows[d] or "", 0, 60)))
  end
  -- WP-I round 3: the screen text (the row's own grid, every other row and
  -- the header float) is byte-identical across the cells, the cursor's two
  -- positions blanked: only the cursor moves
  local at = { { base.srow, base.pcol }, { s.srow, s.pcol } }
  local A, B = blanked(base.cells, at), blanked(s.cells, at)
  local td = {}
  for i = 1, math.max(#A, #B) do if A[i] ~= B[i] then td[#td + 1] = i end end
  if #td > 0 then
    local d = td[1]
    local inrow = d >= base.a and d <= base.b
    out[#out + 1] = tag .. (": text: screen text differs at rows %s (%s); row %d %q -> %q"):format(table.concat(td, ",", 1, math.min(#td, 12)),
      inrow and "in the row" or "outside the row", d, A[d] or "", B[d] or "")
  end
end

function P.run(opts)
  opts = opts or {}
  local M = require("custom.mdtable")
  local win = api.nvim_get_current_win()
  local m = M.model(win)
  local out, steps, rowmoves, scrolls, shifted, reanchored, clipped, skipped = {}, 0, 0, 0, 0, 0, 0, {}
  local entry = m and m.tables[opts.table or 1]
  if not entry then return { violations = { "no table" }, steps = 0 } end
  local tbl = entry.tbl
  local g = M.grid(entry)
  local R = {}
  for i, row in ipairs(tbl.rows) do if row.kind ~= "delim" and #row.cells > 0 then R[#R + 1] = i end end
  local pick = opts.rows
  if not pick and #R <= 12 then pick = R end -- WP-J: every row of a small table (each tall row)
  if not pick then
    local seen = {}
    pick = {}
    for _, i in ipairs({ 1, 2, 3, math.ceil(#R / 2), #R }) do
      if R[i] and not seen[R[i]] then seen[R[i]] = true; pick[#pick + 1] = R[i] end
    end
  end
  local L, Hk = termkey("<C-l>"), termkey("<C-h>")
  local raw, virtual = {}, {} -- WP-J: rows drawn raw / virtual while the cursor is on them
  for _, r in ipairs(pick) do
    local row = tbl.rows[r]
    local lnum = tbl.start_row + r - 1
    M.goto(win, lnum, row.cells[1].s)
    -- opts.settle (ms): let other plugins' deferred decorations (e.g.
    -- render-markdown's debounced render) land before the first snapshot
    if opts.settle then vim.wait(opts.settle, function() return false end) end
    local base = P.snap()
    if base.tall then raw[#raw + 1] = r end
    if base.virtual then virtual[#virtual + 1] = r end
    local nc = #row.cells
    local seq = {}
    for _ = 2, nc do seq[#seq + 1] = L end
    for _ = 2, nc do seq[#seq + 1] = Hk end
    for i, key in ipairs(seq) do
      vim.api.nvim_feedkeys(key, "mx", false)
      local s = P.snap()
      steps = steps + 1
      cmp_cell(base, s, ("row %d step %d (%s, cell %s)"):format(r, i, key == L and "C-l" or "C-h", tostring(s.k)), out)
    end
  end
  local ncell = #out
  -- row moves: header to the last row with Ctrl-j
  local J = termkey("<C-j>")
  M.goto(win, tbl.start_row, tbl.rows[1].cells[1].s)
  local prev = P.snap()
  for _ = 2, #R do
    vim.api.nvim_feedkeys(J, "mx", false)
    local s = P.snap()
    rowmoves = rowmoves + 1
    local intop = function(x) return x.topline - 1 >= tbl.start_row and x.topline - 1 < tbl.end_row end
    -- clipped at the bottom: the leaving row drawn as a virtual row from
    -- its old top, the separator, the entering row (its new span) and the
    -- border after it do not fit in the window; scroll-to-fit (or Neovim,
    -- for a raw row) moves the view
    local rl = tbl.rows[prev.lnum - tbl.start_row + 1]
    local lv = rl and g.count[prev.lnum - tbl.start_row + 1] or 0
    local function marks_of(x)
      local t = {}
      for i = 1, #x.rows do if marker(x.rows[i]) then t[#t + 1] = i .. "=" .. x.rows[i] end end
      return table.concat(t, ";")
    end
    -- skipped moves are listed with how far the leaving row's first line
    -- moved up (the shift of the rows above): skipped = { { from, to, why, shift } }
    local function shift()
      local t = prev.rows[prev.a]
      for j = 1, #s.rows do if s.rows[j] == t then return prev.a - j end end
      return nil
    end
    if prev.a + lv + 1 + (s.b - s.a + 1) > #prev.rows then
      scrolls = scrolls + 1
      skipped[#skipped + 1] = { prev.lnum, s.lnum, "entering row clipped at the bottom", shift() }
    elseif marks_of(prev) ~= marks_of(s) or prev.float ~= s.float then
      -- a clip re-cut (its `… N more rows …` marker moved or changed) or
      -- the header float shown/hidden/changed: counted, not compared
      clipped = clipped + 1
      skipped[#skipped + 1] = { prev.lnum, s.lnum, "clip re-cut or header float changed", shift() }
    else
      -- the view's top line in the table: Neovim's view hangs on the anchor
      -- (cursor) line, which a row move changes; reanchor() re-seats it
      if intop(prev) or intop(s) then reanchored = reanchored + 1 end
      -- above both rows: unchanged; below both: the same rows, shifted as a
      -- block only by the height change of the two rows themselves (a row
      -- that grows while it holds the cursor: the cell fallback near the
      -- table top, "row"/"cell" spill rows; counted in `shifted`)
      local top = math.min(prev.a, s.a)
      local diff = {}
      for i = 1, top - 1 do
        if prev.rows[i] ~= s.rows[i] and not marker(prev.rows[i] or "") and not marker(s.rows[i] or "") then diff[#diff + 1] = i end
      end
      local from = math.max(prev.b, s.b) + 1
      local found
      for j = prev.b + 1, #prev.rows + 1 do
        local okj = true
        for t = 0, #s.rows - from do
          local x, y = prev.rows[j + t], s.rows[from + t]
          if x == nil then break end
          if x ~= y and not marker(x) and not marker(y) then okj = false; break end
        end
        if okj then found = j; break end
      end
      if not found then diff[#diff + 1] = "below" end
      if found and found ~= from then shifted = shifted + 1 end
      if #diff > 0 then
        local d = type(diff[1]) == "number" and diff[1] or from
        out[#out + 1] = ("row move %d -> %d (spans %d..%d -> %d..%d): rows outside both rows changed: %s; row %d %q -> %q"):format(
          prev.lnum, s.lnum, prev.a, prev.b, s.a, s.b, table.concat(vim.tbl_map(tostring, diff), ","), d,
          vim.fn.strcharpart(prev.rows[d] or "", 0, 50), vim.fn.strcharpart(s.rows[d] or "", 0, 50))
      end
    end
    prev = s
  end
  local cellv, rowv = {}, {}
  for i, v in ipairs(out) do if i <= ncell then cellv[#cellv + 1] = v else rowv[#rowv + 1] = v end end
  return { violations = out, cell_violations = cellv, row_violations = rowv, steps = steps, rowmoves = rowmoves,
    scrolls = scrolls, shifted = shifted, reanchored = reanchored, clipped = clipped, skipped = skipped, raw = raw, virtual = virtual }
end

-- write run() as JSON lines to path (tmux use)
function P.run_to(path, opts)
  local res = P.run(opts)
  local lines = { ("steps %d rowmoves %d scrolls %d reanchored %d shifted %d violations %d"):format(res.steps, res.rowmoves or 0,
    res.scrolls or 0, res.reanchored or 0, res.shifted or 0, #res.violations) }
  for _, v in ipairs(res.violations) do lines[#lines + 1] = v end
  vim.fn.writefile(lines, path)
  return res
end

return P
