-- nvim-treesitter (main branch) configuration.
-- The legacy module API (highlight/indent/folds options on setup()) was removed
-- on the main branch. Highlight is now engaged per-buffer via FileType autocmd,
-- parser installation goes through the install() function.

local M = {}

-- Parsers to keep installed. install() is idempotent and async.
M.ensure_installed = { "c", "cpp", "lua", "vim", "vimdoc", "markdown", "markdown_inline" }

function M.setup()
  -- preserve nvchad/base46 highlight theme load
  pcall(dofile, vim.g.base46_cache .. "syntax")

  local ok, ts = pcall(require, "nvim-treesitter")
  if not ok then
    return
  end

  ts.setup({})

  -- Kick off parser install; safe no-op if already present.
  pcall(ts.install, M.ensure_installed)

  -- Enable treesitter highlight on every buffer whose filetype maps
  -- to an installed parser. On main branch this is not automatic.
  vim.api.nvim_create_autocmd("FileType", {
    group = vim.api.nvim_create_augroup("JgTreesitterStart", { clear = true }),
    callback = function(args)
      local ft = vim.bo[args.buf].filetype
      if not ft or ft == "" then return end
      local lang = vim.treesitter.language.get_lang(ft)
      if not lang then return end
      local ok_add = pcall(vim.treesitter.language.add, lang)
      if not ok_add then return end
      pcall(vim.treesitter.start, args.buf, lang)
    end,
  })
end

return M
