-- nvim-treesitter (master branch) configuration.
-- master is the branch that supports Neovim 0.11. The main branch requires
-- Neovim 0.12+ and fails silently here: its installer dies inside an async
-- task on vim.list.unique (a 0.12 API), so no parser or query ever lands in
-- install_dir. Buffers then get a highlighter with zero rules -- parsed, but
-- completely uncolored. Keep this on master until Neovim itself is upgraded.
local options = {
  ensure_installed = {
    -- nvim itself
    "lua",
    "luadoc",
    "vim",
    "vimdoc",
    "query",
    -- c family (clangd, cmake)
    "c",
    "cpp",
    "cuda",
    "cmake",
    "make",
    -- python (pylsp)
    "python",
    -- web (ts_ls, html, jsonls)
    "html",
    "css",
    "javascript",
    "typescript",
    "tsx",
    "json",
    "jsonc",
    -- go (gopls)
    "go",
    "gomod",
    "gosum",
    "gowork",
    "gotmpl",
    -- shell, config, docs
    "bash",
    "yaml",
    "toml",
    "markdown",
    "markdown_inline",
    "dockerfile",
    -- fortran (fortls)
    "fortran",
    -- misc
    "diff",
    "gitcommit",
    "gitignore",
    "regex",
    "printf",
  },

  highlight = {
    enable = true,
    use_languagetree = true,
  },

  -- Left off deliberately: treesitter indent would override the built-in
  -- indenting this config already tunes (see custom/latex_indent.lua and
  -- custom/fortranformat.lua). Enabling it is a separate decision.
  indent = { enable = false },
}

return options
