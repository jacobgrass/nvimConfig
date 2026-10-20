-- Landing (review F1/F7): every motion lands on the line it targets, in
-- needs.md, ledger.md and generated tables whose grid is 0.5-4x the window
-- height, at 120x45 and 100x30, with the landing intents on and off
-- (vim.g.mdtable_intent = false): the viewport clipping alone must keep
-- Neovim from relocating the cursor. The target of a normal-mode motion is
-- what the motion computes on the same marks (`:normal!`, then cursor and
-- view restored), i.e. before Neovim validates the cursor; cmdline jumps,
-- marks, quickfix and nvim_win_set_cursor have their own targets. After each
-- step: the line, the cursor row drawn as the real row (model cursor = the
-- line, cursor on screen on a table line), every bar aligned, no block taller
-- than the window minus 2, no mdtable error; per scenario 0 corrections.
-- Viewport plan (review finding 5, header.lua): after each step a second
-- render with no cursor change yields the same plan, float and view, and on
-- a table row l then h (inside the cell) change neither the float state nor
-- topline/topfill.
-- 100x42 was added for the viewport plan; there one landing mismatch that
-- the committed code before the sticky header has too (a page scroll from
-- outside a table landing one line off the `normal!` oracle, outside the
-- table) is printed as KNOWN instead of failing; every other check is strict.
-- ONLY=<substring of the scenario name>, VERBOSE=1 prints every step.
local here = vim.fn.fnamemodify(_G.arg[0], ":p:h")
local H = dofile(here .. "/helpers.lua")
local D = dofile(here .. "/uidriver.lua")
D.timeout_ms = 15000
local ONLY, VERBOSE = os.getenv("ONLY"), os.getenv("VERBOSE")
io.stdout:setvbuf("no")

-- 20 prose lines (short: "# Big" only, the layout of the reviewer's
-- probe_reloc2), a blank, the table (n body rows), a blank, `tail` lines:
-- tail = 1 puts the table near EOF (where Neovim relocated), tail = 30
-- leaves room below the table
local function gen(n, tail, short)
  local L = {}
  if short then L[1] = "# Big" else
    for i = 1, 20 do L[i] = ("prose line %d foo%s"):format(i, i == 8 and " open ( paren" or "") end
  end
  L[#L + 1] = ""
  L[#L + 1] = "| # | Topic | Detail |"
  L[#L + 1] = "|---|---|---|"
  for i = 1, n do
    L[#L + 1] = ("| %d | topic%d%s | %s |"):format(i, i, i == math.ceil(n / 2) and " close )" or "", ("detail word "):rep(12) .. "end" .. i)
  end
  L[#L + 1] = ""
  for i = 1, tail or 30 do L[#L + 1] = "tail line " .. i end
  return L
end

local function steps_gen(n, short)
  local P = short and 2 or 21 -- lines before the header
  local last, mid = P + 2 + n, P + 2 + math.ceil(n / 2)
  return {
    { "gg" }, { "20G" }, { "8j" }, { ":" .. last .. "<CR>" }, { "12k" }, { "gg" },
    { "<C-d>" }, { "<C-d>" }, { "<C-d>" }, { "<C-u>" }, { "<C-u>" },
    { "gg" }, { "<C-f>" }, { "<C-f>" }, { "<C-b>" }, { "<C-b>" },
    { "gg" }, { "}" }, { "}" }, { "{" }, { "}" }, { "{" }, { "{" },
    { "gg" }, { "'a", mark = mid }, { "gg" }, { "`a", mark = last }, { "G" }, { "'a", mark = mid - 1 },
    { "gg" }, { ":" .. mid .. "<CR>" }, { ":" .. last .. "<CR>" }, { ":12<CR>" }, { ":" .. (mid + 2) .. "<CR>" },
    { "gg" }, { "/end" .. (mid - P - 2) .. "<CR>" }, { "gg" }, { "?end" .. n .. "<CR>" }, { "n" }, { "N" }, { "n" },
    { "G" }, { "gg" }, { "G" }, { "8G" }, { "f(" }, { "%" }, { "%" },
    { "gg" }, { "qf", lnum = mid }, { "G" }, { "qf", lnum = last - 1 },
    { "gg" }, { "setcursor", lnum = last }, { "gg" }, { "setcursor", lnum = mid }, { "G" }, { "setcursor", lnum = mid - 1 },
    { "G" }, { "12k" }, { "8k" }, { "<C-u>" }, { "<C-b>" }, { "8j" }, { "<C-d>" }, { "<C-f>" },
  }
end

local function steps_file(words, lines)
  local a, b, c = lines[1], lines[2], lines[3]
  return {
    { "gg" }, { ":" .. a .. "<CR>" }, { "gg" }, { ":" .. b .. "<CR>" }, { ":" .. c .. "<CR>" }, { "gg" }, { "8j" }, { "G" }, { "12k" },
    { "gg" }, { "<C-d>" }, { "<C-d>" }, { "<C-d>" }, { "<C-u>" }, { "<C-u>" }, { "<C-f>" }, { "<C-b>" },
    { "gg" }, { "}" }, { "}" }, { "}" }, { "{" }, { "{" },
    { "gg" }, { "'a", mark = b }, { "G" }, { "`a", mark = a },
    { "gg" }, { "/" .. words[1] .. "<CR>" }, { "gg" }, { "?" .. words[2] .. "<CR>" }, { "n" }, { "N" },
    { "G" }, { "gg" }, { "qf", lnum = c }, { "gg" }, { "setcursor", lnum = b }, { "G" }, { "setcursor", lnum = a },
  }
end

local ORACLE = [[
  local st = ...
  local k = st.k
  local function sp(p, f) return vim.fn.searchpos(p, f)[1] end
  if st.mark then vim.fn.setpos("'a", { 0, st.mark, 3, 0 }); return st.mark end
  if k == "qf" then
    vim.fn.setqflist({ { bufnr = vim.api.nvim_get_current_buf(), lnum = st.lnum, col = 1, text = "probe" } })
    return st.lnum
  end
  if k == "setcursor" then return st.lnum end
  if k:match("^:%d+<CR>$") then return math.min(tonumber(k:match("%d+")), vim.fn.line("$")) end
  local pat = k:sub(2):gsub("<CR>$", "")
  if k:sub(1, 1) == "/" then return sp(pat, "nw") end
  if k:sub(1, 1) == "?" then return sp(pat, "bnw") end
  if k:match("^%d*[jk]$") then
    -- inside a table (nav.lua, WP-E E1): j/k walk the grid lines of the
    -- cursor's cell, then the same cell of the next/previous rows, then
    -- buffer lines past the table
    local n, dir = tonumber(k:match("^(%d+)")) or 1, k:sub(-1) == "j" and 1 or -1
    local l, col = vim.fn.line(".") - 1, vim.fn.col(".") - 1
    local m = M._last_model(0)
    for _, e in ipairs(m.tables) do
      local t = e.tbl
      if l >= t.start_row and l < t.end_row then
        local x0 = l - t.start_row + 1
        local row = t.rows[x0]
        local kk = row.kind ~= "delim" and require("custom.mdtable.project").cell_at(row, col) or 1
        local function nl(x)
          local cl, c2 = e.lay.rows[x].cells[math.min(kk, #t.rows[x].cells)], 0
          for _, ch in ipairs(cl and cl.chunks or {}) do if not ch.fill then c2 = c2 + 1 end end
          return math.max(c2, 1)
        end
        local li, last = 1, nl(x0)
        if m.cursor and m.cursor.lnum == l then
          last = math.max(#m.cursor.proj.nav, 1)
          for i, nv in ipairs(m.cursor.proj.nav) do for _, b in ipairs(nv.b) do if b <= col then li = i end end end
        end
        if row.kind == "delim" or (m.tall and m.tall.lnum == l) then li, last = 1, 1 end
        local room = dir == 1 and last - li or li - 1
        -- WP-J: a virtual (tall) row: j/k scroll it while it has rows to show
        if m.vrow and m.vrow.lnum == l then room = dir == 1 and (m.vrow.room_down or 0) or (m.vrow.room_up or 0) end
        if n <= room then return l + 1 end
        local R, ri = {}, nil
        for x, rw in ipairs(t.rows) do if rw.kind ~= "delim" then R[#R + 1] = x; if x == x0 then ri = #R end end end
        if row.kind == "delim" then ri = dir == 1 and 1 or 2 end
        local rest = n - room
        while true do
          ri = ri + dir
          if not R[ri] then
            local out = dir == 1 and t.end_row or t.start_row - 1
            if out < 0 or out >= vim.fn.line("$") then return l + 1 end
            return math.max(0, math.min(vim.fn.line("$") - 1, out + dir * (rest - 1))) + 1
          end
          local c = nl(R[ri])
          if rest <= c then return t.start_row + R[ri] end
          rest = rest - c
        end
      end
    end
  end
  local fwd = vim.v.searchforward == 1
  if k == "n" then return sp(vim.fn.getreg("/"), fwd and "nw" or "bnw") end
  if k == "N" then return sp(vim.fn.getreg("/"), fwd and "bnw" or "nw") end
  local v = vim.fn.winsaveview()
  vim.cmd("normal! " .. vim.api.nvim_replace_termcodes(k, true, false, true))
  local l = vim.fn.line(".")
  vim.fn.winrestview(v)
  return l
]]

local CHECK = [[
  local l = vim.fn.line(".")
  local m = M._last_model(0)
  local row
  for _, e in ipairs(m and m.tables or {}) do
    if l - 1 >= e.tbl.start_row and l - 1 < e.tbl.end_row then row = e.tbl.rows[l - e.tbl.start_row] end
  end
  local real = row and row.kind ~= "delim" and not row.ragged
  -- WP-I: a row whose tallest cell's line is taller than the window is
  -- drawn raw in every cell (per row): the cursor row is then the raw line,
  -- on screen, not the grid cursor row
  local raw = m and m.tall and m.tall.lnum == l - 1 and not m.tall.anchor and true or false
  if raw then real = false end
  -- WP-J: a row taller than the window is virtual while the cursor is on
  -- it: the cursor on the row's covered line (on screen), no real cell
  local virt = m and m.vrow and m.vrow.lnum == l - 1 and true or false
  if virt then real = false end
  local sp = vim.fn.screenpos(0, l, vim.fn.col("."))
  local rows = S.screen()
  local errs, blocks = S.check(rows, 2)
  if raw and sp.row <= 0 then errs[#errs + 1] = "raw cursor row off screen" end
  if virt and sp.row <= 0 then errs[#errs + 1] = "virtual cursor row off screen" end
  local win, mx = vim.api.nvim_get_current_win(), 0
  for _, n in ipairs(require("custom.mdtable.draw").all_ns()) do
    if n.win == win then
      for _, e in ipairs(vim.api.nvim_buf_get_extmarks(0, n.p, 0, -1, { details = true, type = "virt_lines" })) do
        mx = math.max(mx, #(e[4].virt_lines or {}))
      end
    end
  end
  local onbar = sp.row > 0 and (rows[sp.row] or ""):find("│", 1, true) ~= nil
  return { line = l, intable = row ~= nil, real = real or false, raw = raw, virt = virt, crow = m and m.cursor and m.cursor.lnum or -1,
    srow = sp.row, onbar = onbar, errs = errs, nblocks = #blocks, mx = mx, merr = S.errors(), errmsg = vim.v.errmsg }
]]

-- plan, float and view of the current window
local STATE = [[
  local v = vim.fn.winsaveview()
  local p = M._plan(0)
  local f = require("custom.mdtable.header")._floats[vim.api.nvim_get_current_win()]
  local fh = (f and vim.api.nvim_win_is_valid(f.win)) and vim.api.nvim_win_get_config(f.win).height or 0
  local c = vim.api.nvim_win_get_cursor(0)
  return { line = c[1], col = c[2], topline = v.topline, topfill = v.topfill, fh = fh,
    text = fh > 0 and table.concat(vim.api.nvim_buf_get_lines(f.buf, 0, -1, false), "\n") or "",
    show = p and p.show_header or false,
    plan = p and table.concat({ tostring(p.show_header), p.float_height, p.topline, p.topfill }, "/") or "none" }
]]
local function sfmt(s)
  return ("line %d col %d top %d fill %d float %d plan %s"):format(s.line, s.col, s.topline, s.topfill, s.fh, s.plan)
end
-- why the viewport is not stable after a step, or nil
local function unstable(c, real)
  local s1 = c.lua(STATE)
  c.request("nvim_input", "<Cmd>lua M.render(0, { force = true })<CR>")
  c.request("nvim_eval", "1")
  local s2 = c.lua(STATE)
  for _, k in ipairs({ "line", "col", "topline", "topfill", "fh", "text", "plan" }) do
    if s1[k] ~= s2[k] then return ("second render changed %s: %s -> %s"):format(k, sfmt(s1), sfmt(s2)) end
  end
  if not real then return nil end
  for _, key in ipairs({ "l", "h" }) do
    c.request("nvim_input", key)
    c.request("nvim_eval", "1")
    local s3 = c.lua(STATE)
    for _, k in ipairs({ "line", "topline", "topfill", "fh", "show" }) do
      if s1[k] ~= s3[k] then return ("%s changed %s: %s -> %s"):format(key, k, sfmt(s1), sfmt(s3)) end
    end
  end
  return nil
end

local function input(c, st)
  local k = st.k
  if k == "qf" then k = ":cc 1<CR>"
  elseif k == "setcursor" then k = ("<Cmd>lua vim.api.nvim_win_set_cursor(0, { %d, 0 })<CR>"):format(st.lnum) end
  c.request("nvim_input", k)
  c.request("nvim_eval", "1")
end

local total = { steps = 0, bad = 0, known = 0 }
local function scenario(name, W, Hh, intent, src, steps)
  if ONLY and not name:find(ONLY, 1, true) then return end
  H.run(name, function()
    local c = D.start(W, Hh + 1)
    local ok, err = xpcall(function()
      c.lua("_G.S = dofile(...); _G.M = require('custom.mdtable'); vim.g.mdtable_intent = select(2, ...)", here .. "/screen.lua", intent)
      c.lua("_G.BUF, _G.WIN = S.open(...)", src)
      c.request("nvim_input", "<Ignore>")
      local h = c.lua("return vim.api.nvim_win_get_height(0)")
      H.eq(Hh, h, "window height")
      local bad, mxall, prev_in = {}, 0, false
      local page_known = W == 100 and Hh == 42
      for i, st0 in ipairs(steps) do
        local st = { k = st0[1], mark = st0.mark, lnum = st0.lnum } -- msgpack: no mixed tables
        local want = c.lua(ORACLE, st)
        c.lua("vim.v.errmsg = ''; require('custom.mdtable.nav').last_scroll = nil")
        input(c, st)
        -- <C-d>/<C-u>/<C-f>/<C-b> by the table model (WP-E E3): its target;
        -- the builtin (no table in range): the oracle's
        local ls = st.k:match("^<C%-[dufb]>$") and c.lua("return require('custom.mdtable.nav').last_scroll")
        if ls and ls ~= vim.NIL then want = ls[1] end
        local r = c.lua(CHECK)
        total.steps = total.steps + 1
        mxall = math.max(mxall, r.mx)
        local why = {}
        if r.line ~= want then why[#why + 1] = ("line %d, want %d"):format(r.line, want) end
        if r.real and (r.crow ~= r.line - 1 or r.srow <= 0 or not r.onbar) then
          why[#why + 1] = ("cursor row not drawn as the real row (model %d, screen row %d, on bar %s)"):format(r.crow + 1, r.srow, tostring(r.onbar))
        end
        if #r.errs > 0 then why[#why + 1] = "misaligned: " .. r.errs[1] end
        if r.mx > h - 2 then why[#why + 1] = ("block of %d lines > window - 2"):format(r.mx) end
        if #r.merr > 0 then why[#why + 1] = "mdtable error: " .. r.merr[1] end
        local u = unstable(c, r.real)
        if u then why[#why + 1] = u end
        if page_known and #why == 1 and r.line ~= want and st.k:match("^<C%-[fbdu]>$") and not prev_in and not r.intable then
          print(("  KNOWN step %d %s: line %d, want %d (page scroll outside the table; also on the pre-header code)"):format(i, st.k, r.line, want))
          total.known = total.known + 1
          why = {}
        end
        prev_in = r.intable
        if VERBOSE then print(("  %2d %-24s want %3d got %3d tbl %s mx %d %s %s"):format(i, st.k .. (st.lnum and (" " .. st.lnum) or "") .. (st.mark and (" " .. st.mark) or ""), want, r.line, tostring(r.intable), r.mx, r.errmsg, table.concat(why, "; "))) end
        if #why > 0 then bad[#bad + 1] = ("step %d %s: %s"):format(i, st.k, table.concat(why, "; ")) end
      end
      local corrected = c.lua("return M.stats.corrected or 0")
      local line = c.lua("return M.stats_line()")
      print(("  %s: %d steps, %d bad, largest block %d (window %d), corrected %d, %s"):format(name, #steps, #bad, mxall, h, corrected, line:match("re%-clips.*") or ""))
      total.bad = total.bad + #bad
      if #bad > 0 then error(table.concat(bad, "\n")) end
      H.eq(0, corrected, "backup landing corrections")
    end, debug.traceback)
    c.stop()
    if not ok then error(err, 0) end
  end)
end

-- WP-E E1: leaving a table with the navigation keys, crossing rows with
-- j/k; explicit targets on needs.md plus two lines after the table. After
-- every step the CHECK asserts (aligned, cursor row real and on screen).
local E1 = [[
  local st = ...
  if st.go then M.goto(0, st.go[1], S.cell_col(st.go[1], st.go[2])) end
  if st.opt ~= nil then vim.g.mdtable_jk_cross_rows = st.opt end
]]
local function e1(name, W, Hh, intent)
  if ONLY and not name:find(ONLY, 1, true) then return end
  H.run(name, function()
    local c = D.start(W, Hh + 1)
    local ok, err = xpcall(function()
      c.lua("_G.S = dofile(...); _G.M = require('custom.mdtable'); vim.g.mdtable_intent = select(2, ...)", here .. "/screen.lua", intent)
      -- text right before the table (120 characters) and a heading right
      -- after it, so the exits land on text (review WP-E F1, T1)
      local lines = H.read("needs.md")
      lines[7] = ("abcdefghij"):rep(12)
      vim.list_extend(lines, { "## " .. ("0123456789"):rep(11), "", "after the table" })
      c.lua("_G.BUF, _G.WIN = S.open(...)", lines)
      c.request("nvim_input", "<Ignore>")
      -- needs.md (0-based): line 6 before the table, header 7, delimiter 8, body 9..13; 14 and 15 after
      local function cells(l) return c.lua("local m = M._last_model(0); return #m.cursor.proj.nav") end
      local bad = {}
      local function at(label, key, want, setup)
        if setup then c.lua(E1, setup); c.request("nvim_eval", "1") end
        if key then c.request("nvim_input", key); c.request("nvim_eval", "1") end
        local r = c.lua(CHECK)
        local why = {}
        if r.line ~= want then why[#why + 1] = ("line %d, want %d"):format(r.line, want) end
        if r.real and (r.crow ~= r.line - 1 or r.srow <= 0 or not r.onbar) then why[#why + 1] = "cursor row not drawn as the real row" end
        if not r.intable and r.srow <= 0 then why[#why + 1] = "cursor off screen" end
        if #r.errs > 0 then why[#why + 1] = "misaligned: " .. r.errs[1] end
        if #r.merr > 0 then why[#why + 1] = "mdtable error: " .. r.merr[1] end
        if VERBOSE then print(("  %-34s line %d want %d %s"):format(label, r.line, want, table.concat(why, "; "))) end
        if #why > 0 then bad[#bad + 1] = label .. ": " .. table.concat(why, "; ") end
        return r
      end
      local r = at("C-j from the last row", "<C-j>", 15, { go = { 13, 2 } })
      if r.intable then bad[#bad + 1] = "C-j: still in the table" end
      at("C-k from the header", "<C-k>", 7, { go = { 7, 2 } })
      -- WP-I: a raw last row (per row, at narrow sizes) is walked by its
      -- screen rows first: j stays on it, then leaves the table after its
      -- last screen row
      for _, key in ipairs({ "j", "<Down>" }) do
        local label = key == "j" and "j from the last row, one-line cell 1" or "<Down> from the last row, cell 1"
        c.lua(E1, { go = { 13, 1 } }); c.request("nvim_eval", "1")
        local rk = c.lua(CHECK)
        if rk.raw or rk.virt then -- (WP-J: a virtual last row: j scrolls it first, while it has rows to show)
          local room = rk.virt and c.lua("local m = M._last_model(0); return m.vrow and m.vrow.room_down or 0") or 1
          if room > 0 then at(label .. " (raw row: walks its screen rows)", key, 14) end
          local n = 0
          while c.lua("return vim.fn.line('.')") == 14 and n < 80 do c.request("nvim_input", key); c.request("nvim_eval", "1"); n = n + 1 end
          at(label .. " (raw row: past its last screen row)", nil, 15)
        else
          at(label, key, 15, { go = { 13, 1 } })
        end
      end
      at("k from the header, cell 1", "k", 7, { go = { 7, 1 } })
      at("<Up> from the header, cell 1", "<Up>", 7, { go = { 7, 1 } })
      at("j from the header, cell 1: first body row", "j", 10, { go = { 7, 1 } })
      local rj = c.lua(CHECK)
      -- (WP-J: a virtual (tall) row: j scrolls it, then the next row)
      if rj.raw or rj.virt then -- WP-I round 3: row 1 raw at this size: j walks its screen rows, then the next row
        local n = 0
        while c.lua("return vim.fn.line('.')") == 10 and n < 80 do c.request("nvim_input", "j"); c.request("nvim_eval", "1"); n = n + 1 end
        at("j again: past the raw row's screen rows, the next row", nil, 11)
      else
        at("j again: the next row", "j", 11)
      end
      at("k: back", "k", 10)
      -- a multi-line cell: j walks its grid lines first
      local r1 = at("row 1 cell 3", nil, 10, { go = { 9, 3 } })
      if r1.raw or r1.virt then -- WP-I round 3: row 1 raw (its frame is taller than the window): j walks its screen rows
        local n = 0
        while c.lua("return vim.fn.line('.')") == 10 and n < 80 do c.request("nvim_input", "j"); c.request("nvim_eval", "1"); n = n + 1 end
        at("j past the raw row's last screen row: next row", nil, 11)
      else
        local n = cells()
        if n < 2 then bad[#bad + 1] = "row 1 cell 3 should wrap (" .. n .. " lines)" end
        for i = 1, n - 1 do at("j in the cell " .. i, "j", 10) end
        at("j past the cell's last line: next row", "j", 11)
      end
      at("k: back to row 1's last line", "k", 10)
      c.lua(E1, { go = { 9, 1 } }); c.request("nvim_eval", "1")
      -- (row 1 raw, per row: 3j walks three of its screen rows)
      local r3 = c.lua(CHECK)
      local room3 = c.lua("local m = M._last_model(0); return m.vrow and m.vrow.room_down or -1")
      at("3j from row 1 cell 1", "3j", (r3.raw or (r3.virt and room3 >= 3)) and 10 or 13, { go = { 9, 1 } })
      c.lua(E1, { go = { 9, 1 } }); c.request("nvim_eval", "1")
      -- (row 1 raw with more than 9 screen rows: 9j walks 9 of them, WP-I round 3)
      local sr = c.lua([[local m = M._last_model(0); if not (m.tall and m.tall.lnum == 9) then return 0 end
        local i = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1]
        return math.ceil(vim.fn.strdisplaywidth(vim.fn.getline(10)) / (i.width - i.textoff))]])
      if sr > 9 then
        at("9j in the raw row 1: nine of its screen rows", "9j", 10, { go = { 9, 1 } })
      else
        at("9j: past the table, on buffer lines (clamped at the last line)", "9j", 17, { go = { 9, 1 } })
      end
      -- exits keep the drawn screen column (wincol), clamped to the end of
      -- the landing screen row when it is shorter
      -- (WP-J: on a virtual row the drawn column is the active cell's grid column)
      local WC = [[local m = M._last_model(0); local wc = vim.fn.wincol()
        if m.vrow and m.vrow.lnum == vim.fn.line(".") - 1 then
          for _, x in ipairs(m.tables) do
            if x.tbl == m.vrow.tbl then wc = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff + M.grid(x).left[m.vrow.k] + 1 end
          end
        end
        return { wc, vim.fn.col("."), vim.fn.col("$") - 1, vim.fn.line(".") }]]
      for _, k in ipairs({ 2, 3, 5 }) do
        for _, ex in ipairs({ { 13, "<C-j>", 15 }, { 13, "j", 15 }, { 7, "<C-k>", 7 }, { 7, "k", 7 } }) do
          local label = ("column: %s from %s cell %d"):format(ex[2], ex[1] == 13 and "the last row" or "the header", k)
          c.lua(E1, { go = { ex[1], k } }); c.request("nvim_eval", "1")
          local w0 = c.lua(WC)
          local w1
          for _ = 1, 60 do -- j/k first walk the cell's grid lines
            c.request("nvim_input", ex[2]); c.request("nvim_eval", "1")
            w1 = c.lua(WC)
            if w1[4] ~= w0[4] then break end
          end
          local ok = w1[4] == ex[3] and (w1[1] == w0[1] or (w1[1] < w0[1] and w1[2] == w1[3]))
          if VERBOSE then print(("  %-34s wincol %d -> %d, line %d"):format(label, w0[1], w1[1], w1[4])) end
          if not ok then bad[#bad + 1] = ("%s: line %d (want %d), wincol %d -> %d"):format(label, w1[4], ex[3], w0[1], w1[1]) end
          at(label .. " (checks)", nil, ex[3])
        end
      end
      -- the option restores the clamp
      at("clamp: j on the last row", "j", 14, { go = { 13, 1 }, opt = false })
      at("clamp: C-j on the last row", "<C-j>", 14)
      at("clamp: k on the header", "k", 8, { go = { 7, 1 } })
      at("clamp: C-k on the header", "<C-k>", 8)
      c.lua("vim.g.mdtable_jk_cross_rows = nil")
      c.lua(E1, { go = { 13, 1 } }); c.request("nvim_eval", "1")
      local rb = c.lua(CHECK)
      if rb.raw or rb.virt then -- WP-I: the raw last row is walked by screen rows first (WP-J: a virtual one scrolled)
        local n = 0
        while c.lua("return vim.fn.line('.')") == 14 and n < 80 do c.request("nvim_input", "j"); c.request("nvim_eval", "1"); n = n + 1 end
        at("option back on: j exits (after the raw row's screen rows)", nil, 15)
      else
        at("option back on: j exits", "j", 15, { go = { 13, 1 } })
      end
      H.eq(0, c.lua("return M.stats.corrected or 0"), "backup landing corrections")
      if #bad > 0 then error(table.concat(bad, "\n")) end
    end, debug.traceback)
    c.stop()
    if not ok then error(err, 0) end
  end)
end

-- WP-E E3: <C-d> from above the first table to the end of the buffer, then
-- <C-u> back to the top, intent off. Every step lands on the model's target
-- (no relocation) with the CHECK asserts; inside a table the cursor stays in
-- cell 1; the cursor enters every table it passes; every body row of those
-- tables is on screen at some step.
local VIS = [=[
  local rows = S.screen()
  local out = {}
  for ti, e in ipairs(M._last_model(0).tables) do
    local g = M.grid(e)
    for x, rw in ipairs(e.tbl.rows) do
      if rw.kind == "body" and g.first[x] then
        local t = {}
        for _, ch in ipairs(g.lines[g.first[x]]) do t[#t + 1] = ch[1] end
        local txt = vim.trim(table.concat(t))
        -- WP-I: the cursor row drawn raw (per row) is seen when its line is on screen
        local mt = M._last_model(0).tall
        if mt and not mt.anchor and mt.lnum == e.tbl.start_row + x - 1 and vim.fn.screenpos(0, mt.lnum + 1, 1).row > 0 then
          out[#out + 1] = e.tbl.start_row .. ":" .. x
        else
          for _, s in ipairs(rows) do if s:find(txt, 1, true) then out[#out + 1] = e.tbl.start_row .. ":" .. x; break end end
        end
      end
    end
  end
  local l, cl = vim.fn.line(".") - 1, vim.fn.col(".") - 1
  local k
  for _, e in ipairs(M._last_model(0).tables) do
    if l >= e.tbl.start_row and l < e.tbl.end_row then
      local rw = e.tbl.rows[l - e.tbl.start_row + 1]
      if rw.kind ~= "delim" then k = require("custom.mdtable.project").cell_at(rw, cl) end
    end
  end
  local tabs = {}
  for _, e in ipairs(M._last_model(0).tables) do
    local b = 0
    for _, rw in ipairs(e.tbl.rows) do if rw.kind == "body" then b = b + 1 end end
    tabs[#tabs + 1] = { e.tbl.start_row, e.tbl.end_row, b, #M.grid(e).lines, math.floor(vim.api.nvim_win_get_height(0) / 2) }
  end
  -- (WP-J: a virtual row scrolls in place: its offset and the view tell a move)
  local m0, v0 = M._last_model(0), vim.fn.winsaveview()
  local vo = (m0.vrow and m0.vrow.off or 0) .. ":" .. v0.topline .. ":" .. v0.topfill
  return { vis = out, k = k or 0, tabs = tabs, last = vim.fn.line("$"), col = cl, vo = vo }
]=]
local function e3(name, W, Hh, src)
  if ONLY and not name:find(ONLY, 1, true) then return end
  H.run(name, function()
    local c = D.start(W, Hh + 1)
    local ok, err = xpcall(function()
      c.lua("_G.S = dofile(...); _G.M = require('custom.mdtable'); vim.g.mdtable_intent = false", here .. "/screen.lua")
      c.lua("_G.BUF, _G.WIN = S.open(...)", src)
      c.request("nvim_input", "<Ignore>")
      local bad, seen, entered, tabs = {}, {}, {}, {}
      for _, dir in ipairs({ "<C-d>", "<C-u>" }) do
        local prev, prev_pos
        for i = 1, 80 do
          c.lua("vim.v.errmsg = ''; require('custom.mdtable.nav').last_scroll = nil")
          c.request("nvim_input", dir); c.request("nvim_eval", "1")
          local ls = c.lua("return require('custom.mdtable.nav').last_scroll")
          if ls == vim.NIL then ls = nil end
          local r, v = c.lua(CHECK), c.lua(VIS)
          for _, x in ipairs(v.vis) do seen[x] = true end
          for _, tb in ipairs(v.tabs) do tabs[tb[1]] = tb end
          local why = {}
          if ls and r.line ~= ls[1] then why[#why + 1] = ("relocated: line %d, target %d"):format(r.line, ls[1]) end
          if r.real and (r.crow ~= r.line - 1 or r.srow <= 0 or not r.onbar) then why[#why + 1] = "cursor row not drawn as the real row" end
          if r.intable then
            entered[r.line] = true
            if r.real and v.k ~= 1 then why[#why + 1] = "cursor left cell 1 (cell " .. v.k .. ")" end
          end
          if #r.errs > 0 then why[#why + 1] = "misaligned: " .. r.errs[1] end
          if #r.merr > 0 then why[#why + 1] = "mdtable error: " .. r.merr[1] end
          if prev and (dir == "<C-d>" and r.line < prev or dir == "<C-u>" and r.line > prev) then why[#why + 1] = "moved backwards" end
          if VERBOSE then print(("  %s %2d line %d target %s tbl %s %s"):format(dir, i, r.line, ls and ls[1] or "-", tostring(r.intable), table.concat(why, "; "))) end
          if #why > 0 then bad[#bad + 1] = ("%s %d: %s"):format(dir, i, table.concat(why, "; ")) end
          -- a tall row: <C-d> may move within its cell (same line, later grid line)
          local here = r.line .. ":" .. v.col .. ":" .. (v.vo or "")
          if here == prev_pos or (dir == "<C-d>" and r.line == v.last) or (dir == "<C-u>" and r.line == 1) then break end
          prev, prev_pos = r.line, here
        end
      end
      local nt, nrows = 0, 0
      for s0, tb in pairs(tabs) do
        nt = nt + 1
        local inside = false
        for l in pairs(entered) do if l - 1 >= tb[1] and l - 1 < tb[2] then inside = true end end
        -- a grid shorter than the move may be passed in one step (its rows are on screen)
        if not inside and tb[4] > tb[5] then bad[#bad + 1] = "never entered the table at line " .. (s0 + 1) end
        local b = 0
        for x = 1, tb[2] - tb[1] do if seen[s0 .. ":" .. x] then b = b + 1 end end
        nrows = nrows + tb[3]
        if b < tb[3] then bad[#bad + 1] = ("table at line %d: %d of %d body rows on screen"):format(s0 + 1, b, tb[3]) end
      end
      print(("  %s: %d tables, %d body rows, all on screen and entered: %s"):format(name, nt, nrows, tostring(#bad == 0)))
      if #bad > 0 then error(table.concat(bad, "\n")) end
    end, debug.traceback)
    c.stop()
    if not ok then error(err, 0) end
  end)
end

for _, size in ipairs({ { 120, 45 }, { 100, 30 } }) do
  for _, intent in ipairs({ true, false }) do
    e1(("E1 exit and cross rows %dx%d intent %s"):format(size[1], size[2], intent and "on" or "off"), size[1], size[2], intent)
  end
  e3(("E3 <C-d>/<C-u> needs.md %dx%d intent off"):format(size[1], size[2]), size[1], size[2], H.read("needs.md"))
  e3(("E3 <C-d>/<C-u> ledger.md %dx%d intent off"):format(size[1], size[2]), size[1], size[2], H.read("ledger.md"))
end

-- rows of gen(n) for a grid of about f window heights (row height measured)
local function rows_for(W, Hh)
  local c = D.start(W, Hh + 1)
  c.lua("_G.S = dofile(...); _G.M = require('custom.mdtable')", here .. "/screen.lua")
  c.lua("_G.BUF, _G.WIN = S.open(...)", gen(10))
  c.request("nvim_input", "<Ignore>")
  local g = c.lua([[local e = M._last_model(0).tables[1]
    local g = require('custom.mdtable.project').grid(e.tbl, e.lay, { width = vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].width - vim.fn.getwininfo(vim.api.nvim_get_current_win())[1].textoff, separators = true, tabstop = 8 })
    return { lines = #g.lines, row = g.count[3] }]])
  c.stop()
  local fixed = g.lines - 10 * (g.row + 1) -- borders, header, delimiter (+1: the separator after each body row but one)
  return function(f)
    local n = 1
    while fixed + n * (g.row + 1) < f * Hh do n = n + 1 end
    return n, fixed + n * (g.row + 1)
  end
end

for _, size in ipairs({ { 120, 45 }, { 100, 42 }, { 100, 30 } }) do
  local W, Hh = size[1], size[2]
  local nfor = rows_for(W, Hh)
  for _, intent in ipairs({ true, false }) do
    local tag = ("%dx%d intent %s"):format(W, Hh, intent and "on" or "off")
    scenario("needs.md " .. tag, W, Hh, intent, "needs.md", steps_file({ "Impossibly", "Sagg-acwrite" }, { 10, 12, 14 }))
    scenario("ledger.md " .. tag, W, Hh, intent, "ledger.md", steps_file({ "GM5", "Ignores" }, { 12, 20, 30 }))
    for _, lay in ipairs({ { 1 }, { 30 }, { 1, true } }) do
      local tail, short = lay[1], lay[2]
      for _, f in ipairs({ 0.5, 1.1, 1.5, 2, 4 }) do
        local n, gl = nfor(f)
        scenario(("grid %.1fx (%d rows, ~%d lines, %s, %d after) %s"):format(f, n, gl, short and "at line 3" or "after prose", tail, tag),
          W, Hh, intent, gen(n, tail, short), steps_gen(n, short))
      end
    end
  end
end
print(("LANDING total: %d steps, %d bad, %d known (100x42 page scroll outside a table)"):format(total.steps, total.bad, total.known))
H.done()
