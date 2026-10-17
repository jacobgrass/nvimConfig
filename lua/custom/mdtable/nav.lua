-- custom.mdtable.nav: cell navigation keys (buffer-local maps in n, x and i),
-- ported from the spike onto the layout/project model.
-- Inside a rendered table: h/l (<Left>/<Right>) move one visible character
-- within the cursor's cell, j/k (<Down>/<Up>) move between the cell's wrapped
-- grid lines at the same visual column; Ctrl-h/Ctrl-l go to the
-- previous/next cell (continuing on the previous/next row), Ctrl-j/Ctrl-k to
-- the same column of the next/previous row; the delimiter row is skipped.
-- Leaving and crossing rows (vim.g.mdtable_jk_cross_rows ~= false): j on a
-- cell's last grid line goes to the same cell of the next row (first grid
-- line, same visual column), k on its first grid line to the previous row
-- (last grid line); j/k past the last body row / the header, and Ctrl-j /
-- Ctrl-k there, leave the table to the line after / before it at the same
-- screen column. With the option false every move clamps at the cell and
-- table edges. <C-d>/<C-u>/<C-f>/<C-b> (n, x) move by rendered screen lines
-- (N.scroll) when a table is in their range. Plain h/j/k/l are not mapped in
-- insert mode (they are typed text). Outside tables every key does what
-- NvChad maps it to (lua/core/mappings.lua): j/k/<Down>/<Up> gj/gk (plain j/k
-- with a count, or onto a table line from the screen line next to it),
-- Ctrl-hjkl window moves in normal mode and arrows in insert mode, the rest
-- builtin. g:mdtable_table_motions = false disables the maps.
local api = vim.api
local project = require("custom.mdtable.project")
local N = {}
local core -- custom.mdtable (set by setup)
local want = {} -- win -> { lnum, col, vcol } (sticky column for j/k)

local KEYS = {
  { lhs = "h", act = "h", modes = { "n", "x" } },
  { lhs = "l", act = "l", modes = { "n", "x" } },
  { lhs = "j", act = "j", modes = { "n", "x" } },
  { lhs = "k", act = "k", modes = { "n", "x" } },
  { lhs = "<Left>", act = "h", modes = { "n", "x", "i" } },
  { lhs = "<Right>", act = "l", modes = { "n", "x", "i" } },
  { lhs = "<Down>", act = "j", modes = { "n", "x", "i" } },
  { lhs = "<Up>", act = "k", modes = { "n", "x", "i" } },
  { lhs = "<C-h>", act = "H", modes = { "n", "x", "i" }, win = "<C-w>h", ins = "<Left>" },
  { lhs = "<C-l>", act = "L", modes = { "n", "x", "i" }, win = "<C-w>l", ins = "<Right>" },
  { lhs = "<C-j>", act = "J", modes = { "n", "x", "i" }, win = "<C-w>j", ins = "<Down>" },
  { lhs = "<C-k>", act = "K", modes = { "n", "x", "i" }, win = "<C-w>k", ins = "<Up>" },
}
N.KEYS = KEYS
local DESC = "mdtable: cell navigation"

function N.setup(m) core = m end

local function short_mode()
  local m = api.nvim_get_mode().mode
  if m:sub(1, 1) == "i" then return "i" end
  if m:match("^[vV\22]") then return "x" end
  return "n"
end

-- Table of the last render containing lnum (0-based): entry, row index.
local function table_at(model, lnum)
  for _, e in ipairs(model and model.tables or {}) do
    local t = e.tbl
    if lnum >= t.start_row and lnum < t.end_row then return e, lnum - t.start_row + 1 end
  end
end

-- NvChad's behaviour for a key outside tables (count: v:count of the press).
local function fallback(model, key, m, count)
  if m == "i" then return key.ins or key.lhs end
  if key.win then return m == "n" and key.win or key.lhs end
  if key.act ~= "j" and key.act ~= "k" then return key.lhs end
  if count > 0 then return key.act end
  -- gj/gk, but plain j/k onto a table line from the screen line next to it:
  -- gj/gk do not step onto the table's concealed lines
  local l, dir = api.nvim_win_get_cursor(0)[1] - 1, key.act == "j" and 1 or -1
  if table_at(model, l + dir) then
    local vc = vim.fn.virtcol(".") - 1
    local o = dir == 1 and { start_row = l, end_row = l, start_vcol = vc }
      or { start_row = l, end_row = l, start_vcol = 0, end_vcol = vc + 1 }
    if api.nvim_win_text_height(0, o).all <= 1 then return "STEP" end
  end
  -- an unwrapped line: plain j/k (same motion; gk next to concealed table
  -- lines and their filler does not move at all)
  if api.nvim_win_text_height(0, { start_row = l, end_row = l, start_vcol = 0 }).all <= 1 then return key.act end
  return "g" .. key.act
end

-- Visible characters of cell k on one unwrapped line (no drawn layout).
local function plain_positions(row, k)
  local c = row.cells[k]
  local P = {}
  if not c then return P end
  local line, cs, ce = row.line, c.cs, c.ce
  local x, i, kc = 0, c.s, 1
  while i < c.e do
    while kc <= #cs and ce[kc] <= i do kc = kc + 1 end
    if kc <= #cs and cs[kc] <= i then
      i = ce[kc]
    else
      local b = line:byte(i + 1)
      local n = b < 0x80 and 1 or (b >= 0xF0 and 4 or (b >= 0xE0 and 3 or 2))
      local w = n == 1 and 1 or api.nvim_strwidth(line:sub(i + 1, i + n))
      if w > 0 then P[#P + 1] = { b = i, n = n, w = w, col = x, r = 1 } end
      x, i = x + w, i + n
    end
  end
  return P
end

-- Navigable positions of the cursor's cell: { b, n, w, col, r (grid line) }.
local function positions(model, row, r, col)
  local cur = model.cursor
  local k = project.cell_at(row, col)
  local bars = project.bars(row)
  if not (cur and cur.r == r and cur.k == k and cur.tbl.rows[r] == row) then
    return plain_positions(row, k), { k = k, nextbar = bars[k + 1] }
  end
  local P = {}
  for li, nv in ipairs(cur.proj.nav) do
    for i = 1, #nv.b do P[#P + 1] = { b = nv.b[i], n = nv.n[i], w = nv.w[i], col = nv.col[i], r = li } end
  end
  return P, { k = k, nextbar = bars[k + 1] }
end

local function clamp(x, a, b) return math.max(a, math.min(b, x)) end

-- Insert mode: also the position after the cell's last visible character,
-- unless that is the next cell's bar (the renderer would switch cells there).
local function with_end(P, cell)
  local last = P[#P]
  local e = last.b + last.n
  if cell.nextbar and e >= cell.nextbar then return P end
  local Q = vim.list_extend({}, P)
  Q[#Q + 1] = { b = e, n = 0, w = 0, col = last.col + last.w, r = last.r }
  return Q
end

local function landing(row, k, insert)
  local P = plain_positions(row, k)
  if P[1] then return P[1].b end
  local c = row.cells[k]
  return clamp(c.s, 0, math.max(#row.line - (insert and 0 or 1), 0))
end

local function cross_rows() return vim.g.mdtable_jk_cross_rows ~= false end

-- Byte in cell k of table row x (entry e) on grid line li (nil: the cell's
-- last line) at in-cell visual column vcol (pad included), from the layout's
-- chunks: what the cursor-row projection draws on that line.
local function col_at(e, x, k, vcol, li, insert)
  local row = e.tbl.rows[x]
  local lc = e.lay.rows[x] and e.lay.rows[x].cells[k]
  local P = plain_positions(row, k)
  if not lc or #P == 0 then return landing(row, k, insert) end
  local real = {}
  for _, ch in ipairs(lc.chunks) do if not ch.fill then real[#real + 1] = ch end end
  local ch = real[math.min(li or #real, #real)]
  if not ch then return P[1].b end
  local best, c0
  for _, p in ipairs(P) do
    if p.b >= ch.s and p.b < ch.e then
      c0 = c0 or p.col
      if not best or p.col - c0 + (ch.pad_left or 0) <= vcol then best = p end
    end
  end
  return best and best.b or P[1].b
end

-- Screen column of the cursor in the text area of win (0-based).
local function screen_col(win, lnum, col)
  local sp = vim.fn.screenpos(win, lnum + 1, col + 1)
  local info = vim.fn.getwininfo(win)[1]
  if not info or sp.col == 0 then return 0 end
  return math.max(sp.col - info.wincol - info.textoff, 0)
end

-- Byte of buffer line l at screen row s (nil: its last) and screen column sc.
local function line_col(win, l, s, sc)
  local line = api.nvim_buf_get_lines(api.nvim_win_get_buf(win), l, l + 1, false)[1] or ""
  if line == "" then return 0 end
  local info = vim.fn.getwininfo(win)[1]
  local W = math.max(info.width - info.textoff, 1)
  if not s then s = math.max(math.ceil(vim.fn.strdisplaywidth(line) / W) - 1, 0) end
  local b = vim.fn.virtcol2col(win, l + 1, s * W + sc + 1)
  return math.max(math.min(b - 1, #line - 1), 0)
end

-- Leave table t of win to the line after (dir 1) or before (-1) it, at
-- screen column sc. false when there is no such line (the move clamps).
-- extra: further lines past that one (the rest of a count).
local function exit_table(win, t, dir, sc, extra)
  local n = api.nvim_buf_line_count(api.nvim_win_get_buf(win))
  local l = dir == 1 and t.end_row or t.start_row - 1
  if l < 0 or l >= n then return false end
  l = math.max(0, math.min(n - 1, l + dir * (extra or 0)))
  local c = line_col(win, l, dir == 1 and 0 or nil, sc)
  core.set_intent(win, { kind = "line", lnum = l, col = c })
  core.goto(win, l, c)
  want[win] = nil
  return true
end

-- Grid lines of cell k of table row x (entry e): its layout chunks.
local function cell_lines(e, x, k)
  local lc = e.lay.rows[x] and e.lay.rows[x].cells[k]
  local n = 0
  for _, ch in ipairs(lc and lc.chunks or {}) do if not ch.fill then n = n + 1 end end
  return math.max(n, 1)
end

-- Rows of table t without the delimiter: { row, lnum, x }, and the index of
-- row r in it (the delimiter: between the header and the first body row).
local function rows_of(t, r)
  local R, ri = {}, nil
  for x, rw in ipairs(t.rows) do
    if rw.kind ~= "delim" then
      R[#R + 1] = { row = rw, lnum = t.start_row + x - 1, x = x }
      if x == r then ri = #R end
    end
  end
  return R, ri
end


function N.run(i, count)
  local key = KEYS[i]
  local win = api.nvim_get_current_win()
  local m = short_mode()
  local model = core.model(win) -- renders first when the buffer or cursor changed
  local cur = api.nvim_win_get_cursor(win)
  local lnum, col = cur[1] - 1, cur[2]
  local e, r = table_at(model, lnum)
  if not e then
    local keys = fallback(model, key, m, count)
    if keys == "STEP" then -- plain j/k onto a table line
      local l = lnum + (key.act == "j" and 1 or -1)
      local line = api.nvim_buf_get_lines(0, l, l + 1, false)[1] or ""
      core.goto(win, l, math.min(col, math.max(#line - 1, 0)))
      return
    end
    if count > 0 and m ~= "i" then keys = count .. keys end
    api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "ni", false)
    return
  end
  local t = e.tbl
  local row = t.rows[r]
  local n, insert, act = math.max(count, 1), m == "i", key.act
  -- cursor() instead of nvim_win_set_cursor: the latter scrolls at once for
  -- the old marks (the target line is still concealed); cursor() leaves the
  -- scrolling to Neovim's main loop, after the CursorMoved render
  -- Render at once, before Neovim validates the cursor: with the target
  -- still concealed and more filler than the window is tall, Neovim would
  -- move the cursor elsewhere (reproduced with plain extmarks).
  local function go(l, c) core.goto(win, l, c) end
  -- drawn screen column of in-cell column vcol of cell k on the cursor row
  -- (review WP-E F1: screenpos() counts the concealed bytes and inline
  -- padding before the cell): the cell's left edge in the grid + vcol. A row
  -- drawn raw (ragged, taller than the window) is plain text: screenpos.
  local function drawn_col(k, vcol)
    local raw = model.tall and model.tall.lnum == lnum
    if model.cursor and model.cursor.lnum == lnum and not raw then return core.grid(e).left[k] + vcol end
    -- raw: the wanted column (gj/gk to a shorter last screen row keep it)
    local v = api.nvim_win_call(win, vim.fn.winsaveview)
    local info = vim.fn.getwininfo(win)[1]
    local W = math.max(info.width - info.textoff, 1)
    if raw and v.curswant < 1e6 then return v.curswant % W end
    return screen_col(win, lnum, col)
  end
  -- cell and in-cell visual column of the cursor (the sticky column of j/k)
  local function here_vcol()
    local P, cell = positions(model, row, r, col)
    local here = P[1]
    for _, p in ipairs(P) do if p.b <= col then here = p end end
    if not here then return cell.k, 0 end
    local v = here.col + ((here.b < col and here.n > 0) and here.w or 0)
    local w = want[win]
    if w and w.lnum == lnum and w.col == col then v = w.vcol end
    return cell.k, v
  end
  -- j/k past the cell's first/last grid line: the same cell of the
  -- previous/next row, or out of the table past the header / last row
  -- m: grid lines to move past the cell's edge (a count walks on through
  -- the same cell of the following rows; past the table, buffer lines)
  local function cross(dir, k, vcol, m)
    local R, ri = rows_of(t, r)
    if row.kind == "delim" then ri = dir == 1 and 1 or 2 end
    while true do
      ri = ri + dir
      local target = R[ri]
      if not target then return exit_table(win, t, dir, drawn_col(k, vcol), m - 1) end
      local kk = math.min(k, #target.row.cells)
      local nl = cell_lines(e, target.x, kk)
      if m <= nl then
        local li = dir == 1 and m or nl - m + 1
        local c = kk > 0 and col_at(e, target.x, kk, vcol, li, insert) or 0
        go(target.lnum, c)
        want[win] = { lnum = target.lnum, col = c, vcol = vcol }
        return
      end
      m = m - nl
    end
  end
  if act == "h" or act == "l" or act == "j" or act == "k" then
    if row.kind == "delim" then
      if (act == "j" or act == "k") and cross_rows() then cross(act == "j" and 1 or -1, 1, 0, n) end
      return
    end
    local P, cell = positions(model, row, r, col)
    if #P == 0 and (act == "j" or act == "k") and cross_rows() then
      cross(act == "j" and 1 or -1, cell.k, 0, n)
      return
    end
    if #P == 0 then -- no visible text: settle on the cell's landing position
      local to = landing(row, cell.k, insert)
      if to ~= col then go(lnum, to) end
      return
    end
    if insert then P = with_end(P, cell) end
    if act == "h" or act == "l" then
      local le, lt = 0, 0 -- positions at or before / before the cursor
      for _, p in ipairs(P) do
        if p.b <= col then le = le + 1 end
        if p.b < col then lt = lt + 1 end
      end
      local x = act == "l" and le + n or lt + 1 - n
      go(lnum, P[clamp(x, 1, #P)].b)
      want[win] = nil
      return
    end
    local here = P[1] -- last position at or before the cursor
    for _, p in ipairs(P) do if p.b <= col then here = p end end
    local vcol = here.col + ((here.b < col and here.n > 0) and here.w or 0)
    local w = want[win]
    if w and w.lnum == lnum and w.col == col then vcol = w.vcol end
    -- a row drawn raw (taller than the window, init.lua): one grid line in
    -- the model, several screen rows: gj/gk walk them, then cross the row
    -- edge (review WP-E F2)
    if model.tall and model.tall.lnum == lnum and not model.tall.anchor then
      local vc = api.nvim_win_call(win, function() return vim.fn.virtcol(".") - 1 end)
      local o = act == "j" and { start_row = lnum, end_row = lnum, start_vcol = vc }
        or { start_row = lnum, end_row = lnum, start_vcol = 0, end_vcol = vc + 1 }
      local rem = math.max(api.nvim_win_text_height(win, o).all - 1, 0)
      if rem >= n or not cross_rows() then
        local c = math.min(n, rem)
        if c > 0 then
          api.nvim_feedkeys(api.nvim_replace_termcodes((insert and "<C-o>" or "") .. (c > 1 and c or "") .. "g" .. act,
            true, false, true), "ni", false)
        end
        want[win] = nil
        return
      end
      cross(act == "j" and 1 or -1, cell.k, vcol, n - rem)
      return
    end
    local rr0 = here.r + (act == "j" and n or -n)
    if (rr0 > P[#P].r or rr0 < P[1].r) and cross_rows() then
      cross(act == "j" and 1 or -1, cell.k, vcol, act == "j" and rr0 - P[#P].r or P[1].r - rr0)
      return
    end
    local rr = clamp(rr0, P[1].r, P[#P].r)
    if rr == here.r then return end
    local target
    for _, p in ipairs(P) do
      if p.r == rr and (not target or p.col <= vcol) then target = p end
    end
    go(lnum, target.b)
    want[win] = { lnum = lnum, col = target.b, vcol = vcol }
    return
  end
  -- cell to cell
  want[win] = nil
  local R, ri = {}, nil -- rows without the delimiter
  for x, rw in ipairs(t.rows) do
    if rw.kind ~= "delim" then
      R[#R + 1] = { row = rw, lnum = t.start_row + x - 1 }
      if x == r then ri = #R end
    end
  end
  local k = project.cell_at(row, col)
  if row.kind == "delim" then
    if act == "H" or act == "L" then return end
    ri = act == "J" and 1 or 2 -- between header (1) and the first body row (2)
  end
  if act == "J" or act == "K" then
    local to = ri + (act == "J" and n or -n)
    if (to > #R or to < 1) and cross_rows() and row.kind ~= "delim" then
      if exit_table(win, t, act == "J" and 1 or -1, drawn_col(here_vcol())) then return end
    end
    ri = clamp(to, 1, #R)
    k = math.min(k, #R[ri].row.cells)
  else
    k = math.min(k, #R[ri].row.cells)
    for _ = 1, n do
      if act == "L" then
        if k < #R[ri].row.cells then k = k + 1 elseif ri < #R then ri, k = ri + 1, 1 else break end
      else
        if k > 1 then k = k - 1 elseif ri > 1 then ri = ri - 1; k = #R[ri].row.cells else break end
      end
    end
  end
  if #R[ri].row.cells == 0 then return end
  go(R[ri].lnum, landing(R[ri].row, k, insert))
end

-- <C-d>/<C-u>/<C-f>/<C-b> by rendered screen lines (Jacob, WP-E E3). The
-- walk goes over buffer lines outside tables (their screen rows) and the
-- full grid of each rendered table (one step per grid line); amount: 'scroll'
-- (a count sets it, as for the builtin) or half the window for d/u, the
-- window - 2 times the count for f/b. On a table grid line of a row the
-- cursor lands in that row, the same cell, that grid line, the same visual
-- column; on a border, separator or the delimiter it goes on in the
-- direction of the move. The view then keeps the cursor's screen row (the
-- viewport plan applies after). A walk that meets no table is the builtin.
local SCROLL = { ["<C-d>"] = { 1, "half" }, ["<C-u>"] = { -1, "half" }, ["<C-f>"] = { 1, "page" }, ["<C-b>"] = { -1, "page" } }
N.last_scroll = nil -- tests: { lnum, col } of the last model-based move (nil: builtin)

local function view_for(win, A, R)
  local th = api.nvim_win_text_height
  local function hts(l) local x = th(win, { start_row = l, end_row = l }); return x.all - x.fill, x.fill end
  local _, fillA = hts(A)
  if R <= fillA then return { topline = A + 1, topfill = math.max(R, 0) } end
  local base = fillA
  for T = A - 1, 0, -1 do
    local text, fill = hts(T)
    base = base + text
    if base >= R then return { topline = T + 1, topfill = 0 } end
    if base + fill >= R then return { topline = T + 1, topfill = R - base } end
    base = base + fill
  end
  return { topline = 1, topfill = 0 }
end

function N.scroll(lhs, count)
  local win = api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  local dir, kind = SCROLL[lhs][1], SCROLL[lhs][2]
  local function builtin()
    N.last_scroll = nil
    api.nvim_feedkeys(api.nvim_replace_termcodes((count > 0 and count or "") .. lhs, true, false, true), "ni", false)
  end
  local model = core.model(win)
  if not model then return builtin() end
  local h = api.nvim_win_get_height(win)
  local amount
  if kind == "half" then
    if count > 0 then vim.wo[win].scroll = count end
    amount = vim.wo[win].scroll > 0 and vim.wo[win].scroll or math.floor(h / 2)
  else
    amount = math.max(h - 2, 1) * math.max(count, 1)
  end
  local nlines = api.nvim_buf_line_count(buf)
  local info = vim.fn.getwininfo(win)[1]
  local W = math.max(info.width - info.textoff, 1)
  local th = api.nvim_win_text_height
  local function rows(l) return math.max(th(win, { start_row = l, end_row = l, start_vcol = 0 }).all, 1) end
  local starts, ends = {}, {}
  for _, e in ipairs(model.tables) do starts[e.tbl.start_row], ends[e.tbl.end_row - 1] = e, e end
  local cur = api.nvim_win_get_cursor(win)
  local lnum, col = cur[1] - 1, cur[2]
  local wl = vim.fn.winline()
  -- start position: { e, gi } in a table grid or { l, s } on a buffer line
  local pos, k, vcol, sc = nil, 1, 0, 0
  local e0, r0 = table_at(model, lnum)
  if e0 then
    local g = core.grid(e0)
    local row = e0.tbl.rows[r0]
    local li = 1
    if row.kind ~= "delim" and model.cursor and model.cursor.lnum == lnum then
      local P = positions(model, row, r0, col)
      local here = P[1]
      for _, p in ipairs(P) do if p.b <= col then here = p end end
      if here then li, vcol = here.r, here.col end
      k = project.cell_at(row, col)
      local w = want[win]
      if w and w.lnum == lnum and w.col == col then vcol = w.vcol end
    elseif row.kind ~= "delim" then
      -- drawn raw (taller than the window): the layout chunk holding the cursor
      k = project.cell_at(row, col)
      local lc = e0.lay.rows[r0] and e0.lay.rows[r0].cells[k]
      local n = 0
      for _, ch in ipairs(lc and lc.chunks or {}) do
        if not ch.fill then n = n + 1; if col >= ch.s then li = n end end
      end
    end
    pos = { e = e0, gi = (g.first[r0] or 1) + li - 1 }
  else
    local vc = vim.fn.virtcol(".") - 1
    pos = { l = lnum, s = math.floor(vc / W) }
    sc = vc % W
  end
  local touched = pos.e ~= nil
  -- one rendered screen line in direction dir, or nil at the buffer edge
  local function step(p)
    if p.e then
      local g, t = core.grid(p.e), p.e.tbl
      local gi = p.gi + dir
      if gi >= 1 and gi <= #g.lines then return { e = p.e, gi = gi } end
      local l = dir == 1 and t.end_row or t.start_row - 1
      if l < 0 or l >= nlines then return nil end
      return { l = l, s = dir == 1 and 0 or rows(l) - 1 }
    end
    local s = p.s + dir
    if s >= 0 and s < rows(p.l) then return { l = p.l, s = s } end
    local l = p.l + dir
    if l < 0 or l >= nlines then return nil end
    local e = dir == 1 and starts[l] or ends[l]
    if e then touched = true; return { e = e, gi = dir == 1 and 1 or #core.grid(e).lines } end
    return { l = l, s = dir == 1 and 0 or rows(l) - 1 }
  end
  -- grid line gi of entry e -> table row index x and its grid line li
  local function row_at(e, gi)
    local g = core.grid(e)
    for x, rw in ipairs(e.tbl.rows) do
      if rw.kind ~= "delim" and g.first[x] and gi >= g.first[x] and gi < g.first[x] + g.count[x] then return x, gi - g.first[x] + 1 end
    end
  end
  -- a grid line the cursor can be on: a line of cell k in its row (not a
  -- border, separator, the delimiter or a line below a shorter cell)
  local function cursor_line(p)
    local x, li = row_at(p.e, p.gi)
    if not x then return false end
    local rw = p.e.tbl.rows[x]
    return #rw.cells == 0 or li <= cell_lines(p.e, x, math.max(math.min(k, #rw.cells), 1))
  end
  for _ = 1, amount do
    local nx = step(pos)
    if not nx then break end
    pos = nx
  end
  while pos.e and not cursor_line(pos) do -- go on in the direction of the move
    local nx = step(pos)
    if not nx then
      -- the buffer edge right after the grid: back to the nearest cursor line
      local g = core.grid(pos.e)
      repeat pos = { e = pos.e, gi = pos.gi - dir } until pos.gi < 1 or pos.gi > #g.lines or cursor_line(pos)
      break
    end
    pos = nx
  end
  if not touched then return builtin() end
  local tl, tc, off
  if pos.e and pos.gi >= 1 and row_at(pos.e, pos.gi) then
    local x, li = row_at(pos.e, pos.gi)
    local rw = pos.e.tbl.rows[x]
    local kk = math.max(math.min(k, #rw.cells), 1)
    tl = pos.e.tbl.start_row + x - 1
    tc = #rw.cells > 0 and col_at(pos.e, x, kk, vcol, li, false) or 0
    off = li - 1
  else
    if pos.e then pos = { l = lnum, s = 0 } end
    tl, tc, off = pos.l, line_col(win, pos.l, pos.s, sc), pos.s
  end
  N.last_scroll = { tl + 1, tc }
  core.goto(win, tl, tc)
  -- keep the cursor's screen row: rows above its line's text = row - 1 -
  -- its row inside the line (the projection's spill and grid line)
  local m2 = core._last_model(win)
  if m2 and m2.cursor and m2.cursor.lnum == tl then off = (m2.cursor.proj.spill_above or 0) + off end
  if m2 and m2.tall and m2.tall.lnum == tl then off = math.floor((vim.fn.virtcol(".") - 1) / W) end
  local v = view_for(win, tl, wl - 1 - off)
  api.nvim_win_call(win, function() vim.fn.winrestview({ topline = v.topline, topfill = v.topfill, skipcol = 0 }) end)
  core.resettle(win)
  if pos.e then want[win] = { lnum = tl, col = tc, vcol = vcol } else want[win] = nil end
end

local function nav_expr(buf, i)
  local key, count = KEYS[i], vim.v.count
  local m = short_mode()
  if core.attached(buf) then
    local win = api.nvim_get_current_win()
    local model = core._last_model(win)
    -- inside a table, or the model is stale: decide in N.run after a render
    -- (none can happen here, expr maps run under textlock)
    if not model or model.tick ~= api.nvim_buf_get_changedtick(buf) or table_at(model, api.nvim_win_get_cursor(win)[1] - 1) then
      return ("<Cmd>lua require('custom.mdtable.nav').run(%d, %d)<CR>"):format(i, count)
    end
    local k = fallback(model, key, m, count)
    if k == "STEP" then return ("<Cmd>lua require('custom.mdtable.nav').run(%d, 0)<CR>"):format(i) end
    return k
  end
  local k = fallback(nil, key, m, count)
  return k == "STEP" and key.act or k
end

-- Landing intents for jumps whose target is known before they run (see the
-- landing correction in init.lua). Expr maps: they return the key unchanged.
local LAND = {
  { "G", function(c) return { kind = "line", lnum = c > 0 and c - 1 or math.huge } end },
  { "gg", function(c) return { kind = "line", lnum = c > 0 and c - 1 or 0 } end },
  { "n", function() return { kind = "search", pattern = vim.fn.getreg("/"), backward = vim.v.searchforward == 0 } end },
  { "N", function() return { kind = "search", pattern = vim.fn.getreg("/"), backward = vim.v.searchforward == 1 } end },
}
local LDESC = "mdtable: landing correction"
local EDESC = "mdtable: cell editor on a row drawn raw"

-- i/a/I/A on a row drawn raw (taller than the window, init.lua) open the
-- floating cell editor at the cursor's cell instead of inserting in the
-- line (vim.g.mdtable_cell_editor = false: the builtin keys).
local function edit_expr(buf, lhs)
  if vim.g.mdtable_cell_editor == false or not core.attached(buf) then return lhs end
  local win = api.nvim_get_current_win()
  local model = core._last_model(win)
  local lnum = api.nvim_win_get_cursor(win)[1] - 1
  if not (model and model.tick == api.nvim_buf_get_changedtick(buf) and model.tall and model.tall.lnum == lnum
      and not model.tall.anchor) then
    return lhs
  end
  return ("<Cmd>lua require('custom.mdtable.celledit').open_at_cursor({ insert = %q, at_cursor = true })<CR>"):format(lhs)
end

function N.map(buf)
  for _, lhs in ipairs({ "i", "a", "I", "A" }) do
    vim.keymap.set("n", lhs, function() return edit_expr(buf, lhs) end, { buffer = buf, expr = true, desc = EDESC })
  end
  for _, l in ipairs(LAND) do
    vim.keymap.set({ "n", "x" }, l[1], function() -- noremap: the returned key is the builtin
      local it = l[2](vim.v.count)
      if it.kind == "search" then
        if it.pattern == "" then return l[1] end
        local c = api.nvim_win_get_cursor(0)
        it.origin = { c[1] - 1, c[2] }
      end
      core.set_intent(0, it)
      -- pre-render with the target as cursor row, then run the jump
      local c = vim.v.count
      return "<Cmd>lua require('custom.mdtable').prerender(0)<CR>" .. (c > 0 and c or "") .. l[1]
    end, { buffer = buf, expr = true, desc = LDESC })
  end
  if vim.g.mdtable_table_motions == false then return end
  for lhs in pairs(SCROLL) do
    vim.keymap.set({ "n", "x" }, lhs, function() N.scroll(lhs, vim.v.count) end, { buffer = buf, desc = DESC })
  end
  for i, key in ipairs(KEYS) do
    vim.keymap.set(key.modes, key.lhs, function() return nav_expr(buf, i) end,
      { buffer = buf, expr = true, desc = DESC })
  end
end

function N.unmap(buf)
  for _, m in ipairs({ "n", "x", "i" }) do
    for _, d in ipairs(api.nvim_buf_get_keymap(buf, m)) do
      if d.desc == DESC or d.desc == LDESC or d.desc == EDESC then pcall(vim.keymap.del, m, d.lhs, { buffer = buf }) end
    end
  end
end

return N
