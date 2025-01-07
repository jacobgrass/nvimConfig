local base = require("plugins.configs.lspconfig")
local on_attach = base.on_attach
local capabilities = base.capabilities

local lspconfig = require("lspconfig")

-- Existing clangd setup
lspconfig.clangd.setup {
  on_attach = function(client, bufnr)
    -- client.server_capabilities.signatureHelpProvider = false
    on_attach(client, bufnr)
    -- Disable diagnostics for proto files
    if vim.bo[bufnr].filetype == "proto" then
      vim.diagnostic.disable(bufnr)
    end
  end,
  capabilities = capabilities,
  filetypes = { "c", "cpp", "objc", "objcpp", "cuda", "proto" },
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

-- lspconfig.mdformat.setup {
--   on_attach = on_attach,
--   capabilities = capabilities,
-- }

-- Fortran
lspconfig.fortls.setup {
  on_attach = on_attach,
  capabilities = capabilities,
}
