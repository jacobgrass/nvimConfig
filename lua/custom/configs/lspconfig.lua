local vim = vim
local base = require("plugins.configs.lspconfig")
local on_attach = base.on_attach
local capabilities = base.capabilities

local lspconfig = require("lspconfig")
local util = require("lspconfig.util") -- For root_dir patterns

-- Common root directory function for .NET projects
local csharp_root_dir = function(fname)
  return util.root_pattern("*.sln", "*.csproj", ".git")(fname)
end

-- Existing clangd setup
lspconfig.clangd.setup {
  cmd = {
    "clangd",
    "--compile-commands-dir=build",
    "--query-driver=/usr/bin/gcc"
  },
  on_attach = function(client, bufnr)
    -- client.server_capabilities.signatureHelpProvider = false
    on_attach(client, bufnr)
    -- Disable diagnostics for proto files
    if vim.bo[bufnr].filetype == "proto" then
      vim.diagnostic.disable(bufnr)
    end
  end,
  capabilities = capabilities,
  filetypes = { "c", "cpp", "objc", "objcpp", "cuda", "proto", "javascript" },
}

-- Add CMAKE setup
lspconfig.cmake.setup {
  on_attach = on_attach,
  capabilities = capabilities,
  filetypes = { "cmake", "CMakeLists.txt" },
  init_options = {
    buildDirectory = "build",
  },
}

-- Python
lspconfig.pylsp.setup {
  on_attach = on_attach,
  capabilities = capabilities,
}

-- Lua
lspconfig.lua_ls.setup {
  on_attach = on_attach,
  capabilities = capabilities,
}

-- JSON
lspconfig.jsonls.setup {
  on_attach = on_attach,
  capabilities = capabilities,
}

-- YAML
lspconfig.yamlls.setup {
  on_attach = on_attach,
  capabilities = capabilities,
  settings = {
    yaml = {
      schemas = {
        ["https://json.schemastore.org/github-workflow.json"] = "/.github/workflows/*",
        ["https://gitlab.com/gitlab-org/gitlab/-/raw/master/app/assets/javascripts/editor/schema/ci.json"] = "/.gitlab-ci.yml",
      },
    },
  },
}

-- Bash
lspconfig.bashls.setup {
  on_attach = on_attach,
  capabilities = capabilities,
}

lspconfig.marksman.setup {
  on_attach = on_attach,
  capabilities = capabilities,
}

-- Fortran
lspconfig.fortls.setup {
  on_attach = on_attach,
  capabilities = capabilities,
}

lspconfig.docker_compose_language_service.setup {
  on_attach = on_attach,
  capabilities = capabilities,
  filetypes = { "docker-compose.yml" },
}

lspconfig.dockerls.setup {
  on_attach = on_attach,
  capabilities = capabilities,
  filetypes = { "dockerfile" },
}

-- 󰄳 C# / OmniSharp
lspconfig.omnisharp.setup {
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
  cmd = { "omnisharp", "--languageserver", "--hostPID", tostring(vim.v.pproccessid or vim.fn.getpid()) },
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
}
