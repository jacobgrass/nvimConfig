local H = dofile(vim.fn.fnamemodify(_G.arg[0], ":p:h") .. "/helpers.lua")
local scan = require("custom.mdtable.scan")
local layout = require("custom.mdtable.layout")
local api = vim.api

local big_table = dofile(vim.fn.fnamemodify(_G.arg[0], ":p:h") .. "/gen.lua").big_table

local N = 20
local report = {}

-- Median of n timings where setup(i) runs untimed before each timed fn(i).
local function timed(n, setup, fn)
  local t = {}
  for i = 1, n do
    local ctx = setup and setup(i)
    collectgarbage("collect")
    local t0 = vim.uv.hrtime()
    fn(i, ctx)
    t[i] = (vim.uv.hrtime() - t0) / 1e6
    if ctx and ctx.cleanup then ctx.cleanup() end
  end
  table.sort(t)
  return t[math.floor((n + 1) / 2)], t[1], t[n]
end

local function fresh(lines)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  return { buf = buf, cleanup = function() scan.detach(buf); api.nvim_buf_delete(buf, { force = true }) end }
end

local function line(fmt, ...)
  local s = fmt:format(...)
  report[#report + 1] = s
  print("PERF " .. s)
end

local function cpu_ms()
  local r = vim.uv.getrusage()
  return (r.utime.sec + r.stime.sec) * 1e3 + (r.utime.usec + r.stime.usec) / 1e3
end

-- Director ruling 2026-10-16: the tree reparse is paid by Neovim's highlighter
-- on every keystroke anyway, so it is timed and printed separately; the
-- budgets apply to scan's own work (scan.tables + layout.cached) in CPU time.
local function load() return vim.trim(vim.fn.system("cut -d' ' -f1-3 /proc/loadavg")) end
local function med_of(t) table.sort(t); return t[math.floor((#t + 1) / 2)], t[1] end
local OPTS = { width = 115, separators = true }

H.run("perf: cold scan + layout of 20x7 table with 300-char cells < 12 ms CPU (tree parsed first)", function()
  local lines = big_table()
  local ntab, cpu, wall, parse = 0, {}, {}, {}
  for i = 1, N do
    layout.cache_clear()
    local ctx = fresh(lines)
    local parser = vim.treesitter.get_parser(ctx.buf, "markdown")
    local n = api.nvim_buf_line_count(ctx.buf)
    collectgarbage("collect")
    local p0 = cpu_ms()
    parser:parse({ 0, n })
    parse[i] = cpu_ms() - p0
    local w0, c0 = vim.uv.hrtime(), cpu_ms()
    local t = scan.tables(ctx.buf, 0, n)
    layout.cached(t[1], OPTS)
    cpu[i], wall[i] = cpu_ms() - c0, (vim.uv.hrtime() - w0) / 1e6
    ntab = #t
    ctx.cleanup()
  end
  H.eq(1, ntab)
  local probe = fresh(lines)
  local nconc = 0
  for _, r in ipairs(scan.tables(probe.buf)[1].rows) do for _, c in ipairs(r.cells) do nconc = nconc + #c.cs end end
  probe.cleanup()
  H.ok(nconc > 1000, "generated table carries inline markup: " .. nconc .. " conceal ranges")
  local cm, cmin = med_of(cpu)
  local wm = med_of(wall)
  local pm = med_of(parse)
  line("cold scan+layout 20x7x300 (own work): CPU median %.3f ms (min %.3f), wall median %.3f ms; first treesitter parse CPU median %.3f ms; load %s",
    cm, cmin, wm, pm, load())
  H.ok(cm < 12, "CPU median " .. cm)
end)

H.run("perf: scan + layout after a one-row edit < 1.5 ms CPU (reparse timed separately), 19 hits", function()
  local lines = big_table()
  local ctx = fresh(lines)
  local buf = ctx.buf
  local parser = vim.treesitter.get_parser(buf, "markdown")
  local t = scan.tables(buf)
  H.eq(20, #t[1].rows)
  local lo, hi = t[1].start_row, t[1].end_row
  local hits, cpu, wall, parse = {}, {}, {}, {}
  for i = 1, N do
    local r = 4 + (i % 18) -- body rows are buffer rows 4..21
    local l = api.nvim_buf_get_lines(buf, r, r + 1, false)[1]
    api.nvim_buf_set_lines(buf, r, r + 1, false, { l:gsub("| ", "| x" .. i .. " ", 1) .. "" })
    collectgarbage("collect")
    local p0 = cpu_ms()
    parser:parse({ lo, hi })
    parse[i] = cpu_ms() - p0
    local w0, c0 = vim.uv.hrtime(), cpu_ms()
    local tt = scan.tables(buf, lo, hi)
    layout.cached(tt[1], OPTS)
    cpu[i], wall[i] = cpu_ms() - c0, (vim.uv.hrtime() - w0) / 1e6
    hits[i] = scan.stats(buf).hits .. "/" .. scan.stats(buf).misses
  end
  for i = 1, N do H.eq("19/1", hits[i], "run " .. i .. " hits/misses") end
  local cm, cmin = med_of(cpu)
  local wm = med_of(wall)
  local pm, pmin = med_of(parse)
  line("one-row edit, scan+layout (own work): CPU median %.3f ms (min %.3f), wall median %.3f ms; reparse CPU median %.3f ms (min %.3f); load %s",
    cm, cmin, wm, pm, pmin, load())
  local nmed = timed(N, nil, function() scan.tables(buf, lo, hi) end)
  line("scan, nothing changed: wall median %.3f ms", nmed)
  ctx.cleanup()
  H.ok(cm < 1.5, "CPU median " .. cm)
end)

H.run("sharing: a second parse of the same range is a no-op; the highlighter's later parse hits", function()
  local lines = big_table()
  local ctx = fresh(lines)
  local buf = ctx.buf
  local parser = vim.treesitter.get_parser(buf, "markdown")
  local t = scan.tables(buf)
  local lo, hi = t[1].start_row, t[1].end_row
  local first, second, valid_before, valid_after, valid_all = {}, {}, true, true, nil
  for i = 1, N do
    local r = 4 + (i % 18)
    local l = api.nvim_buf_get_lines(buf, r, r + 1, false)[1]
    api.nvim_buf_set_lines(buf, r, r + 1, false, { l:gsub("| ", "| y" .. i .. " ", 1) .. "" })
    valid_before = valid_before and parser:is_valid(false, { lo, 0, hi, 0 })
    local c0 = cpu_ms()
    parser:parse({ lo, hi })
    local c1 = cpu_ms()
    parser:parse({ lo, hi })
    local c2 = cpu_ms()
    first[i], second[i] = c1 - c0, c2 - c1
    valid_after = valid_after and parser:is_valid(false, { lo, 0, hi, 0 })
    valid_all = parser:is_valid()
  end
  -- what the highlighter does in on_start: parse the window's {topline, botline} with a callback
  local sync, cb_ms
  local c0 = cpu_ms()
  local trees = parser:parse({ { lo + 2, hi - 2 } }, function() sync = true end)
  cb_ms = cpu_ms() - c0
  local fm = med_of(first)
  local sm = med_of(second)
  line("sharing: reparse after edit CPU median %.3f ms, same range again %.4f ms; is_valid(range) before %s, after %s; is_valid() whole buffer %s; highlighter-style parse returned trees %s in %.4f ms",
    fm, sm, tostring(valid_before), tostring(valid_after), tostring(valid_all), tostring(trees ~= nil), cb_ms)
  ctx.cleanup()
  H.eq(false, valid_before, "an edit invalidates the range")
  H.eq(true, valid_after, "one parse makes the range valid")
  H.ok(sm < 0.25 and sm < fm / 4, "second parse is a no-op: " .. sm)
  H.ok(trees ~= nil, "highlighter-style parse of a covered window range finishes synchronously")
  H.ok(cb_ms < 0.25, "and costs ~0: " .. cb_ms)
end)

H.run("perf: layout.cached hit < 0.05 ms", function()
  local ctx = fresh(big_table())
  local t = scan.tables(ctx.buf)[1]
  layout.cache_clear()
  local miss = timed(1, nil, function() layout.cached(t, { width = 115, separators = true }) end)
  local first = layout.cached(t, { width = 115, separators = true })
  local med = timed(N, nil, function()
    assert(layout.cached(t, { width = 115, separators = true }) == first)
  end)
  local lmed = timed(N, nil, function() layout.table(t, { width = 115, separators = true }) end)
  line("layout.cached hit: median %.4f ms (miss %.3f ms; uncached layout.table median %.3f ms)", med, miss, lmed)
  ctx.cleanup()
  H.ok(med < 0.05, "median " .. med)
end)

H.run("perf: memory of one cold scan of needs.md < 300 KB", function()
  local ctx = fresh(H.read("needs.md"))
  collectgarbage("collect")
  collectgarbage("stop")
  local before = collectgarbage("count")
  local t = scan.tables(ctx.buf)
  local kb = collectgarbage("count") - before
  collectgarbage("restart")
  H.eq(1, #t)
  local before2 = collectgarbage("count")
  collectgarbage("stop")
  before2 = collectgarbage("count")
  scan.tables(ctx.buf)
  local kb2 = collectgarbage("count") - before2
  collectgarbage("restart")
  line("memory: cold scan of needs.md %.1f KB, warm scan %.1f KB", kb, kb2)
  ctx.cleanup()
  H.ok(kb < 300, kb .. " KB")
end)

H.done()
