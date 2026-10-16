-- nvim -l tmux_check.lua CAPTURE... : alignment check (screen.lua's S.check)
-- on tmux captures; prints one line per capture and exits non-zero on errors.
-- A capture without a rendered table is a FAIL unless its name contains
-- "notable"; an ABORT marker in the capture directory is a FAIL.
local here = vim.fn.fnamemodify(_G.arg[0], ":p:h")
local S = dofile(here .. "/screen.lua")
local bad = 0
for _, f in ipairs(_G.arg) do
  if vim.fn.filereadable(vim.fn.fnamemodify(f, ":h") .. "/ABORT") == 1 and not _G.ABORT_SEEN then
    _G.ABORT_SEEN = true
    print("FAIL ABORT: " .. table.concat(vim.fn.readfile(vim.fn.fnamemodify(f, ":h") .. "/ABORT"), " "))
    bad = bad + 1
  end
  if not f:find("messages") then
    local rows = vim.fn.readfile(f)
    rows[#rows], rows[#rows - 1] = nil, nil -- statusline (laststatus=3) and command line
    local gutter = tonumber(os.getenv("GUTTER") or "5") -- number column + signs (gitsigns draws │ for changed lines)
    for i, s in ipairs(rows) do
      rows[i] = string.rep(" ", gutter) .. vim.fn.strcharpart(s, gutter)
    end
    local errs, blocks = S.check(rows, 2)
    if #blocks == 0 and not f:find("notable", 1, true) then errs[#errs + 1] = "no rendered table in the capture" end
    print(("%s %s: %d table block(s), %d error(s)%s"):format(#errs == 0 and "OK  " or "FAIL", vim.fn.fnamemodify(f, ":t"),
      #blocks, #errs, #errs > 0 and ("\n    " .. table.concat(errs, "\n    ")) or ""))
    if #errs > 0 then bad = bad + 1 end
  end
end
os.exit(bad == 0 and 0 or 1)
