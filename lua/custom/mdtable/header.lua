-- custom.mdtable.header: sticky table header (one float per editor window).
--
-- While the cursor is in a body row of a table and the table's header block
-- (top border, header grid lines, delimiter) is not fully visible, a float
-- pinned at row 0 of the window shows that block. Its lines are the
-- grid lines the body uses (project.grid of the same layout), so every bar
-- of the pinned header sits at the body rows' columns.
--
-- The float and scroll-to-fit follow one viewport plan (init.lua plan()):
-- H.rule decides, independent of the view, whether the float may show for
-- the cursor row: only when the row's grid fits in the window below the
-- float (and the rows above that grid can fill the float's rows). Then
-- scroll-to-fit keeps the float's rows free; else no float and fit()
-- reserves nothing (the row needs the whole window). H.scroll_view is the
-- float's part of the plan's target view; H.sync only shows or hides.
--
-- Visibility (sync), from the anchor line A (= the cursor line) and the view:
--   pre        screen rows above A's text (A's filler included)
--   header_top pre - fill(A): screen row of the above block's first line;
--              the header is that block's first lines unless the block was
--              clipped (then it is not drawn at all)
--   shown      when the rule allows it and the real header is not fully
--              visible: header_top < 0 (scrolled off) or the block is
--              clipped. The float may cover prose above the table.
-- Clipped block, its `… N more rows …` marker on screen (header_top >= 0):
-- the float is the header plus a marker recounted for the rows it hides
-- (with_marker), n + 1 lines covering rows 0..n. With the real marker below
-- row n, the plan's view scrolls down so it lands at row n under the
-- float's marker (the table reads as one grid); a plain scroll does not, and
-- the float is the header alone above the prose and the real marker.
-- The cursor line is never under the float: the plan's view puts A's text
-- below it; on a plain scroll (WinScrolled) the float hides instead, so
-- <C-e> is not fought.
-- The float spans the whole window (col 0) with a blank textoff-wide prefix,
-- so the number and sign columns of the lines it covers are hidden too.
-- Hidden when the window is shorter than the block + 3 lines, the buffer is
-- not rendered, or sticky headers are off (vim.g/vim.b.mdtable_sticky_header).
local api = vim.api
local H = {}

local floats = {} -- parent win -> { win, buf, src, key, cfg, dkey }
H._floats = floats
H.counters = { opens = 0, writes = 0, configs = 0 } -- tests: float churn
local ns = api.nvim_create_namespace("mdtable.header")
local th = api.nvim_win_text_height

function H.enabled(buf)
  local v = vim.b[buf].mdtable_sticky_header
  if v == nil then v = vim.g.mdtable_sticky_header ~= false end
  return v and true or false
end

-- The header block of a grid: lines 1 .. delimiter (memoized on the grid).
function H.lines(g, tbl)
  local b = g.header
  if b then return b end
  local d
  for r, row in ipairs(tbl.rows) do
    if row.kind == "delim" then d = r; break end
  end
  b = {}
  if d and g.first[d] then
    for i = 1, g.first[d] do b[i] = g.lines[i] end
  end
  g.header = b
  return b
end

-- Height of the float for this cursor table (0: never shown in win).
function H.height(buf, ctx, h)
  if not ctx or not H.enabled(buf) then return 0 end
  local n = #H.lines(ctx.g, ctx.tbl)
  if n == 0 or h < n + 3 then return 0 end
  return n
end

-- The float's half of the viewport plan, the same for every view of this
-- cursor row: { show_header, float_height }. float_height: the header block
-- (n lines), + 1 for the clip marker it carries when the block above the
-- row is clipped; 0 when no float. show_header: the row's grid (cr.height:
-- its separator, screen rows incl. spill, own lines; a ragged row: its text
-- rows) fits in the window below the float, and the rows above that grid
-- (the block drawn above the row, prose and other tables before it) can
-- fill the float's rows. scroll-to-fit reserves float_height rows.
function H.rule(win, buf, ctx, cr, h)
  local n = H.height(buf, ctx, h)
  if n == 0 then return { show_header = false, float_height = 0 } end
  local nf = ctx.clipped and n + 1 or n
  local A = ctx.A
  local height = cr and cr.height or th(win, { start_row = A, end_row = A, start_vcol = 0 }).all
  if height + nf > h then return { show_header = false, float_height = 0 } end
  local room = #ctx.above - (cr and cr.sep_above or 0)
  if room < nf and A > 0 then
    room = room + th(win, { start_row = 0, end_row = A - 1, max_height = nf - room }).all
  end
  if room < nf then return { show_header = false, float_height = 0 } end
  return { show_header = true, float_height = nf }
end

function H.close(win)
  local f = floats[win]
  if not f then return end
  floats[win] = nil
  if api.nvim_win_is_valid(f.win) then pcall(api.nvim_win_close, f.win, true) end
  if api.nvim_buf_is_valid(f.buf) then pcall(api.nvim_buf_delete, f.buf, { force = true }) end
end

function H.close_buf(buf)
  for w, f in pairs(floats) do
    if f.src == buf then H.close(w) end
  end
end

-- Floats whose parent closed or shows another buffer.
function H.prune()
  if next(floats) == nil then return end
  for w, f in pairs(floats) do
    if not api.nvim_win_is_valid(w) or not api.nvim_win_is_valid(f.win) or api.nvim_win_get_buf(w) ~= f.src then
      H.close(w)
    end
  end
end

local function show(win, src, lines, key)
  local info = vim.fn.getwininfo(win)[1]
  if not info then return end
  local pad, width = info.textoff, info.width
  local f = floats[win]
  if f and not (api.nvim_win_is_valid(f.win) and api.nvim_buf_is_valid(f.buf)) then H.close(win); f = nil end
  local ckey = pad .. ":" .. width .. ":" .. #lines
  local cfg = { relative = "win", win = win, row = 0, col = 0, width = width, height = #lines, focusable = false,
    style = "minimal", zindex = 40 }
  if not f then
    local b = api.nvim_create_buf(false, true)
    vim.bo[b].bufhidden = "wipe"
    cfg.noautocmd = true
    local fw = api.nvim_open_win(b, false, cfg)
    H.counters.opens = H.counters.opens + 1
    vim.wo[fw].winhighlight = "NormalFloat:Normal"
    vim.wo[fw].wrap = false
    f = { win = fw, buf = b, src = src, ckey = ckey }
    floats[win] = f
  elseif f.ckey ~= ckey then
    api.nvim_win_set_config(f.win, cfg)
    f.ckey = ckey
    H.counters.configs = H.counters.configs + 1
  end
  key = key .. "|" .. pad
  if f.key ~= key then
    f.key = key
    H.counters.writes = H.counters.writes + 1
    local text, marks = {}, {}
    for i, chunks in ipairs(lines) do
      local parts, c = { string.rep(" ", pad) }, pad
      for _, ch in ipairs(chunks) do
        local s = ch[1]
        parts[#parts + 1] = s
        if ch[2] and #s > 0 then marks[#marks + 1] = { i - 1, c, c + #s, ch[2] } end
        c = c + #s
      end
      text[i] = table.concat(parts)
    end
    -- bounded clear: the float buffer holds only these few lines
    api.nvim_buf_clear_namespace(f.buf, ns, 0, api.nvim_buf_line_count(f.buf))
    api.nvim_buf_set_lines(f.buf, 0, -1, false, text)
    for _, m in ipairs(marks) do
      api.nvim_buf_set_extmark(f.buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
    end
  end
end

-- grid line object -> row index, for each header/body row's first line
local function first_map(g, tbl)
  local m = g.header_first
  if m then return m end
  m = {}
  for r, row in ipairs(tbl.rows) do
    if row.kind ~= "delim" and g.first[r] then m[g.lines[g.first[r]]] = r end
  end
  g.header_first = m
  return m
end

-- Float lines for a clipped block whose marker the float covers (block top
-- at screen row ht, 0 <= ht <= n): the header block plus a marker
-- `… K more rows …` as the last line, K = body rows above the cursor row
-- whose first line is not on screen below the float (the header is in the
-- float). Memoized on the grid per K.
local function with_marker(ctx, n, ht)
  local g, tbl, block = ctx.g, ctx.tbl, ctx.above
  local fm = first_map(g, tbl)
  local before = 0
  for r = 1, ctx.r - 1 do
    if tbl.rows[r].kind ~= "delim" then before = before + 1 end
  end
  local vis = 0
  for i = n + 1 - ht + 1, #block do -- block line i is at screen row ht + i - 1
    if fm[block[i]] then vis = vis + 1 end
  end
  local k = before - 1 - vis -- the header is on screen, in the float
  g.header_m = g.header_m or {}
  local m = g.header_m[k]
  if not m then
    m = {}
    for i, l in ipairs(H.lines(g, tbl)) do m[i] = l end
    -- k = 0: the clip hid only the header; a blank grid line covers its marker
    m[#m + 1] = k > 0 and require("custom.mdtable.project").marker(g, tbl, k) or g.blank
    g.header_m[k] = m
  end
  return m
end

local function vkey(view, h, ctx)
  return view.topline .. ":" .. view.topfill .. ":" .. view.skipcol .. ":" .. h .. ":" .. tostring(ctx.g) .. ":" .. ctx.A
    .. ":" .. tostring(ctx.above)
end

-- Screen rows above A's text in view v ({ topline, topfill }), A's filler
-- (fill) included.
local function pre_of(win, A, fill, h, v)
  local t, tf = v.topline - 1, v.topfill
  if A == t then return math.min(tf, fill) end
  return tf + th(win, { start_row = t, end_row = A - 1, start_vcol = 0, max_height = h }).all + fill
end

-- Lines of the float when A's text starts at screen row pre, or nil (the
-- real header is on screen).
local function decide(ctx, n, fill, pre)
  local ht = pre - fill
  if ht >= 0 and not ctx.clipped then return nil end
  if ht >= 0 and ht <= n then return with_marker(ctx, n, ht) end
  return H.lines(ctx.g, ctx.tbl)
end

-- The float's part of the plan's target view (render paths, show_header
-- only): from view v, the view that seats the float. A clipped block whose
-- real marker is below row n: scroll down until it is at row n (header_top
-- = topfill(l) + rows l..A-1 for topline l before the table), else to A
-- itself. Cursor line under the float with A at the window top: show more
-- of A's filler. Pure: returns a view, does not apply it.
function H.scroll_view(win, ctx, h, v)
  local n = H.height(api.nvim_win_get_buf(win), ctx, h)
  local A = ctx.A
  if n == 0 or A < v.topline - 1 or (v.skipcol or 0) > 0 then return v end
  local fill = th(win, { start_row = A, end_row = A }).fill
  local pre = pre_of(win, A, fill, h, v)
  if ctx.clipped and pre - fill > n then
    local nv
    for l = v.topline - 1, ctx.tbl.start_row - 1 do
      local R = th(win, { start_row = l, end_row = A - 1, start_vcol = 0, max_height = h }).all
      if R <= n then
        local fl = th(win, { start_row = l, end_row = l }).fill
        nv = { topline = l + 1, topfill = math.min(fl, n - R) }
        break
      end
    end
    v = nv or { topline = A + 1, topfill = fill }
    pre = pre_of(win, A, fill, h, v)
  end
  local lines = decide(ctx, n, fill, pre)
  if lines and pre < #lines and A == v.topline - 1 and fill >= #lines then
    v = { topline = A + 1, topfill = #lines }
  end
  return v
end

-- Show, update or hide the float of win for the current view; never
-- scrolls. ctx = { g, tbl, A, r, above, clipped } for the cursor's table
-- (cursor in body row r on line A; above: the block drawn above A, clipped:
-- it starts with a clip marker), or nil. view: winsaveview() of win (nil:
-- read it). p: the viewport plan (no float unless p.show_header).
function H.sync(win, ctx, h, view, p)
  if not (ctx and p and p.show_header) then H.close(win); return end
  local buf = api.nvim_win_get_buf(win)
  local n = H.height(buf, ctx, h)
  if n == 0 then H.close(win); return end
  view = view or api.nvim_win_call(win, vim.fn.winsaveview)
  local f = floats[win]
  local dkey = vkey(view, h, ctx)
  if f and f.dkey == dkey and api.nvim_win_is_valid(f.win) then return end
  local A = ctx.A
  if A < view.topline - 1 or view.skipcol > 0 then H.close(win); return end
  local fill = th(win, { start_row = A, end_row = A }).fill
  local pre = pre_of(win, A, fill, h, view)
  local lines = decide(ctx, n, fill, pre)
  if lines and pre < #lines then lines = nil end -- the cursor line is never under the float
  if not lines then H.close(win); return end
  show(win, buf, lines, require("custom.mdtable.project").block_sig(lines))
  if floats[win] then floats[win].dkey = dkey end
end

return H
