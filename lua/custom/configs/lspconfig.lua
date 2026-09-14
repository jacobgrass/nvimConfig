local vim = vim

-- Disable LSP file logging: $LOCALAPPDATA/nvim-data/lsp.log can grow unbounded
-- and incurs disk I/O on every LSP message. Re-enable to WARN if debugging.
vim.lsp.log.set_level(vim.log.levels.OFF)

-- Shut down LSP clients that have no attached buffers. lspconfig keeps clients
-- alive for the whole session by default; combined with single_file_support
-- and large LSPs (clangd, omnisharp, ts_ls, gopls), this is a major source of
-- RSS growth on Windows. Run shortly after BufDelete so other plugins finish
-- their bookkeeping first.
vim.api.nvim_create_autocmd("BufDelete", {
  group = vim.api.nvim_create_augroup("JgLspIdleStop", { clear = true }),
  callback = function()
    vim.defer_fn(function()
      for _, client in ipairs(vim.lsp.get_clients()) do
        if vim.tbl_isempty(client.attached_buffers or {}) then
          pcall(function() client:stop() end)
        end
      end
    end, 500)
  end,
})

-- Base capabilities are applied to every server via vim.lsp.config("*") and the
-- base on_attach runs from an LspAttach autocmd (see plugins.configs.lspconfig).
require("plugins.configs.lspconfig")

local uv = vim.uv or vim.loop
local go_format_group = vim.api.nvim_create_augroup("GoLspFormatOnSave", { clear = true })
local html_format_group = vim.api.nvim_create_augroup("HtmlLspFormatOnSave", { clear = true })
local ts_js_format_group = vim.api.nvim_create_augroup("TsJsFormatOnSave", { clear = true })

-- Per-server attach hooks. Kept out of `vim.lsp.config(..., { on_attach })` so
-- nvim-lspconfig's default on_attach for the server (buffer commands such as
-- LspEslintFixAll / LspTypescriptSourceAction / LspClangdSwitchSourceHeader) is preserved.
local attach_hooks = {}

vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("JgLspServerAttach", { clear = true }),
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    local hook = client and attach_hooks[client.name]
    if hook then
      hook(client, args.buf)
    end
  end,
})

local function enable(server, config)
  if config then
    vim.lsp.config(server, config)
  end
  vim.lsp.enable(server)
end

-- root_dir callback from a flat marker list (nearest ancestor containing any marker).
local function root_from_markers(markers)
  return function(bufnr, on_dir)
    on_dir(vim.fs.root(bufnr, markers))
  end
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
  local clients = vim.lsp.get_clients({ bufnr = bufnr, name = "eslint" })
  if #clients == 0 then
    return
  end

  -- nvim-lspconfig registers the buffer-local LspEslintFixAll; older versions used EslintFixAll.
  for _, cmd in ipairs({ "LspEslintFixAll", "EslintFixAll" }) do
    if vim.fn.exists(":" .. cmd) == 2 then
      pcall(vim.cmd, "silent! " .. cmd)
      return
    end
  end
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

local clangd_db = require("custom.clangd_db")

-- root_dir -> compile_commands.json directory (false when clangd should decide)
local clangd_db_by_root = {}
-- root_dir -> argv the running clangd was started with (for :ClangdCompileCommands)
local clangd_argv_by_root = {}

local function clangd_cmd(cc_dir)
  local is_windows = vim.fn.has("win32") ~= 0
  -- Memory-tuned flags for long-running sessions on Windows.
  -- Drop --background-index (kept full project AST in RAM); keep clang-tidy.
  -- Cap parallelism and result counts to bound memory growth.
  local cmd = {
    "clangd",
    "--clang-tidy",
    "--completion-style=detailed",
    "--header-insertion=iwyu",
    "--limit-references=100",
    "--limit-results=20",
    "--pch-storage=memory",
    "-j=2",
  }

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

-- Resolve root + database for a buffer and remember the database per root so
-- the cmd builder (which only sees the root) can pick it up.
local function clangd_resolve(bufnr)
  local root, cc_dir = clangd_db.resolve(bufnr)
  if root then
    clangd_db_by_root[root] = cc_dir or false
  end
  return root, cc_dir
end

local clangd_filetypes = { "c", "cpp", "objc", "objcpp", "cuda" }

-- clangd (C/C++)
-- Set `vim.g.clangd_compile_commands_dir` (absolute, or relative to the
-- workspace root) to pin the database on a machine where auto-detection is
-- wrong. See `custom.clangd_db` for the search rules.
vim.lsp.config("clangd", {
  cmd = function(dispatchers, config)
    local cc_dir = clangd_db_by_root[config.root_dir] or nil
    local argv = clangd_cmd(cc_dir)
    clangd_argv_by_root[config.root_dir] = argv
    return vim.lsp.rpc.start(argv, dispatchers, { cwd = config.cmd_cwd, env = config.cmd_env })
  end,
  root_dir = function(bufnr, on_dir)
    local root = clangd_resolve(bufnr)
    if root then
      on_dir(root)
    end
  end,
  filetypes = clangd_filetypes,
})
vim.lsp.enable("clangd")

vim.api.nvim_create_user_command("ClangdCompileCommands", function()
  local bufnr = vim.api.nvim_get_current_buf()
  local root, cc_dir = clangd_db.resolve(bufnr)
  local lines = {
    "root:              " .. tostring(root),
    "compile_commands:  " .. (cc_dir and (cc_dir .. "/compile_commands.json") or "<none found; clangd default search>"),
  }
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr, name = "clangd" })) do
    lines[#lines + 1] = ("running client %d: root=%s"):format(client.id, client.config.root_dir)
    lines[#lines + 1] = "  cmd: " .. table.concat(clangd_argv_by_root[client.config.root_dir] or { "?" }, " ")
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end, { desc = "Show which compile_commands.json clangd uses for this buffer" })

-- CMake
enable("cmake", {
  init_options = {
    buildDirectory = "build",
  },
})

-- Python
enable("pylsp")

-- Lua: configured in plugins.configs.lspconfig

-- JSON
enable("jsonls")

-- HTML
attach_hooks.html = function(client, bufnr)
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
end
enable("html", {
  filetypes = { "html" },
  init_options = {
    provideFormatter = true,
  },
})

-- TypeScript / JavaScript
local function setup_typescript_lsp()
  local ts_server_bin = find_executable("typescript-language-server")
  if not ts_server_bin then
    vim.notify(
      "typescript-language-server not found. Install it with :MasonInstall typescript-language-server",
      vim.log.levels.WARN
    )
    return
  end

  attach_hooks.ts_ls = function(client, bufnr)
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
  end

  enable("ts_ls", {
    cmd = { ts_server_bin, "--stdio" },
    filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact" },
    root_dir = root_from_markers({ "tsconfig.json", "jsconfig.json", "package.json", ".git" }),
  })
end

setup_typescript_lsp()

-- YAML
enable("yamlls", {
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
enable("bashls")

-- Go
attach_hooks.gopls = function(_, bufnr)
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
end
enable("gopls", {
  filetypes = { "go", "gomod", "gowork", "gotmpl" },
  root_dir = root_from_markers({ "go.work", "go.mod", ".git" }),
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

-- Markdown
enable("marksman", {
  filetypes = { "markdown" },
})

-- Fortran
enable("fortls")

-- Docker
enable("docker_compose_language_service", {
  filetypes = { "yaml" },
})

enable("dockerls", {
  filetypes = { "dockerfile" },
})

-- 󰄳 C# / OmniSharp
attach_hooks.omnisharp = function(_, bufnr)
  -- OmniSharp's formatting capabilities are used by default.
  -- Restart is useful when OmniSharp gets into a weird state.
  vim.keymap.set("n", "<leader>oR", function()
    require("plugins.configs.lspconfig").restart("omnisharp")
    print("OmniSharp server restarted.")
  end, { buffer = bufnr, noremap = true, silent = true, desc = "Restart OmniSharp" })
end
enable("omnisharp", {
  -- Ensure the 'OmniSharp' executable (or omnisharp.sh script) is on PATH.
  cmd = { "OmniSharp", "--languageserver", "--hostPID", tostring(vim.fn.getpid()) },
  filetypes = { "cs", "vb" }, -- C# and VB.NET
  root_dir = function(bufnr, on_dir)
    on_dir(vim.fs.root(bufnr, function(name)
      return name:match("%.sln$") ~= nil or name:match("%.csproj$") ~= nil or name == ".git"
    end))
  end,
  -- Modern .NET features; an omnisharp.json in the project root is also honoured.
  settings = {
    FormattingOptions = {
      OrganizeImports = true,
    },
    RoslynExtensionsOptions = {
      EnableAnalyzersSupport = true,
      EnableImportCompletion = true,
    },
    Sdk = {
      IncludePrereleases = true, -- If you use .NET preview SDKs
    },
  },
})

-- ESLint
attach_hooks.eslint = function(client)
  client.server_capabilities.documentFormattingProvider = false
  client.server_capabilities.documentRangeFormattingProvider = false
end
enable("eslint", {
  filetypes = { "javascript", "javascriptreact", "typescriptreact", "typescript" },
})
