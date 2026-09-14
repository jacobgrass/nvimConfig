-- Locate the compile_commands.json that clangd should use for a given file.
--
-- Search order, walking upward from the file's directory (stopping at $HOME / the
-- filesystem root):
--   1. `vim.g.clangd_compile_commands_dir` override (absolute, or relative to the
--      workspace root).
--   2. A `.clangd` config that sets `CompilationDatabase` -> defer to clangd.
--   3. `<dir>/compile_commands.json`
--   4. `<dir>/<build-like>/compile_commands.json`, up to two levels below any
--      build-like directory (build/, out/, build-*, *-build, cmake-build-*, ...),
--      so layouts such as `build/linux-debug/`, `out/build/x64-Debug/` and
--      superbuilds like `build/<project>-build/` are found.
-- When several databases sit at the same level, prefer the one that lists the
-- file being edited, then the most recently generated one.

local M = {}

local uv = vim.uv or vim.loop
local CC = "compile_commands.json"
local MAX_ANCESTORS = 16
local MAX_DB_BYTES = 64 * 1024 * 1024

local SKIP_DIRS = {
  [".git"] = true,
  [".cache"] = true,
  ["_deps"] = true,
  ["CMakeFiles"] = true,
  ["node_modules"] = true,
}

local function file_exists(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "file"
end

local function join(...)
  return table.concat({ ... }, "/")
end

local function read_file(path, max_bytes)
  local st = uv.fs_stat(path)
  if not st or st.type ~= "file" or st.size > max_bytes then
    return nil
  end
  local fd = uv.fs_open(path, "r", 438)
  if not fd then
    return nil
  end
  local data = uv.fs_read(fd, st.size, 0)
  uv.fs_close(fd)
  return data
end

local function is_build_dir_name(name)
  local n = name:lower()
  return n == "build"
    or n == "builds"
    or n == "_build"
    or n == "out"
    or n:match("^build[-_.]") ~= nil
    or n:match("[-_.]build$") ~= nil
    or n:match("^cmake%-build") ~= nil
    or n:match("^out[-_.]") ~= nil
end

local function list_subdirs(dir)
  local out = {}
  pcall(function()
    for name, kind in vim.fs.dir(dir) do
      if kind == "directory" and not SKIP_DIRS[name] then
        out[#out + 1] = name
      end
    end
  end)
  table.sort(out)
  return out
end

-- compile_commands.json under build-like children of `dir`, at most two levels
-- below the build directory itself.
local function build_dir_candidates(dir)
  local found = {}
  local function check(d)
    if file_exists(join(d, CC)) then
      found[#found + 1] = d
    end
  end
  for _, name in ipairs(list_subdirs(dir)) do
    if is_build_dir_name(name) then
      local b = join(dir, name)
      check(b)
      for _, sub in ipairs(list_subdirs(b)) do
        local s = join(b, sub)
        check(s)
        for _, sub2 in ipairs(list_subdirs(s)) do
          check(join(s, sub2))
        end
      end
    end
  end
  return found
end

-- 2: database lists this exact file, 1: lists a file with the same basename, 0: neither.
local function db_match_score(db_dir, fname)
  local data = read_file(join(db_dir, CC), MAX_DB_BYTES)
  if not data then
    return 0
  end
  if data:find(fname, 1, true) then
    return 2
  end
  -- JSON-escaped Windows paths: "C:\\proj\\src\\a.cpp"
  local escaped = fname:gsub("/", "\\\\")
  if escaped ~= fname and data:find(escaped, 1, true) then
    return 2
  end
  local base = vim.fs.basename(fname)
  if data:find("/" .. base .. '"', 1, true) or data:find("\\\\" .. base .. '"', 1, true) then
    return 1
  end
  return 0
end

local function db_mtime(db_dir)
  local st = uv.fs_stat(join(db_dir, CC))
  return st and st.mtime and st.mtime.sec or 0
end

local function pick_best(candidates, fname)
  local best, best_score, best_mtime
  for _, dir in ipairs(candidates) do
    local score = db_match_score(dir, fname)
    local mtime = db_mtime(dir)
    if best == nil or score > best_score or (score == best_score and mtime > best_mtime) then
      best, best_score, best_mtime = dir, score, mtime
    end
  end
  return best
end

-- A project-level .clangd that points at a database wins over our guess.
local function clangd_config_sets_db(dir)
  local data = read_file(join(dir, ".clangd"), 1024 * 1024)
  return data ~= nil and data:find("CompilationDatabase", 1, true) ~= nil
end

local function is_absolute(path)
  return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil
end

local function is_search_boundary(dir, home)
  return dir == nil or dir == "" or dir == "/" or dir == home or dir:match("^%a:/?$") ~= nil
end

--- Find the directory holding compile_commands.json for `fname`.
---@param fname string absolute path of the source file
---@param root string|nil workspace root (used to resolve a relative override)
---@return string|nil db_dir directory containing compile_commands.json, or nil to let clangd decide
---@return string|nil found_under ancestor of `fname` the database was found beneath
function M.find(fname, root)
  fname = vim.fs.normalize(fname)

  local override = vim.g.clangd_compile_commands_dir
  if type(override) == "string" and override ~= "" then
    local dir = vim.fs.normalize(override)
    if not is_absolute(dir) and root then
      dir = join(vim.fs.normalize(root), dir)
    end
    if file_exists(join(dir, CC)) then
      return dir, root
    end
    vim.notify_once(
      ("clangd: vim.g.clangd_compile_commands_dir=%s has no %s; falling back to auto-detection"):format(override, CC),
      vim.log.levels.WARN
    )
  end

  local home = vim.fs.normalize(uv.os_homedir() or "")
  local dir = vim.fs.dirname(fname)
  for _ = 1, MAX_ANCESTORS do
    if is_search_boundary(dir, home) then
      break
    end
    if clangd_config_sets_db(dir) then
      return nil, dir
    end
    if file_exists(join(dir, CC)) then
      return dir, dir
    end
    local candidates = build_dir_candidates(dir)
    if #candidates > 0 then
      return pick_best(candidates, fname), dir
    end
    local parent = vim.fs.dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end

  return nil, nil
end

local ROOT_MARKERS = { CC, "compile_flags.txt", ".clangd", "CMakeLists.txt", ".git" }

--- Resolve the workspace root and compilation database for a buffer.
--- The root is widened to the directory the database was found under, so a
--- nested repo or subproject inside a superbuild shares one clangd instance.
---@param bufnr integer
---@return string|nil root
---@return string|nil db_dir
function M.resolve(bufnr)
  local fname = vim.api.nvim_buf_get_name(bufnr)
  if fname == "" then
    return nil, nil
  end
  fname = vim.fs.normalize(fname)

  local marker_root = vim.fs.root(bufnr, ROOT_MARKERS)
  if marker_root then
    marker_root = vim.fs.normalize(marker_root)
  end

  local db_dir, found_under = M.find(fname, marker_root)

  local root = marker_root
  if found_under and (root == nil or #found_under < #root) then
    root = found_under
  end
  root = root or vim.fs.dirname(fname)

  return root, db_dir
end

return M
