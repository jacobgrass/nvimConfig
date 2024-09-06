local plugins = {
  {
    {
      "neovim/nvim-lspconfig",
      config = function ()
        require "plugins.configs.lspconfig"
        require "custom.configs.lspconfig"
      end,
    },
    "williamboman/mason.nvim",
    opts ={
      ensure_installed = {
        "clangd"
      }
    },
    {
      "danymat/neogen",
      config = function()
        require('neogen').setup( {})
      end,
      lazy = false
      -- Uncomment next line if you want to follow only stable versions
      -- tag = "*"
    }
  }

}
return plugins
