-- custom.mdtable.nav: cell navigation keys (buffer-local maps in n, x and i),
-- ported from the spike onto the layout/project model.
-- Inside a rendered table: h/l (<Left>/<Right>) move one visible character
-- within the cursor's cell, j/k (<Down>/<Up>) move between the cell's wrapped
-- grid lines at the same visual column; Ctrl-h/Ctrl-l go to the
-- previous/next cell (continuing on the previous/next row), Ctrl-j/Ctrl-k to
-- the same column of the next/previous row; the delimiter row is skipped and
-- every move clamps at the table edges. Plain h/j/k/l are not mapped in
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
  if act == "h" or act == "l" or act == "j" or act == "k" then
    if row.kind == "delim" then return end
    local P, cell = positions(model, row, r, col)
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
    local rr = clamp(here.r + (act == "j" and n or -n), P[1].r, P[#P].r)
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
    ri = clamp(ri + (act == "J" and n or -n), 1, #R)
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

function N.map(buf)
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
  for i, key in ipairs(KEYS) do
    vim.keymap.set(key.modes, key.lhs, function() return nav_expr(buf, i) end,
      { buffer = buf, expr = true, desc = DESC })
  end
end

function N.unmap(buf)
  for _, m in ipairs({ "n", "x", "i" }) do
    for _, d in ipairs(api.nvim_buf_get_keymap(buf, m)) do
      if d.desc == DESC or d.desc == LDESC then pcall(vim.keymap.del, m, d.lhs, { buffer = buf }) end
    end
  end
end

return N
