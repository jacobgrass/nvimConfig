local base = require("plugins.configs.lspconfig")
local on_attach = base.on_attach
local capabilities = base.capabilities

local lspconfig = require("lspconfig")

-- Existing clangd setup
lspconfig.clangd.setup {
  on_attach = function(client, bufnr)
    client.server_capabilities.signatureHelpProvider = false
    on_attach(client, bufnr)
  end,
  capabilities = capabilities,
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

