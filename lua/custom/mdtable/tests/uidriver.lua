-- Minimal msgpack-RPC driver: spawns `nvim --embed --clean`, attaches a UI of
-- a given size (so the child's screen grid really has that size; headless
-- Neovim without a UI does not resize its grid and corrupts memory when
-- 'lines' > 24), discards the redraw events and runs Lua in the child.
local uv = vim.uv or vim.loop
local D = {}

function D.start(W, H, env)
  local stdin, stdout = uv.new_pipe(false), uv.new_pipe(false)
  local self = { pending = {}, id = 0, closed = false }
  local args = { "--embed", "--clean" }
  local handle
  handle = uv.spawn("nvim", { args = args, stdio = { stdin, stdout, 2 }, env = env }, function()
    self.closed = true
  end)
  assert(handle, "spawn nvim failed")
  self.handle, self.stdin, self.stdout = handle, stdin, stdout
  local unpack = vim.mpack.Unpacker()
  stdout:read_start(function(err, data)
    if err or not data then self.closed = true; return end
    local pos = 1
    while pos <= #data do
      local obj, np = unpack(data, pos)
      if np == pos then break end
      pos = np
      if obj ~= nil and type(obj) == "table" and obj[1] == 1 then self.pending[obj[2]] = { err = obj[3], res = obj[4] } end
    end
  end)
  function self.request(method, ...)
    self.id = self.id + 1
    local id = self.id
    stdin:write(vim.mpack.encode({ 0, id, method, { ... } }))
    local t0 = uv.now()
    while not self.pending[id] do
      if self.closed then error("child nvim exited during " .. method) end
      if D.timeout_ms then -- opt-in: a child stuck in a prompt fails the test instead of hanging it
        uv.update_time()
        if uv.now() - t0 > D.timeout_ms then
          self.closed = true
          pcall(function() handle:kill(9) end)
          error(("child nvim did not answer %s within %d ms"):format(method, D.timeout_ms), 2)
        end
        uv.run("nowait")
        if not self.pending[id] then uv.sleep(1) end
      else
        uv.run("once")
      end
    end
    local r = self.pending[id]
    self.pending[id] = nil
    if r.err ~= nil and r.err ~= vim.NIL then
      error(method .. ": " .. vim.inspect(r.err), 2)
    end
    return r.res
  end
  function self.lua(code, ...) return self.request("nvim_exec_lua", code, { ... }) end
  function self.resize(w, h) return self.request("nvim_ui_try_resize", w, h) end
  function self.stop()
    pcall(self.request, "nvim_command", "qa!")
    if not handle:is_closing() then handle:kill(15) end
    for _ = 1, 50 do if self.closed then break end; uv.run("nowait"); uv.sleep(10) end
  end
  self.request("nvim_ui_attach", W, H, { ext_linegrid = true })
  return self
end

return D
