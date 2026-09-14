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
        "html-lsp",
        "lua-language-server",
        "python-lsp-server",
        "yaml-language-server",
        "fortls",
        "docker-compose-language-service",
        "dockerfile-language-service",
        "typescript-language-server",
        "eslint-lsp",
        "bashls",
        "omnisharp",
        "gopls",

        -- DAP
        "codelldb",
        "delve",

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
        "goimports",
        "gofumpt",
        "prettier",
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
      -- mason-bridge only maps filetypes to Mason-installed formatters/linters
      -- (it has no `handlers`/`servers` options); LSP servers are configured in
      -- `custom.configs.lspconfig` via vim.lsp.config.
      require("mason-bridge").setup({})
    end,
  },
  {
    "echasnovski/mini.icons",
    event = "VeryLazy",
    opts = {},
  },
}


return plugins
