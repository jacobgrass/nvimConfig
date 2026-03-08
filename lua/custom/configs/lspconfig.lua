local vim = vim
local base = require("plugins.configs.lspconfig")
local on_attach = base.on_attach
local capabilities = base.capabilities

local util = require("lspconfig.util") -- For root_dir patterns
local uv = vim.uv or vim.loop
local ok_lspconfig, lspconfig = pcall(require, "lspconfig")
local go_format_group = vim.api.nvim_create_augroup("GoLspFormatOnSave", { clear = true })
local html_format_group = vim.api.nvim_create_augroup("HtmlLspFormatOnSave", { clear = true })
local ts_js_format_group = vim.api.nvim_create_augroup("TsJsFormatOnSave", { clear = true })

local function setup(server, config)
  if ok_lspconfig and lspconfig[server] and type(lspconfig[server].setup) == "function" then
    lspconfig[server].setup(config)
    return
  end

  if type(vim.lsp.config) == "function" and type(vim.lsp.enable) == "function" then
    vim.lsp.config(server, config)
    vim.lsp.enable(server)
    return
  end

  vim.notify(("Unable to configure LSP server '%s'"):format(server), vim.log.levels.ERROR)
end

-- Common root directory function for .NET projects
local csharp_root_dir = function(fname)
  return util.root_pattern("*.sln", "*.csproj", ".git")(fname)
end

local function file_exists(path)
  return path and uv.fs_stat(path) ~= nil
end

local function find_executable(name)
  local path = vim.fn.exepath(name)
  if path ~= "" then
    return path
  end

  local is_windows = vim.fn.has("win32") == 1
  local mason_data = vim.fn.stdpath("data") .. "/mason/"
  local mason_bin = mason_data .. "bin/"
  local candidates = { mason_bin .. name }

  if is_windows then
    table.insert(candidates, mason_bin .. name .. ".cmd")
    table.insert(candidates, mason_bin .. name .. ".exe")
  end

  -- Some npm-based Mason packages expose the executable only in package-local .bin.
  local mason_pkg_bin = mason_data .. "packages/" .. name .. "/node_modules/.bin/" .. name
  table.insert(candidates, mason_pkg_bin)
  if is_windows then
    table.insert(candidates, mason_pkg_bin .. ".cmd")
    table.insert(candidates, mason_pkg_bin .. ".exe")
  end

  for _, candidate in ipairs(candidates) do
    if file_exists(candidate) then
      return candidate
    end
  end

  return nil
end

local function format_with_prettier(bufnr, extra_args)
  local prettier = find_executable("prettier")
  if not prettier then
    vim.notify("prettier not found (PATH or Mason bin)", vim.log.levels.WARN)
    return false
  end

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then
    return false
  end

  local cmd = {
    prettier,
    "--stdin-filepath",
    filepath,
  }

  if type(extra_args) == "table" and #extra_args > 0 then
    vim.list_extend(cmd, extra_args)
  end

  local input = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local result = vim.system(cmd, { stdin = input, text = true }):wait()

  if result.code ~= 0 then
    local stderr = (result.stderr or "unknown error"):gsub("%s+$", "")
    vim.notify("prettier format failed: " .. stderr, vim.log.levels.WARN)
    return false
  end

  local formatted = result.stdout or ""
  if formatted:sub(-1) == "\n" then
    formatted = formatted:sub(1, -2)
  end

  local new_lines = formatted == "" and { "" } or vim.split(formatted, "\n", { plain = true })
  local view = vim.fn.winsaveview()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
  vim.fn.winrestview(view)
  return true
end

local function format_html_with_prettier(bufnr)
  local plugin_path = vim.fn.stdpath("data")
    .. "/mason/packages/prettier/node_modules/prettier-plugin-organize-attributes/lib/index.js"

  local extra_args = {
    "--attribute-sort",
    "ASC",
  }

  if file_exists(plugin_path) then
    table.insert(extra_args, "--plugin")
    table.insert(extra_args, plugin_path)
  end

  return format_with_prettier(bufnr, extra_args)
end

local js_ts_filetypes = {
  javascript = true,
  javascriptreact = true,
  typescript = true,
  typescriptreact = true,
}

local function is_js_ts_filetype(filetype)
  return js_ts_filetypes[filetype] == true
end

local function run_eslint_fix_all(bufnr)
  if vim.fn.exists(":EslintFixAll") ~= 2 then
    return
  end

  local clients = vim.lsp.get_clients({ bufnr = bufnr, name = "eslint" })
  if #clients == 0 then
    return
  end

  pcall(vim.cmd, "silent! EslintFixAll")
end

local function format_ts_js_with_prettier(bufnr)
  return format_with_prettier(bufnr)
end

vim.api.nvim_create_user_command("HtmlFormat", function()
  format_html_with_prettier(vim.api.nvim_get_current_buf())
end, { desc = "Format HTML with prettier (deterministic attribute order)" })

vim.api.nvim_create_user_command("TsJsFormat", function()
  local bufnr = vim.api.nvim_get_current_buf()
  local filetype = vim.bo[bufnr].filetype

  if not is_js_ts_filetype(filetype) then
    vim.notify(("TsJsFormat is only for JS/TS buffers (current: %s)"):format(filetype), vim.log.levels.INFO)
    return
  end

  run_eslint_fix_all(bufnr)
  format_ts_js_with_prettier(bufnr)
end, { desc = "Format JS/TS with eslint fixes + prettier" })

local function find_compile_commands_dir(root)
  if not root or root == "" then
    return nil
  end

  -- Allow manual override per-machine if needed
  if type(vim.g.clangd_compile_commands_dir) == "string" and vim.g.clangd_compile_commands_dir ~= "" then
    local overridden = util.path.join(root, vim.g.clangd_compile_commands_dir)
    if file_exists(util.path.join(overridden, "compile_commands.json")) then
      return overridden
    end
  end

  if file_exists(util.path.join(root, "compile_commands.json")) then
    return root
  end

  -- Common build dirs across Linux + Windows + CMake presets
  local candidates = {
    { "build" },
    { "Build" },
    { "out", "build" },
    { "cmake-build-debug" },
    { "cmake-build-release" },
    { "build", "Debug" },
    { "build", "Release" },
    { "build", "RelWithDebInfo" },
    { "build", "MinSizeRel" },
    -- Common CMake presets naming
    { "build", "x64-Debug" },
    { "build", "x64-Release" },
  }

  for _, parts in ipairs(candidates) do
    local dir = util.path.join(root, unpack(parts))
    if file_exists(util.path.join(dir, "compile_commands.json")) then
      return dir
    end
  end

  return nil
end

local function clangd_cmd(root)
  local is_windows = vim.fn.has("win32") ~= 0
  local cmd = {
    "clangd",
    "--background-index",
    "--clang-tidy",
    "--completion-style=detailed",
    "--header-insertion=iwyu",
  }

  local cc_dir = find_compile_commands_dir(root)
  if cc_dir then
    table.insert(cmd, "--compile-commands-dir=" .. cc_dir)
  end

  if is_windows then
    -- Help clangd trust/understand GCC/Clang-family drivers on Windows where used.
    -- (MSVC projects should already be covered via compile_commands.json.)
    table.insert(
      cmd,
      "--query-driver=C:/Program Files/LLVM/bin/clang*.exe,C:/mingw64/bin/*g++.exe,C:/mingw64/bin/*gcc.exe"
    )
  else
    table.insert(
      cmd,
      "--query-driver=/usr/bin/clang*,/usr/bin/gcc*,/usr/bin/g++*,/usr/local/bin/clang*,/usr/local/bin/gcc*,/usr/local/bin/g++*"
    )
  end

  return cmd
end

-- clangd (C/C++)
setup("clangd", {
  root_dir = function(fname)
    return util.root_pattern("compile_commands.json", "compile_flags.txt", "CMakeLists.txt", ".git")(fname)
  end,
  on_new_config = function(new_config, root_dir)
    new_config.cmd = clangd_cmd(root_dir)
  end,
  on_attach = on_attach,
  capabilities = capabilities,
  filetypes = { "c", "cpp", "objc", "objcpp", "cuda" },
})

-- Add CMAKE setup
setup("cmake", {
  on_attach = on_attach,
  capabilities = capabilities,
  init_options = {
    buildDirectory = "build",
  },
})

-- Python
setup("pylsp", {
  on_attach = on_attach,
  capabilities = capabilities,
})

-- Lua
setup("lua_ls", {
  on_attach = on_attach,
  capabilities = capabilities,
})

-- JSON
setup("jsonls", {
  on_attach = on_attach,
  capabilities = capabilities,
})

-- HTML
setup("html", {
  on_attach = function(client, bufnr)
    on_attach(client, bufnr)
    client.server_capabilities.documentFormattingProvider = false

    vim.api.nvim_clear_autocmds { group = html_format_group, buffer = bufnr }
    vim.api.nvim_create_autocmd("BufWritePre", {
      group = html_format_group,
      buffer = bufnr,
      callback = function()
        format_html_with_prettier(bufnr)
      end,
      desc = "Format HTML files with prettier before save",
    })
  end,
  capabilities = capabilities,
  filetypes = { "html" },
  init_options = {
    provideFormatter = true,
  },
})

local function setup_typescript_lsp()
  local server_name = "ts_ls"
  if ok_lspconfig then
    if lspconfig.ts_ls and type(lspconfig.ts_ls.setup) == "function" then
      server_name = "ts_ls"
    elseif lspconfig.tsserver and type(lspconfig.tsserver.setup) == "function" then
      server_name = "tsserver"
    else
      vim.notify("TypeScript LSP unavailable (missing ts_ls/tsserver config)", vim.log.levels.WARN)
      return
    end
  end

  local ts_server_bin = find_executable("typescript-language-server")
  if not ts_server_bin then
    vim.notify(
      "typescript-language-server not found. Install it with :MasonInstall typescript-language-server",
      vim.log.levels.WARN
    )
    return
  end

  setup(server_name, {
    cmd = { ts_server_bin, "--stdio" },
    on_attach = function(client, bufnr)
      on_attach(client, bufnr)
      client.server_capabilities.documentFormattingProvider = false
      client.server_capabilities.documentRangeFormattingProvider = false

      vim.api.nvim_clear_autocmds { group = ts_js_format_group, buffer = bufnr }
      vim.api.nvim_create_autocmd("BufWritePre", {
        group = ts_js_format_group,
        buffer = bufnr,
        callback = function()
          run_eslint_fix_all(bufnr)
          format_ts_js_with_prettier(bufnr)
        end,
        desc = "Format JS/TS files with prettier before save",
      })
    end,
    capabilities = capabilities,
    filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact" },
    root_dir = util.root_pattern("tsconfig.json", "jsconfig.json", "package.json", ".git"),
    single_file_support = true,
  })
end

setup_typescript_lsp()

-- YAML
setup("yamlls", {
  on_attach = on_attach,
  capabilities = capabilities,
  filetypes = { "yaml" },
  settings = {
    yaml = {
      schemas = {
        ["https://json.schemastore.org/github-workflow.json"] = "/.github/workflows/*",
        ["https://gitlab.com/gitlab-org/gitlab/-/raw/master/app/assets/javascripts/editor/schema/ci.json"] = "/.gitlab-ci.yml",
      },
    },
  },
})

-- Bash
setup("bashls", {
  on_attach = on_attach,
  capabilities = capabilities,
})

-- Go
setup("gopls", {
  on_attach = function(client, bufnr)
    on_attach(client, bufnr)

    vim.api.nvim_clear_autocmds { group = go_format_group, buffer = bufnr }
    vim.api.nvim_create_autocmd("BufWritePre", {
      group = go_format_group,
      buffer = bufnr,
      callback = function()
        vim.lsp.buf.format({
          bufnr = bufnr,
          async = false,
          timeout_ms = 3000,
          filter = function(format_client)
            return format_client.name == "gopls"
          end,
        })
      end,
      desc = "Format Go files with gopls before save",
    })
  end,
  capabilities = capabilities,
  filetypes = { "go", "gomod", "gowork", "gotmpl" },
  root_dir = util.root_pattern("go.work", "go.mod", ".git"),
  settings = {
    gopls = {
      gofumpt = true,
      usePlaceholders = true,
      completeUnimported = true,
      analyses = {
        unusedparams = true,
      },
      staticcheck = true,
    },
  },
})

setup("marksman", {
  on_attach = on_attach,
  capabilities = capabilities,
  filetypes = { "markdown" },
})

-- Fortran
setup("fortls", {
  on_attach = on_attach,
  capabilities = capabilities,
})

setup("docker_compose_language_service", {
  on_attach = on_attach,
  capabilities = capabilities,
  filetypes = { "yaml" },
})

setup("dockerls", {
  on_attach = on_attach,
  capabilities = capabilities,
  filetypes = { "dockerfile" },
})

-- 󰄳 C# / OmniSharp
setup("omnisharp", {
  on_attach = function(client, bufnr)
    on_attach(client, bufnr) -- Call your base on_attach

    -- OmniSharp's formatting capabilities will be used by default.
    -- No need to disable them if you are not using a separate formatter like csharpier.

    -- You can add other C# specific keymaps or settings here if needed.
    -- Example: OmniSharp specific command for restarting the server
    -- This is often useful if OmniSharp gets into a weird state.
    vim.keymap.set("n", "<leader>oR", function()
      vim.cmd.OmniSharpRestartServer()
      print("OmniSharp server restarted.")
    end, { buffer = bufnr, noremap = true, silent = true, desc = "Restart OmniSharp" })
  end,
  capabilities = capabilities,
  -- The cmd might be automatically handled if you use mason-lspconfig.
  -- If omnisharp is in your PATH, this (or lspconfig's default) should work.
  -- Ensure 'omnisharp' executable (or omnisharp.sh script) is found.
  cmd = { "OmniSharp", "--languageserver", "--hostPID", tostring(vim.fn.getpid()) },
  filetypes = { "cs", "vb" }, -- C# and VB.NET
  root_dir = csharp_root_dir,
  -- Enable modern .NET features. These are often defaults in newer omnisharp-roslyn but explicit can be good.
  enable_roslyn_analyzers = true,
  organize_imports_on_format = true,
  enable_import_completion = true,
  sdk_include_prereleases = true, -- If you use .NET preview SDKs

  -- If you have an omnisharp.json in your project root, OmniSharp will pick up settings from there.
  -- For example, to specify a target .NET SDK version or formatting options:
  -- {
  --   "FormattingOptions": {
  --     "EnableEditorConfigSupport": true, // Recommended
  --     "OrganizeImports": true
  --   }
  -- }
})

setup("eslint", {
  capabilities = capabilities,
  filetypes = { "javascript", "javascriptreact", "typescriptreact", "typescript" },

  on_attach = function(client, bufnr)
    on_attach(client, bufnr)
    client.server_capabilities.documentFormattingProvider = false
    client.server_capabilities.documentRangeFormattingProvider = false
  end,
})
