-- WSL clipboard that never blocks the editor.
--
-- The Windows side (win32yank.exe) runs through the WSL interop bridge. When
-- that bridge is down every Windows binary hangs ~10 s on a vsock timeout, so:
--   * copy is async (spawn and return), killed after 2 s;
--   * paste waits at most 1.5 s, then falls back to the last local copy;
--   * an async startup probe (1 s) decides the mode; until it succeeds, copy
--     goes out over OSC 52 and paste returns the last local copy (OSC 52 paste
--     is not used: Windows terminals never answer the query and it waits 10 s);
--   * a failed probe is retried on FocusGained (and on paste) at most once a
--     minute;
--   * a WSL_INTEROP that points at a missing socket is replaced by the newest
--     /run/WSL/*_interop.
local M = {}

local YANK = "win32yank.exe"

-- Spawn through sh: libuv blocks the caller until exec succeeds, and exec of a
-- Windows binary costs ~30 ms; exec of sh costs ~1 ms (same pid after exec).
local function yank(...)
  return { "/bin/sh", "-c", 'exec "$0" "$@"', YANK, ... }
end
local PROBE_MS, COPY_MS, PASTE_MS, REPROBE_S = 1000, 2000, 1500, 60

local state = {
  mode = "osc52", -- "osc52" until a probe succeeds, then "win32yank"
  socket_note = "unchanged",
  probe = nil, -- { ok, code, ms, at, socket }
  probing = false,
  copy_job = nil, -- in-flight win32yank -i
  last = nil, -- { lines, regtype } of the last copy from this nvim
  notified = false,
}

local function notify(msg)
  if state.notified then
    return
  end
  state.notified = true
  vim.schedule(function()
    vim.notify(msg, vim.log.levels.WARN)
  end)
end

-- Point WSL_INTEROP at a socket that exists; child processes inherit vim.env.
local function resolve_socket()
  local cur = vim.env.WSL_INTEROP
  if cur and cur ~= "" and vim.uv.fs_stat(cur) then
    return
  end
  local best, best_t
  for _, p in ipairs(vim.fn.glob("/run/WSL/*_interop", false, true)) do
    local st = vim.uv.fs_stat(p)
    if st and st.type == "socket" and (not best_t or st.mtime.sec > best_t) then
      best, best_t = p, st.mtime.sec
    end
  end
  if best then
    state.socket_note = ("replaced %s"):format(cur or "(unset)")
    vim.env.WSL_INTEROP = best
  else
    state.socket_note = ("no live socket for %s"):format(cur or "(unset)")
  end
end

local function local_paste()
  if state.last then
    return { state.last[1], state.last[2] }
  end
  return { { "" }, "v" }
end

local osc52 = require "vim.ui.clipboard.osc52"

local function copy_fn(reg)
  local osc = osc52.copy(reg)
  return function(lines, regtype)
    state.last = { vim.deepcopy(lines), regtype }
    if state.mode ~= "win32yank" then
      osc(lines)
      return
    end
    if state.copy_job then
      if vim.deep_equal(state.copy_lines, lines) then
        return -- "+" and "*" are the same Windows clipboard: one write is enough
      end
      pcall(state.copy_job.kill, state.copy_job, 15)
    end
    local job
    local ok = pcall(function()
      job = vim.system(yank("-i", "--crlf"), {
        stdin = table.concat(lines, "\n"),
        timeout = COPY_MS,
      }, function(r)
        vim.schedule(function()
          if state.copy_job ~= job then
            return -- superseded by a newer copy (and killed)
          end
          state.copy_job = nil
          if r.code ~= 0 then
            M._bridge_failed(("copy exit %d"):format(r.code))
            osc(lines) -- still reach the terminal clipboard
          end
        end)
      end)
    end)
    state.copy_job, state.copy_lines = ok and job or nil, lines
    if not ok then
      M._bridge_failed "copy spawn failed"
      osc(lines)
    end
  end
end

local function paste_fn()
  return function()
    if state.mode ~= "win32yank" then
      M.maybe_reprobe()
      notify "clipboard bridge down; using local register"
      return local_paste()
    end
    if state.copy_job then
      return local_paste() -- our own copy is still landing; it is the newest
    end
    local ok, r = pcall(function()
      return vim.system(yank("-o", "--lf"), { text = true, timeout = PASTE_MS }):wait()
    end)
    if ok and r.code == 0 then
      return vim.split(r.stdout or "", "\n", { plain = true })
    end
    M._bridge_failed(ok and ("paste exit %d"):format(r.code) or "paste spawn failed")
    notify "clipboard bridge timed out; using local register"
    return local_paste()
  end
end

local function apply(mode)
  state.mode = mode
  vim.g.clipboard = {
    name = mode == "win32yank" and "win32yank (async)" or "OSC 52 (win32yank bridge down)",
    copy = { ["+"] = copy_fn "+", ["*"] = copy_fn "*" },
    paste = { ["+"] = paste_fn(), ["*"] = paste_fn() },
    cache_enabled = 1,
  }
  -- Re-read g:clipboard if the provider is already loaded.
  if vim.g.loaded_clipboard_provider then
    pcall(vim.fn["provider#clipboard#Executable"])
  end
end

function M._bridge_failed(why)
  state.probe = { ok = false, code = why, ms = 0, at = os.time(), socket = vim.env.WSL_INTEROP }
  if state.mode ~= "osc52" then
    apply "osc52"
  end
end

function M.probe()
  if state.probing then
    return
  end
  state.probing = true
  resolve_socket()
  local t0 = vim.uv.hrtime()
  local ok = pcall(vim.system, yank("-o", "--lf"), { timeout = PROBE_MS }, function(r)
    local ms = math.floor((vim.uv.hrtime() - t0) / 1e6)
    vim.schedule(function()
      state.probing = false
      state.probe = { ok = r.code == 0, code = r.code, ms = ms, at = os.time(), socket = vim.env.WSL_INTEROP }
      if r.code == 0 then
        state.notified = false
        apply "win32yank"
      end
    end)
  end)
  if not ok then
    state.probing = false
    state.probe = { ok = false, code = "spawn failed", ms = 0, at = os.time(), socket = vim.env.WSL_INTEROP }
  end
end

function M.maybe_reprobe()
  local p = state.probe
  if state.mode == "osc52" and p and not p.ok and os.time() - p.at >= REPROBE_S then
    M.probe()
  end
end

function M.status()
  local p = state.probe
  local probe = p
      and ("%s (%s, %d ms) at %s via %s"):format(
        p.ok and "ok" or "failed",
        tostring(p.code),
        p.ms,
        os.date("%H:%M:%S", p.at),
        p.socket or "?"
      )
    or (state.probing and "running" or "none")
  return table.concat({
    "provider:    " .. (vim.g.clipboard and vim.g.clipboard.name or "?"),
    "WSL_INTEROP: " .. (vim.env.WSL_INTEROP or "(unset)") .. " [" .. state.socket_note .. "]",
    "last probe:  " .. probe,
  }, "\n")
end

M._state = state
M._apply = apply

function M.setup()
  resolve_socket() -- now, so every child (LSP, :terminal) inherits a live one
  apply "osc52"
  vim.schedule(M.probe) -- off the startup path
  vim.api.nvim_create_autocmd("FocusGained", {
    group = vim.api.nvim_create_augroup("custom_clipboard", { clear = true }),
    callback = M.maybe_reprobe,
  })
  vim.api.nvim_create_user_command("ClipboardStatus", function()
    print(M.status())
  end, { desc = "Show clipboard provider, WSL interop socket and last probe" })
end

return M
