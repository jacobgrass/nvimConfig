local vim = vim
local base = require("plugins.configs.lspconfig")
local on_attach = base.on_attach
local capabilities = base.capabilities

local util = require("lspconfig.util") -- For root_dir patterns
local uv = vim.uv or vim.loop
local ok_lspconfig, lspconfig = pcall(require, "lspconfig")
local go_format_group = vim.api.nvim_create_augroup("GoLspFormatOnSave", { clear = true })
local html_format_group = vim.api.nvim_create_augroup("HtmlLspFormatOnSave", { clear = true })

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

local function format_html_with_prettier(bufnr)
  local prettier = vim.fn.exepath("prettier")
  if prettier == "" then
    vim.notify("prettier not found in PATH", vim.log.levels.WARN)
    return
  end

  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath == "" then
    return
  end

  local plugin_path = vim.fn.stdpath("data")
    .. "/mason/packages/prettier/node_modules/prettier-plugin-organize-attributes/lib/index.js"

  local cmd = {
    prettier,
    "--stdin-filepath",
    filepath,
    "--attribute-sort",
    "ASC",
  }

  if file_exists(plugin_path) then
    table.insert(cmd, "--plugin")
    table.insert(cmd, plugin_path)
  end

  local input = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local result = vim.system(cmd, { stdin = input, text = true }):wait()

  if result.code ~= 0 then
    vim.notify("prettier format failed: " .. (result.stderr or "unknown error"), vim.log.levels.WARN)
    return
  end

  local formatted = result.stdout or ""
  if formatted:sub(-1) == "\n" then
    formatted = formatted:sub(1, -2)
  end

  local new_lines = vim.split(formatted, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
end

vim.api.nvim_create_user_command("HtmlFormat", function()
  format_html_with_prettier(vim.api.nvim_get_current_buf())
end, { desc = "Format HTML with prettier (deterministic attribute order)" })

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
  filetypes = { "typescriptreact","typescript" },

  on_attach = function(client, bufnr)
    on_attach(client, bufnr)
    vim.api.nvim_create_autocmd("BufWritePre", {
      buffer = bufnr,
      command = "EslintFixAll",
    })
  end,
})
