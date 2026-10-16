-- Test helpers for `nvim -l` unit tests of custom.mdtable (no init.lua is
-- loaded: the config dir is prepended to 'runtimepath'; the markdown parsers
-- and queries come from ~/.local/share/nvim/site, which is on the default
-- 'runtimepath' of `nvim -l`).
local cfg = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h:h:h")
vim.opt.rtp:prepend(cfg)
local H = { cfg = cfg, fixtures = cfg .. "/lua/custom/mdtable/tests/fixtures", passed = 0, failed = 0 }

function H.fail(msg) error(msg, 2) end

function H.ok(v, msg)
  if not v then error("not ok: " .. (msg or "?"), 2) end
end

function H.eq(want, got, msg)
  if not vim.deep_equal(want, got) then
    error(("%s\n  want: %s\n  got:  %s"):format(msg or "eq", vim.inspect(want), vim.inspect(got)), 2)
  end
end

function H.run(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if ok then
    H.passed = H.passed + 1
    print("PASS " .. name)
  else
    H.failed = H.failed + 1
    print("FAIL " .. name .. "\n" .. tostring(err))
  end
end

function H.read(name)
  return vim.fn.readfile(H.fixtures .. "/" .. name)
end

-- Scratch markdown buffer shown in the current window, parser attached.
function H.with_buffer(lines, fn)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_set_current_buf(buf)
  assert(vim.treesitter.get_parser(buf, "markdown"), "no markdown parser")
  local ok, err = xpcall(fn, debug.traceback, buf)
  pcall(require("custom.mdtable.scan").detach, buf)
  vim.api.nvim_buf_delete(buf, { force = true })
  if not ok then error(err, 0) end
end

-- Median of fn() timings in ms over n runs.
function H.median_ms(n, fn)
  local t = {}
  for i = 1, n do
    local t0 = vim.uv.hrtime()
    fn(i)
    t[i] = (vim.uv.hrtime() - t0) / 1e6
  end
  table.sort(t)
  return t[math.floor((n + 1) / 2)]
end

function H.done()
  print(("SUMMARY %s: %d passed, %d failed"):format(vim.fn.fnamemodify(_G.arg[0] or "?", ":t"), H.passed, H.failed))
  os.exit(H.failed == 0 and 0 or 1)
end

return H
