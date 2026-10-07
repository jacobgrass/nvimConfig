-- Shared prettier lookup: prefer the project's own prettier and run it from the
-- project root, so that plugins named in the project's config resolve.
local uv = vim.uv or vim.loop

local M = {}

local is_windows = vim.fn.has("win32") == 1

local function file_exists(path)
  return path and uv.fs_stat(path) ~= nil
end

local function file_dir(filepath)
  if filepath == nil or filepath == "" then
    return nil
  end
  return vim.fs.dirname(vim.fs.normalize(vim.fn.fnamemodify(filepath, ":p")))
end

-- PATH, then Mason bin, then the Mason package-local .bin (same order as before).
local function find_global()
  local path = vim.fn.exepath("prettier")
  if path ~= "" then
    return path
  end

  local mason_data = vim.fn.stdpath("data") .. "/mason/"
  local bins = {
    mason_data .. "bin/prettier",
    mason_data .. "packages/prettier/node_modules/.bin/prettier",
  }

  for _, bin in ipairs(bins) do
    local candidates = { bin }
    if is_windows then
      table.insert(candidates, bin .. ".cmd")
      table.insert(candidates, bin .. ".exe")
    end
    for _, candidate in ipairs(candidates) do
      if file_exists(candidate) then
        return candidate
      end
    end
  end

  return nil
end

--- Return the nearest node_modules/.bin/prettier above filepath, else the
--- global prettier (PATH or Mason), else nil.
function M.find_prettier(filepath)
  local dir = file_dir(filepath)
  if dir then
    local names = is_windows and { "prettier.cmd", "prettier.exe", "prettier" } or { "prettier" }
    local dirs = { dir }
    vim.list_extend(dirs, vim.iter(vim.fs.parents(dir)):totable())
    for _, d in ipairs(dirs) do
      for _, name in ipairs(names) do
        local candidate = vim.fs.joinpath(d, "node_modules", ".bin", name)
        if file_exists(candidate) then
          return candidate
        end
      end
    end
  end

  return find_global()
end

local function is_root_marker(name)
  return name == "package.json" or name == ".git" or name:match("^%.prettierrc") ~= nil
end

--- Directory to run prettier from: the project root (nearest package.json,
--- .prettierrc* or .git), else the file's directory.
function M.cwd_for(filepath)
  local dir = file_dir(filepath)
  if not dir then
    return nil
  end
  local found = vim.fs.find(is_root_marker, { path = dir, upward = true, limit = 1 })[1]
  return found and vim.fs.dirname(found) or dir
end

return M
