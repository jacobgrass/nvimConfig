---@type ChadrcConfig
local M = {}

M.ui = { theme = 'everforest' }
M.plugins = "custom.plugins"

local vim = vim
local opt = vim.opt

opt.foldmethod = "expr"
opt.foldexpr = "nvim_treesitter#foldexpr()"

return M

