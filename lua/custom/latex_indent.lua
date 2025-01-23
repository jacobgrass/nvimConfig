local vim = vim
-- Function to format the current file using latexformat and reload it in the buffer
local function format_and_reload()
  -- Write first
  vim.cmd('write')

  -- Set width to 80
  vim.cmd('set textwidth=80')
  vim.cmd('normal! gg')
  vim.cmd('normal! gqG')

  -- Get the current file name
  local filepath = vim.fn.expand('%:p')

  -- Ensure the buffer has a file name
  if filepath == '' then
    print("No file to format")
    return
  end

  -- Run latexformat on the file with the desired width (80)
  local cmd = string.format('latexindent "%s"', filepath)
  local result = vim.fn.system(cmd)

  -- Check for error in the latexformat command
  if vim.v.shell_error ~= 0 then
    print("Error running latexindent: " .. result)
    return
  end

  -- Reload the file into the current buffer
  vim.cmd('edit!')
  print("File formatted with latexindent and reloaded")
end

-- Define the :latexformat command
vim.api.nvim_create_user_command(
  'LFormat',
  format_and_reload,
  { desc = "Format the current latex file with latexindent and reload it" }
)
