dofile(vim.g.base46_cache .. "lsp")

local M = {}
local utils = require "core.utils"
local config = utils.load_config()

-- Diagnostics UI (replaces `nvchad.lsp`, which relied on the removed vim.lsp.with()).
local severity = vim.diagnostic.severity
vim.diagnostic.config {
  virtual_text = { prefix = "" },
  signs = {
    text = {
      [severity.ERROR] = "󰅙",
      [severity.WARN] = "",
      [severity.INFO] = "󰋼",
      [severity.HINT] = "󰌵",
    },
    numhl = {
      [severity.ERROR] = "DiagnosticSignError",
      [severity.WARN] = "DiagnosticSignWarn",
      [severity.INFO] = "DiagnosticSignInfo",
      [severity.HINT] = "DiagnosticSignHint",
    },
  },
  underline = true,
  update_in_insert = false,
}

-- Float styling for hover / signature help; passed to vim.lsp.buf.* by the mappings.
M.hover_opts = { border = "single" }
M.signature_opts = { border = "single", focusable = false, relative = "cursor" }

-- Start/stop/restart helpers that work on Neovim 0.12 (built-in `:lsp`, where
-- nvim-lspconfig no longer defines :LspStart/:LspStop) and on older versions.
M.stop_buffer_clients = function(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local clients = vim.lsp.get_clients { bufnr = bufnr }
  for _, client in ipairs(clients) do
    client:stop()
  end
  vim.notify(("Stopped %d LSP client(s)"):format(#clients), vim.log.levels.INFO)
end

M.start_buffer_clients = function(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if vim.fn.exists ":LspStart" == 2 then
    vim.cmd.LspStart()
    return
  end
  -- Re-run the FileType hook installed by vim.lsp.enable() for this buffer.
  local ok = pcall(vim.api.nvim_exec_autocmds, "FileType", { group = "nvim.lsp.enable", buffer = bufnr })
  if ok then
    vim.notify("LSP started for current filetype", vim.log.levels.INFO)
  else
    vim.notify("No enabled LSP configs found (vim.lsp.enable hook missing)", vim.log.levels.WARN)
  end
end

M.restart = function(name)
  if vim.fn.exists ":lsp" == 2 then
    vim.cmd("lsp restart " .. name)
  elseif vim.fn.exists ":LspRestart" == 2 then
    vim.cmd.LspRestart(name)
  else
    for _, client in ipairs(vim.lsp.get_clients { name = name }) do
      client:stop()
    end
    M.start_buffer_clients()
  end
end

if not config.ui.lsp_semantic_tokens and vim.lsp.semantic_tokens and vim.lsp.semantic_tokens.enable then
  vim.lsp.semantic_tokens.enable(false)
end

-- Signature help as you type (replaces `nvchad.signature`, which relied on
-- vim.lsp.with() and vim.lsp.get_active_clients()).
local signature_cfg = (config.ui.lsp or {}).signature or {}
local signature_group = vim.api.nvim_create_augroup("LspSignature", { clear = true })

local function trigger_char_typed(line_to_cursor, triggers)
  local current_char = line_to_cursor:sub(-1)
  local prev_char = line_to_cursor:sub(-2, -2)
  for _, trigger in ipairs(triggers) do
    if current_char == trigger or (current_char == " " and prev_char == trigger) then
      return true
    end
  end
  return false
end

local function setup_signature(bufnr)
  if signature_cfg.disabled then
    return
  end
  vim.api.nvim_clear_autocmds { group = signature_group, buffer = bufnr }
  vim.api.nvim_create_autocmd("TextChangedI", {
    group = signature_group,
    buffer = bufnr,
    callback = function()
      local pos = vim.api.nvim_win_get_cursor(0)
      local line_to_cursor = vim.api.nvim_get_current_line():sub(1, pos[2])
      for _, client in ipairs(vim.lsp.get_clients { bufnr = bufnr, method = "textDocument/signatureHelp" }) do
        local provider = client.server_capabilities.signatureHelpProvider or {}
        if trigger_char_typed(line_to_cursor, provider.triggerCharacters or {}) then
          vim.lsp.buf.signature_help(vim.tbl_extend("force", M.signature_opts, {
            silent = signature_cfg.silent,
            anchor_bias = "above",
          }))
          return
        end
      end
    end,
  })
end

M.on_attach = function(client, bufnr)
  utils.load_mappings("lspconfig", { buffer = bufnr })

  if client.server_capabilities.signatureHelpProvider then
    setup_signature(bufnr)
  end
end

M.capabilities = vim.lsp.protocol.make_client_capabilities()

M.capabilities.textDocument.completion.completionItem = {
  documentationFormat = { "markdown", "plaintext" },
  snippetSupport = true,
  preselectSupport = true,
  insertReplaceSupport = true,
  labelDetailsSupport = true,
  deprecatedSupport = true,
  commitCharactersSupport = true,
  tagSupport = { valueSet = { 1 } },
  resolveSupport = {
    properties = {
      "documentation",
      "detail",
      "additionalTextEdits",
    },
  },
}

-- Apply to every server, without clobbering the per-server `on_attach` that
-- nvim-lspconfig's defaults register (e.g. LspClangdSwitchSourceHeader).
vim.lsp.config("*", { capabilities = M.capabilities })

vim.api.nvim_create_autocmd("LspAttach", {
  group = vim.api.nvim_create_augroup("BaseLspAttach", { clear = true }),
  callback = function(args)
    local client = vim.lsp.get_client_by_id(args.data.client_id)
    if client then
      M.on_attach(client, args.buf)
    end
  end,
})

vim.lsp.config("lua_ls", {
  settings = {
    Lua = {
      diagnostics = {
        globals = { "vim" },
      },
      workspace = {
        library = {
          [vim.fn.expand "$VIMRUNTIME/lua"] = true,
          [vim.fn.expand "$VIMRUNTIME/lua/vim/lsp"] = true,
          [vim.fn.stdpath "data" .. "/lazy/ui/nvchad_types"] = true,
          [vim.fn.stdpath "data" .. "/lazy/lazy.nvim/lua/lazy"] = true,
        },
        maxPreload = 100000,
        preloadFileSize = 10000,
      },
    },
  },
})
vim.lsp.enable("lua_ls")

return M
