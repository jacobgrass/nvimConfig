local plugins = {
  {
    "williamboman/mason.nvim",
    opts = {
      ensure_installed = {
        "clangd",
        "cmake - language - server",
        "cmakelang",
        "cmakelint",
        "codelldb",
        "cpptools",
        "lua - language - server",
      },
    },
  },
  {
    "mfussenegger/nvim-dap",
    config = function()
      require "custom.configs.dap"
      require("core.utils").load_mappings("dap")
    end,
  },
  {
    "jay-babu/mason-nvim-dap.nvim",
    event = "VeryLazy",
    dependencies = {
      "williamboman/mason.nvim",
      "mfussenegger/nvim-dap",
    },
    opts = {
      handlers = {},
    },
  },

  {
    "neovim/nvim-lspconfig",
    config = function()
      require "plugins.configs.lspconfig"
      require "custom.configs.lspconfig"
    end,
  },
  {
    "rcarriga/nvim-dap-ui",
    event = "VeryLazy",
    dependencies = "mfussenegger/nvim-dap",
    config = function()
      local dap = require("dap")
      local dapui = require("dapui")
      dapui.setup()
      dap.listeners.after.event_initialized["dapui_config"] = function()
        dapui.open()
      end
      dap.listeners.before.event_terminated["dapui_config"] = function()
        dapui.close()
      end
      dap.listeners.before.event_exited["dapui_config"] = function()
        dapui.close()
      end
    end,
  },
  {
    "danymat/neogen",
    config = function()
      require('neogen').setup({})
    end,
    lazy = false
    -- Uncomment next line if you want to follow only stable versions
    -- tag = "*"
  },
   {
    "frostplexx/mason-bridge.nvim",
    dependencies = {
      "williamboman/mason.nvim",
      "neovim/nvim-lspconfig",
    },
    config = function()
      require("mason-bridge").setup({
        -- Optional configuration options
        handlers = {
          -- Default handlers
          default = function(config)
            require("lspconfig")[config.name].setup(config)
          end,
        },
        -- Automatically install LSP servers
        automatic_installation = true,
        -- Optional: List of LSP servers to configure
        servers = {
          -- Example server configurations
          clangd = {},
          cmake = {},
          lua_ls = {},
          -- Add other servers as needed
        },
      })
    end,
  },
}


return plugins
