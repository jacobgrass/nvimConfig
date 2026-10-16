-- custom.mdtable.draw: applies desired marks by diffing against drawn marks.
--
-- Per (buf, win) it records every persistent mark it drew by key:
--   "c<lnum>"  one per table line: conceal_lines, or a plain placeholder on
--              the anchor line (toggled in place, never deleted on a move)
--   "a<start>" / "b<start>"  the table's virt_lines anchors above / below
-- A desired mark whose key, row and signature match the record is left
-- untouched; a changed one is updated in place (`nvim_buf_set_extmark{id=}`);
-- a recorded key that is no longer desired is deleted by id. After a text
-- change the recorded rows are re-read from the buffer (one get_extmarks
-- call), because edits move marks.
-- Cursor-row marks live in a second namespace and are cleared only over the
-- line range they occupy. `nvim_buf_clear_namespace(buf, ns, 0, -1)` is used
-- only by draw.clear (detach / disable / closed window).
--
-- Namespaces are per window, scoped with nvim__ns_set; if scoping is not
-- available a shared pair is used (every window then shows the last render).
local api = vim.api
local M = {}

local wins = {} -- win -> { p = ns, c = ns }
local shared
local state = {} -- buf -> win -> { rec = {}, cur = nil, tick = nil }
M.counters = { set = 0, updated = 0, deleted = 0, cursor = 0, untouched = 0 }
local on_ns -- callback(ns) for every namespace created (scan.ignore_ns)

function M.on_namespace(fn) on_ns = fn end

local function mk(name)
  local id = api.nvim_create_namespace(name)
  if on_ns then on_ns(id) end
  return id
end

function M.ns(win)
  local n = wins[win]
  if n then return n end
  local p, c = mk("mdtable.p." .. win), mk("mdtable.c." .. win)
  local ok = api.nvim__ns_set ~= nil
    and pcall(api.nvim__ns_set, p, { wins = { win } })
    and pcall(api.nvim__ns_set, c, { wins = { win } })
  if not ok then
    shared = shared or { p = mk("mdtable.p"), c = mk("mdtable.c"), shared = true }
    n = shared
  else
    n = { p = p, c = c }
  end
  wins[win] = n
  return n
end

function M.all_ns()
  local out = {}
  for win, n in pairs(wins) do out[#out + 1] = { win = win, p = n.p, c = n.c } end
  return out
end

local function st_for(buf, win)
  local b = state[buf]
  if not b then b = {}; state[buf] = b end
  local s = b[win]
  if not s then s = { rec = {} }; b[win] = s end
  return s
end

local function reset_counters()
  local c = M.counters
  c.set, c.updated, c.deleted, c.cursor, c.untouched, c.deleted_conceal = 0, 0, 0, 0, 0, 0
end

local function opts_of(d, id)
  local o
  if d.kind == "conceal" then
    o = { conceal_lines = "" }
  elseif d.kind == "vl" then
    o = { virt_lines = d.lines, virt_lines_above = d.above or nil }
  elseif d.kind == "raw" then
    o = {}
    for k, v in pairs(d.o) do o[k] = v end
  else
    o = {}
  end
  o.id = id
  o.undo_restore = false
  return o
end

local function sig_of(d)
  if d.kind == "vl" then return (d.above and "a" or "b") .. (d.sig or tostring(d.lines)) end
  if d.kind == "raw" then return d.sig end
  return d.kind
end

-- Set desired mark d unless the record says it is drawn as is.
local function put(buf, n, rec, d, C)
  local r = rec[d.key]
  local sig = sig_of(d)
  if r and r.row == d.row and r.sig == sig then
    C.untouched = C.untouched + 1
  else
    local id = api.nvim_buf_set_extmark(buf, n.p, d.row, d.col or 0, opts_of(d, r and r.id))
    if r then C.updated = C.updated + 1 else C.set = C.set + 1 end
    rec[d.key] = { id = id, row = d.row, sig = sig, kind = d.kind }
  end
end

-- desired = { marks = { { key, row, kind = "conceal"|"place"|"vl", lines, above } },
--             cursor = { row, sig, marks = { { col, opts } } } | nil }
-- tick: the buffer's changedtick (re-read mark rows when it changed).
function M.apply(buf, win, desired, tick)
  reset_counters()
  local C = M.counters
  local n = M.ns(win)
  local s = st_for(buf, win)
  local rec = s.rec
  local stale = s.tick ~= tick
  if stale and next(rec) then
    local pos = {}
    for _, m in ipairs(api.nvim_buf_get_extmarks(buf, n.p, 0, -1, {})) do pos[m[1]] = m[2] end
    for key, r in pairs(rec) do
      r.row = pos[r.id]
      if r.row == nil then rec[key] = nil end
    end
  end
  local seen = {}
  for _, d in ipairs(desired.marks) do
    seen[d.key] = true
    put(buf, n, rec, d, C)
  end
  for key, r in pairs(rec) do
    if not seen[key] then
      pcall(api.nvim_buf_del_extmark, buf, n.p, r.id)
      C.deleted = C.deleted + 1
      if r.kind == "conceal" then C.deleted_conceal = C.deleted_conceal + 1 end
      rec[key] = nil
    end
  end
  -- cursor row
  local cur, want = s.cur, desired.cursor
  local same = cur and want and not stale and cur.row == want.row and cur.sig == want.sig
  if not same then
    if cur then
      local lo, hi = cur.row, cur.row
      if stale then
        lo, hi = math.huge, -1
        for _, m in ipairs(api.nvim_buf_get_extmarks(buf, n.c, 0, -1, {})) do
          if m[2] < lo then lo = m[2] end
          if m[2] > hi then hi = m[2] end
        end
      end
      if hi >= lo then api.nvim_buf_clear_namespace(buf, n.c, lo, hi + 1) end
    end
    s.cur = nil
    if want then
      api.nvim_buf_clear_namespace(buf, n.c, want.row, want.row + 1)
      for _, m in ipairs(want.marks) do
        local o = {}
        for k2, v in pairs(m[2]) do o[k2] = v end
        o.undo_restore = false
        local ok = pcall(api.nvim_buf_set_extmark, buf, n.c, want.row, m[1], o)
        if ok then C.cursor = C.cursor + 1 end
      end
      s.cur = { row = want.row, sig = want.sig }
    end
  end
  s.tick = tick
  return C
end

-- Update one desired mark of the last apply (a re-clipped block) in place;
-- adds to the counters of that apply.
function M.update(buf, win, d)
  local s = state[buf] and state[buf][win]
  if not s then return end
  put(buf, M.ns(win), s.rec, d, M.counters)
end

-- Remove everything drawn for (buf, win), or for every window of buf.
function M.clear(buf, win)
  local b = state[buf]
  if api.nvim_buf_is_valid(buf) then
    for w, n in pairs(wins) do
      if win == nil or w == win then
        api.nvim_buf_clear_namespace(buf, n.p, 0, -1)
        api.nvim_buf_clear_namespace(buf, n.c, 0, -1)
      end
    end
  end
  if b then
    if win == nil then state[buf] = nil else b[win] = nil end
  end
end

-- A window closed: drop its marks in every buffer and its record.
function M.forget_win(win)
  local n = wins[win]
  if not n then return end
  for buf, b in pairs(state) do
    if b[win] then
      if api.nvim_buf_is_valid(buf) and not n.shared then
        api.nvim_buf_clear_namespace(buf, n.p, 0, -1)
        api.nvim_buf_clear_namespace(buf, n.c, 0, -1)
      end
      b[win] = nil
    end
  end
  if not n.shared then wins[win] = nil end
end

function M.forget_buf(buf) state[buf] = nil end

function M._state(buf, win) return state[buf] and state[buf][win] end

return M
