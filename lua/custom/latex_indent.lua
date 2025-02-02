local vim = vim

local function format_and_reload()
  -- Save current cursor position
  local cursor_pos = vim.fn.getpos('.')

  -- Write first
  vim.cmd('write')

  -- Get the current file name
  local filepath = vim.fn.expand('%:p')

  -- Ensure the buffer has a file name
  if filepath == '' then
    print("No file to format")
    return
  end

  -- Run dos2unix first
  local dos2unix_cmd = string.format('dos2unix "%s"', filepath)
  vim.fn.system(dos2unix_cmd)

  -- Run latexindent with text wrapping config
  local cmd = string.format('latexindent -m -w -l ~/.config/nvim/lua/custom/latex_indent.yaml "%s" ', filepath)
  local result = vim.fn.system(cmd)

  -- Check for error in the latexindent command
  if vim.v.shell_error ~= 0 then
    print("Error running latexindent: " .. result)
    return
  end

  -- Reload the file into the current buffer
  vim.cmd('edit!')

  -- Restore cursor position
  vim.fn.setpos('.', cursor_pos)

  print("File formatted with latexindent and reloaded")
end

-- Define the :LFormat command
vim.api.nvim_create_user_command(
  'LFormat',
  format_and_reload,
  { desc = "Format the current latex file with latexindent and wrap to 80 characters" }
)
