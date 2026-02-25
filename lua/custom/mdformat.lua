local vim = vim
local uv = vim.uv or vim.loop

local function find_executable(name)
  local path = vim.fn.exepath(name)
  if path ~= "" then
    return path
  end

  local is_windows = vim.fn.has("win32") == 1
  local mason_bin = vim.fn.stdpath("data") .. "/mason/bin/"
  local candidates = { mason_bin .. name }

  if is_windows then
    table.insert(candidates, mason_bin .. name .. ".cmd")
    table.insert(candidates, mason_bin .. name .. ".exe")
  end

  for _, candidate in ipairs(candidates) do
    if uv.fs_stat(candidate) then
      return candidate
    end
  end

  return nil
end

local function run_formatter(filepath)
  -- Prettier outputs consistently aligned Markdown tables, so use it first.
  local prettier = find_executable("prettier")
  if prettier then
    return vim.system({
      prettier,
      "--write",
      "--parser",
      "markdown",
      "--print-width",
      "80",
      "--prose-wrap",
      "always",
      filepath,
    }, { text = true }):wait(), "prettier"
  end

  local mdformat = find_executable("mdformat")
  if mdformat then
    return vim.system({
      mdformat,
      "--wrap=80",
      filepath,
    }, { text = true }):wait(), "mdformat"
  end

  return nil, nil
end

local function format_and_reload()
  vim.cmd("write")
  local filepath = vim.fn.expand("%:p")

  if filepath == "" then
    vim.notify("No file to format", vim.log.levels.WARN)
    return
  end

  local result, formatter = run_formatter(filepath)
  if not result then
    vim.notify("No Markdown formatter found. Install prettier (preferred) or mdformat.", vim.log.levels.ERROR)
    return
  end

  if result.code ~= 0 then
    local stderr = (result.stderr or ""):gsub("%s+$", "")
    local message = stderr ~= "" and stderr or ("exit code " .. tostring(result.code))
    vim.notify(("Error running %s: %s"):format(formatter, message), vim.log.levels.ERROR)
    return
  end

  vim.cmd("edit!")
  vim.notify(("File formatted with %s and reloaded"):format(formatter), vim.log.levels.INFO)
end

vim.api.nvim_create_user_command("Mdformat", format_and_reload, {
  desc = "Format Markdown with prettier (fallback: mdformat) and reload",
})
