local function create_definition()
  -- Save current view state
  local state = vim.fn.winsaveview()

  -- Yank the current line
  vim.cmd('normal! yy')

  -- Move to class definition and capture class name
  vim.cmd([[normal! [{]])
  local class_name = vim.fn.search('class\\s\\+\\zs\\h\\+', 'b')
  class_name = vim.fn.expand('<cword>')

  -- Restore view
  vim.fn.winrestview(state)

  -- Switch to implementation file
  local current_file = vim.fn.expand('%:p:r')
  vim.cmd('edit ' .. current_file .. '.cpp')

  -- Go to end of file and paste
  vim.cmd('normal! Gp')

  -- Get the line number of the pasted text
  local line_nr = vim.fn.line('.')

  -- Get the content of the line
  local line = vim.fn.getline(line_nr)

  -- Clean the string and make modifications
  line = vim.fn.substitute(line, '\n', '', 'g')   -- Remove newlines
  line = vim.fn.substitute(line, '%s+', ' ', 'g') -- Normalize spaces
  line = line:gsub('(~?[%w_]+%()', class_name .. '::' .. '%1')
  line = line:gsub(';%s*$', '\n{\n}\n')           -- Replace trailing semicolon with braces

  -- Delete the original line and insert the modified version
  vim.cmd('normal! dd')
  vim.api.nvim_put(vim.split(line, '\n'), 'l', true, true)
end

-- Create a command to call the function
vim.api.nvim_create_user_command('CreateDefinition', create_definition, {})
