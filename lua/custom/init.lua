-- Loaded by the repo-root init.lua (dofile) before plugins are set up.

-- Markdown pipe tables: wrapped, in-place editable grid (lua/custom/mdtable).
vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("JgMdTable", { clear = true }),
  pattern = { "markdown", "markdown.mdx" },
  callback = function(ev)
    require("custom.mdtable").attach(ev.buf)
  end,
})
pcall(require, "custom.mdtable.celledit") -- floating cell editor: :MdTableCellEdit, <leader>te
