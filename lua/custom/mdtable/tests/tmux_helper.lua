-- Loaded into the tmux smoke session (nvim -c "luafile ..."): moves to a
-- table cell through the renderer and counts redraw frames.
_G.MDFR = 0
vim.api.nvim_set_decoration_provider(vim.api.nvim_create_namespace("mdtable.smoke.frames"), {
  on_start = function() _G.MDFR = _G.MDFR + 1 end,
})
-- row r (1 = header, delimiter skipped), cell j (0 = last) of table t
function _G.MDGO(t, r, j)
  local m = require("custom.mdtable").model(0)
  local tb = m and m.tables[t] and m.tables[t].tbl
  if not tb then return end
  local rows = {}
  for i, row in ipairs(tb.rows) do if row.kind ~= "delim" then rows[#rows + 1] = { row, tb.start_row + i - 1 } end end
  local row, l = unpack(rows[math.min(r, #rows)])
  local c = row.cells[j == 0 and #row.cells or math.min(j, #row.cells)]
  require("custom.mdtable").goto(0, l, c.s)
end
function _G.MDFRAMES(path) vim.fn.writefile({ tostring(_G.MDFR) }, path) end
-- the completion menu would cover the table in the insert-mode captures
vim.api.nvim_create_autocmd("InsertEnter", { callback = function()
  pcall(function() require("cmp").setup.buffer({ enabled = false }) end)
end })
-- a full row for table t (its column count), for the append step
function _G.MDROW(t)
  local m = require("custom.mdtable").model(0)
  local n = m and m.tables[t or 1] and m.tables[t or 1].tbl.ncols or 2
  local cells = { "99", "appended row" }
  for j = 3, n do cells[j] = "c" .. j end
  return "| " .. table.concat(cells, " | ", 1, n) .. " |"
end
