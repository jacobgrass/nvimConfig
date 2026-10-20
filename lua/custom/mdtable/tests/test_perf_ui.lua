-- Performance in a child nvim with a 120x45 UI on needs.md (treesitter
-- highlighting on, as in the real editor).
-- 1. render() CPU per cursor move and per insert keystroke, median of 20,
--    with parser:parse done (and timed) before the render: the highlighter
--    pays the parse on every keystroke anyway.
-- 2. renders per key through the real input path (exactly 1).
-- 3. nvim_buf_clear_namespace(buf, ns, 0, -1) calls during all of it: 0.
-- 4. Editor delta: wall time per key (nvim_input + round trip, i.e. command,
--    autocmds, render and redraw), mdtable enabled minus `:MdTable disable`,
--    median of 30, best of 3 runs (the machine is shared).
local here = vim.fn.fnamemodify(_G.arg[0], ":p:h")
local H = dofile(here .. "/helpers.lua")
local D = dofile(here .. "/uidriver.lua")
local uv = vim.uv or vim.loop
print("PERF uptime: " .. vim.trim(vim.fn.system("uptime")))

local function median(t)
  local s = vim.list_extend({}, t)
  table.sort(s)
  return s[math.floor((#s + 1) / 2)]
end

local function child()
  local c = D.start(120, 46)
  c.lua([[
    _G.CLEAR_ALL, _G.CLEAR_OTHER, _G.CLEAR_WHERE = 0, 0, {}
    local orig = vim.api.nvim_buf_clear_namespace
    vim.api.nvim_buf_clear_namespace = function(b, ns, s, e)
      if s == 0 and e == -1 then
        local name
        for n, id in pairs(vim.api.nvim_get_namespaces()) do if id == ns then name = n end end
        if name and name:sub(1, 8) == "mdtable." then
          CLEAR_ALL = CLEAR_ALL + 1
          CLEAR_WHERE[#CLEAR_WHERE + 1] = debug.traceback("", 2)
        else
          CLEAR_OTHER = CLEAR_OTHER + 1 -- other plugins (the treesitter highlighter, ...)
        end
      end
      return orig(b, ns, s, e)
    end
    _G.S = dofile(...)
    _G.M = require("custom.mdtable")
    _G.BUF, _G.WIN = S.open("needs.md")
    vim.treesitter.start(BUF, "markdown")
  ]], here .. "/screen.lua")
  c.request("nvim_input", "<Ignore>")
  return c
end

local cpu = {}
H.run("render CPU: cursor move < 1.5 ms, insert keystroke < 3 ms (parse excluded), 1 render per key, no clear-all", function()
  local c = child()
  local r = c.lua([[
    local function cpu() local u = vim.uv.getrusage(); return (u.utime.sec + u.stime.sec) * 1e3 + (u.utime.usec + u.stime.usec) / 1e3 end
    local function med(t) table.sort(t); return t[math.floor((#t + 1) / 2)] end
    local win = vim.api.nvim_get_current_win()
    local moves, warm, ins, parse = {}, {}, {}, {}
    -- 20 distinct (row, cell) targets: every move is a first visit (cold projection)
    local targets = {}
    for l = 9, 13 do for j = 1, 4 do targets[#targets + 1] = { l, S.vis_col(l, j) } end end
    for i, t in ipairs(targets) do
      vim.fn.cursor(t[1] + 1, t[2] + 1)
      collectgarbage("collect")
      local t0 = cpu(); M.render(win); moves[i] = cpu() - t0
    end
    for i, t in ipairs(targets) do -- second visit: projection memoized
      vim.fn.cursor(t[1] + 1, t[2] + 1)
      local t0 = cpu(); M.render(win); warm[i] = cpu() - t0
    end
    -- insert keystrokes in cell 3 of row 10
    local l, col = 10, S.vis_col(10, 3)
    vim.fn.cursor(l + 1, col + 1); M.render(win)
    local parser = vim.treesitter.get_parser(BUF, "markdown")
    for i = 1, 20 do
      vim.api.nvim_buf_set_text(BUF, l, col, l, col, { "x" })
      col = col + 1
      vim.fn.cursor(l + 1, col + 1)
      local p0 = vim.uv.hrtime(); parser:parse({ 0, vim.api.nvim_buf_line_count(BUF) }); parse[i] = (vim.uv.hrtime() - p0) / 1e6
      collectgarbage("collect")
      local t0 = cpu(); M.render(win); ins[i] = cpu() - t0
    end
    return { move = med(moves), move_max = math.max(unpack(moves)), warm = med(warm), insert = med(ins),
      insert_max = math.max(unpack(ins)), parse = med(parse) }
  ]])
  -- renders per key through the real input path
  local n0, r0 = c.lua("return M.stats.n"), c.lua("return M.stats.reclips or 0")
  c.request("nvim_input", "<C-j>")
  local n1, r1 = c.lua("return M.stats.n"), c.lua("return M.stats.reclips or 0")
  c.request("nvim_input", "j")
  local n2, r2 = c.lua("return M.stats.n"), c.lua("return M.stats.reclips or 0")
  print(("PERF draw-only re-clips per key (WinScrolled): <C-j> %d, j %d"):format(r1 - r0, r2 - r1))
  local clear_all = c.lua("return CLEAR_ALL")
  local clear_other = c.lua("return CLEAR_OTHER")
  if clear_all > 0 then print(c.lua("return CLEAR_WHERE[1]")) end
  c.stop()
  print(("PERF render CPU, cursor move (first visit): median %.3f ms, max %.3f; repeat visit: median %.3f ms")
    :format(r.move, r.move_max, r.warm))
  print(("PERF render CPU, insert keystroke: median %.3f ms, max %.3f (parser:parse before it, median %.3f ms, not included)")
    :format(r.insert, r.insert_max, r.parse))
  print(("PERF renders per key: <C-j> %d, j %d; clear_namespace(0,-1) calls on mdtable namespaces: %d (other plugins: %d)")
    :format(n1 - n0, n2 - n1, clear_all, clear_other))
  cpu = r
  H.ok(r.move < 1.5, "cursor move CPU " .. r.move)
  H.ok(r.insert < 3, "insert keystroke CPU " .. r.insert)
  H.eq(1, n1 - n0, "renders for <C-j>")
  H.eq(1, n2 - n1, "renders for j")
  H.eq(0, clear_all, "clear_namespace(0, -1) calls")
end)

H.run("WinScrolled re-clip CPU < 0.5 ms median (draw only, 60-row table at 120x45, one-line scrolls)", function()
  local c = D.start(120, 46)
  local lines = { "# Big", "", "| # | Topic | Detail |", "|---|---|---|" }
  for i = 1, 60 do lines[#lines + 1] = ("| %d | topic%d | %s |"):format(i, i, ("detail word "):rep(12) .. "end" .. i) end
  lines[#lines + 1] = ""; lines[#lines + 1] = "after"
  c.lua("_G.S = dofile(...); _G.M = require('custom.mdtable')", here .. "/screen.lua")
  c.lua("_G.BUF, _G.WIN = S.open(...)", lines)
  c.request("nvim_input", ":34<CR>")
  c.request("nvim_eval", "1")
  local r = c.lua([[
    local function cpu() local u = vim.uv.getrusage(); return (u.utime.sec + u.stime.sec) * 1e3 + (u.utime.usec + u.stime.usec) / 1e3 end
    local function med(t) table.sort(t); return t[math.floor((#t + 1) / 2)] end
    local win = vim.api.nvim_get_current_win()
    local v = vim.fn.winsaveview()
    local n0, t = M.stats.n, {}
    local fills = {}
    for i = 0, 19 do fills[#fills + 1] = i end -- topfill 0..19 on the cursor line: the below block re-clips each time
    for i, f in ipairs(fills) do
      vim.fn.winrestview({ topline = v.topline, topfill = f })
      collectgarbage("collect")
      local t0 = cpu(); M.render(win, { nofit = true, reclip = true }); t[i] = cpu() - t0
    end
    -- the real path: <C-e> / <C-y> fire WinScrolled
    local r0 = M.stats.reclips or 0
    return { med = med(t), max = math.max(unpack(t)), renders = M.stats.n - n0, reclips0 = r0, topline = v.topline }
  ]])
  local r0 = r.reclips0
  -- 30 scroll keys through the real path (WinScrolled -> draw-only re-clip).
  -- WP-I: scroll-to-fit may scroll up to 2 extra rows on entering a row, so
  -- the below block's marker and the line after the table stay on screen in
  -- every cell; with that view the count per key is no longer exactly one
  -- (measured on the first 5 keys: 3 re-clips, i.e. two keys with none).
  -- Asserted per key: at most 2 re-clips and their CPU under 0.5 ms; keys
  -- without a re-clip are counted, and whether the view moved on them.
  local keys = {}
  for _ = 1, 6 do vim.list_extend(keys, { "<C-y>", "<C-y>", "<C-e>", "<C-e>", "<C-e>" }) end
  local worst, none, none_moved, cpu_max = 0, 0, 0, 0
  for i, k in ipairs(keys) do
    local b = c.lua("local v = vim.fn.winsaveview(); return { M.stats.reclips or 0, #(M.stats.rtimes or {}), v.topline, v.topfill }")
    c.request("nvim_input", k); c.request("nvim_eval", "1")
    local a = c.lua([[local from = ...; local rt = M.stats.rtimes or {}; local s = 0
      for j = from + 1, #rt do s = s + rt[j] end
      local v = vim.fn.winsaveview(); return { M.stats.reclips or 0, s, v.topline, v.topfill }]], b[2])
    local n = a[1] - b[1]
    worst, cpu_max = math.max(worst, n), math.max(cpu_max, a[2])
    if n == 0 then
      none = none + 1
      if a[3] ~= b[3] or a[4] ~= b[4] then none_moved = none_moved + 1 end
    end
    H.ok(n <= 2, ("scroll key %d %s: %d re-clips, at most 2"):format(i, k, n))
    H.ok(a[2] < 0.5, ("scroll key %d %s: re-clip CPU %.3f ms, under 0.5"):format(i, k, a[2]))
  end
  local after = c.lua("return { M.stats.reclips or 0, vim.fn.line('.'), M.stats_line() }")
  c.stop()
  print(("PERF WinScrolled re-clip CPU: median %.3f ms, max %.3f (20 views); renders during them %d; <C-y>/<C-e> x%d through the real path: %d re-clips (at most %d per key, CPU per key max %.3f ms), %d keys without a re-clip (%d of them moved the view), cursor line %d")
    :format(r.med, r.max, r.renders, #keys, after[1] - r0, worst, cpu_max, none, none_moved, after[2]))
  print("PERF " .. after[3])
  H.ok(r.med < 0.5, "re-clip CPU median " .. r.med)
  H.eq(0, r.renders, "re-clips are not renders")
  H.ok(worst <= 2, "never more than 2 re-clips per scroll key: " .. worst)
end)

H.run("editor delta (enabled - disabled), median of 30, best of 3: j < 1.5 ms, insert keystroke < 3 ms", function()
  local function run(enabled)
    local c = child()
    if not enabled then c.lua("M.toggle(false)") end
    c.lua("vim.fn.cursor(11, S.vis_col(10, 3) + 1)")
    c.request("nvim_input", "<Ignore>")
    local tj, ti = {}, {}
    for i = 1, 31 do
      local t0 = uv.hrtime()
      c.request("nvim_input", i % 2 == 1 and "j" or "k")
      c.request("nvim_eval", "1")
      if i > 1 then tj[#tj + 1] = (uv.hrtime() - t0) / 1e6 end
    end
    c.request("nvim_input", "i")
    c.request("nvim_eval", "1")
    for i = 1, 31 do
      local t0 = uv.hrtime()
      c.request("nvim_input", "x")
      c.request("nvim_eval", "1")
      if i > 1 then ti[#ti + 1] = (uv.hrtime() - t0) / 1e6 end
    end
    c.request("nvim_input", "<Esc>")
    c.stop()
    return median(tj), median(ti)
  end
  local best = { on = { j = math.huge, i = math.huge }, off = { j = math.huge, i = math.huge } }
  for rep = 1, 3 do
    local oj, oi = run(true)
    local fj, fi = run(false)
    print(("PERF editor run %d: j %.3f ms on / %.3f ms off; insert %.3f ms on / %.3f ms off"):format(rep, oj, fj, oi, fi))
    best.on.j, best.on.i = math.min(best.on.j, oj), math.min(best.on.i, oi)
    best.off.j, best.off.i = math.min(best.off.j, fj), math.min(best.off.i, fi)
  end
  local dj, di = best.on.j - best.off.j, best.on.i - best.off.i
  print(("PERF editor delta (best of 3 medians): j %.3f ms (%.3f on, %.3f off); insert %.3f ms (%.3f on, %.3f off)")
    :format(dj, best.on.j, best.off.j, di, best.on.i, best.off.i))
  print("PERF uptime: " .. vim.trim(vim.fn.system("uptime")))
  H.ok(dj < 1.5, "j delta " .. dj)
  H.ok(di < 3, "insert delta " .. di)
end)

H.done()
