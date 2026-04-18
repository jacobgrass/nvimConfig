-- Startup perf: enable Lua module loader cache (Neovim >= 0.9)
pcall(function()
  if vim.loader then
    vim.loader.enable()
  end
end)

require "core"

vim.filetype.add({
  extension = {
    mdx = "markdown.mdx",
  },
  filename = {
    ["docker-compose.yml"] = "yaml.docker-compose",
    ["docker-compose.yaml"] = "yaml.docker-compose",
  },
  pattern = {
    [".*%.gitlab%-ci%.ya?ml"] = "yaml.gitlab",
    [".*helm%-values%.ya?ml"] = "yaml.helm-values",
  },
})

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


if vim.fn.has("win32") == 1 then
  opt.shell = "powershell.exe"
  opt.shellcmdflag = "-NoLogo -NoProfile -ExecutionPolicy RemoteSigned -Command"
  opt.shellredir = "2>&1 | Out-File -Encoding UTF8 %s"
  opt.shellpipe = "2>&1 | Out-File -Encoding UTF8 %s"
  opt.shellquote = ""
  opt.shellxquote = ""
end


-- Treesitter-based folding (works even when nvim-treesitter is lazy-loaded)
-- Uses the built-in foldexpr in Neovim 0.11+ (does not depend on Vimscript funcs).
-- IMPORTANT: do NOT call vim.treesitter.get_parser here — it *creates* a parser,
-- which keeps memory attached to every buffer ever opened. Instead, only set
-- foldexpr when a parser language is registered for the filetype, and let
-- nvim-treesitter's own highlighter own the parser lifecycle.
vim.api.nvim_create_autocmd({ "FileType" }, {
  group = vim.api.nvim_create_augroup("JgTreesitterFolds", { clear = true }),
  callback = function(args)
    local ft = vim.bo[args.buf].filetype
    if ft == "" then return end
    local lang = vim.treesitter.language.get_lang(ft)
    if not lang then return end
    -- Don't trigger parser allocation; just confirm a parser file exists.
    local has_parser = pcall(vim.treesitter.language.add, lang)
    if not has_parser then return end
    for _, win in ipairs(vim.fn.win_findbuf(args.buf)) do
      vim.wo[win].foldmethod = "expr"
      vim.wo[win].foldexpr = "v:lua.vim.treesitter.foldexpr()"
      vim.wo[win].foldlevel = 99
    end
  end,
})

-- Memory probe: <leader>mm prints process + Lua memory + LSP/buffer counts.
vim.keymap.set("n", "<leader>mm", function()
  collectgarbage("collect")
  local rss_mb = (vim.uv or vim.loop).resident_set_memory() / 1024 / 1024
  local lua_kb = collectgarbage("count")
  print(string.format("nvim RSS %.0f MB | Lua %.1f MB | LSPs %d | bufs %d",
    rss_mb, lua_kb / 1024, #vim.lsp.get_clients(), #vim.api.nvim_list_bufs()))
end, { desc = "Memory snapshot" })
opt.rnu = true

require("custom.create_definition")
require("custom.create_getters_setters_cpp")
require("custom.mdformat")
require("custom.fortranformat")
require("custom.latex_indent")
require("custom.reorganize_cpp")
