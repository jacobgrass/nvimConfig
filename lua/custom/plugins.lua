local plugins = {
  {
    "williamboman/mason.nvim",
    opts = {
      ensure_installed = {
        -- LSP
        "bash-language-server",
        "clangd",
        "cmake-language-server",
        "json-lsp",
        "lua-language-server",
        "python-lsp-server",
        "yaml-language-server",
        "fortls",
"docker-compose-language-service",
        "dockerfile-language-service",
        "bashls",
        "omnisharp",

        -- DAP
        "codelldb",

        -- Linters
        "cpplint",
        "pylint",
        "cmakelint",
        "protolint",
        "fprettify",

        -- Formatters
        "clang-format",
        "cmakelang", -- Provides cmake-format
        "yamlfmt",
        "buf",

        -- Optional but recommended for CI configuration
        "circleci-yaml-language-server",
        "gitlab-ci-ls",

        -- Markdown
        "marksman",
        "mdformat",
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
    event = "User FilePost",
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
      local base = require("plugins.configs.lspconfig")

      local function merged_capabilities(extra)
        return vim.tbl_deep_extend("force", {}, base.capabilities, extra or {})
      end

      local function compose_on_attach(user_on_attach)
        return function(client, bufnr)
          base.on_attach(client, bufnr)
          if type(user_on_attach) == "function" then
            user_on_attach(client, bufnr)
          end
        end
      end

      require("mason-bridge").setup({
        -- Optional configuration options
        handlers = {
          -- Default handlers
          default = function(config)
            -- clangd is configured explicitly in `custom.configs.lspconfig`
            -- Avoid double-setup / conflicting settings.
            if config.name == "clangd" then
              return
            end
            config.capabilities = merged_capabilities(config.capabilities)
            config.on_attach = compose_on_attach(config.on_attach)
            require("lspconfig")[config.name].setup(config)
          end,
        },
        -- Automatically install LSP servers
        automatic_installation = true,
        -- Optional: List of LSP servers to configure
        servers = {
          -- Example server configurations
          cmake = {},
          lua_ls = {},
          -- Add other servers as needed
        },
      })
    end,
  },
}


return plugins
