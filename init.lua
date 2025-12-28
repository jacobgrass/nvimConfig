-- Startup perf: enable Lua module loader cache (Neovim >= 0.9)
pcall(function()
  if vim.loader then
    vim.loader.enable()
  end
end)

require "core"

local custom_init_path = vim.api.nvim_get_runtime_file("lua/custom/init.lua", false)[1]

if custom_init_path then
  dofile(custom_init_path)
end

require("core.utils").load_mappings()

local lazypath = vim.fn.stdpath "data" .. "/lazy/lazy.nvim"

-- bootstrap lazy.nvim!
if not vim.loop.fs_stat(lazypath) then
  require("core.bootstrap").gen_chadrc_template()
  require("core.bootstrap").lazy(lazypath)
end

dofile(vim.g.base46_cache .. "defaults")
vim.opt.rtp:prepend(lazypath)
require "plugins"
local vim = vim
local opt = vim.opt

-- Treesitter-based folding (works even when nvim-treesitter is lazy-loaded)
-- Uses the built-in foldexpr in Neovim 0.11+ (does not depend on Vimscript funcs).
vim.api.nvim_create_autocmd({ "FileType" }, {
  group = vim.api.nvim_create_augroup("JgTreesitterFolds", { clear = true }),
  callback = function(args)
    local ok = pcall(vim.treesitter.get_parser, args.buf)
    if ok then
      -- NOTE: foldmethod/foldexpr/foldlevel are window-local, not buffer-local.
      -- Apply to every window currently showing this buffer.
      for _, win in ipairs(vim.fn.win_findbuf(args.buf)) do
        vim.wo[win].foldmethod = "expr"
        vim.wo[win].foldexpr = "v:lua.vim.treesitter.foldexpr()"
        -- keep files mostly unfolded by default; use zM/zR to close/open all
        vim.wo[win].foldlevel = 99
      end
    end
  end,
})
opt.rnu = true

require("custom.create_definition")
require("custom.create_getters_setters_cpp")
require("custom.mdformat")
require("custom.fortranformat")
require("custom.latex_indent")
require("custom.reorganize_cpp")
