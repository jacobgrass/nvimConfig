local is_windows = vim.fn.has("win32") == 1

-- Windows: nvim-tree creates one fs_event watcher per visible directory and
-- leaks native memory under heavy file churn (builds, git operations) — RSS
-- grows ~linearly with every event storm and is never released, eventually
-- OOMing long sessions. Upstream: nvim-tree/nvim-tree.lua#3292 (open).
-- Watchers stay enabled on Linux/macOS where inotify/kqueue behave.
if is_windows then
  local pending = false
  vim.api.nvim_create_autocmd({ "BufWritePost", "FocusGained", "TermLeave", "DirChanged" }, {
    group = vim.api.nvim_create_augroup("NvimTreeManualRefresh", { clear = true }),
    callback = function()
      if pending then
        return
      end
      pending = true
      vim.defer_fn(function()
        pending = false
        local ok, api = pcall(require, "nvim-tree.api")
        if ok and api.tree.is_visible() then
          api.tree.reload()
        end
      end, 500)
    end,
  })
end

local options = {
  filters = {
    dotfiles = false,
    exclude = { vim.fn.stdpath "config" .. "/lua/custom" },
  },
  disable_netrw = true,
  hijack_netrw = true,
  hijack_cursor = true,
  hijack_unnamed_buffer_when_opening = false,
  sync_root_with_cwd = true,
  update_focused_file = {
    enable = true,
    update_root = false,
  },
  view = {
    adaptive_size = false,
    side = "left",
    width = 30,
    preserve_window_proportions = true,
  },
  git = {
    enable = false,
    ignore = true,
  },
  filesystem_watchers = {
    enable = not is_windows,
    -- keep watcher counts down where they remain enabled
    ignore_dirs = { "node_modules", "\\.cache", "build", "target" },
  },
  actions = {
    open_file = {
      resize_window = true,
    },
  },
  renderer = {
    root_folder_label = false,
    highlight_git = false,
    highlight_opened_files = "none",

    indent_markers = {
      enable = false,
    },

    icons = {
      show = {
        file = true,
        folder = true,
        folder_arrow = true,
        git = false,
      },

      glyphs = {
        default = "󰈚",
        symlink = "",
        folder = {
          default = "",
          empty = "",
          empty_open = "",
          open = "",
          symlink = "",
          symlink_open = "",
          arrow_open = "",
          arrow_closed = "",
        },
        git = {
          unstaged = "✗",
          staged = "✓",
          unmerged = "",
          renamed = "➜",
          untracked = "★",
          deleted = "",
          ignored = "◌",
        },
      },
    },
  },
}

return options
