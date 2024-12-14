local vim = vim

local function create_getter_setter()
  -- Save current view state
  local state = vim.fn.winsaveview()

  -- Get the current line
  local line = vim.fn.getline('.')

  -- Extract member name and type
  local member_pattern = '%s*([%w_:<>]+)%s+([%w_]+)%s*;'
  local type, member = line:match(member_pattern)

  if not type or not member then
    print("Invalid member declaration")
    return
  end

  -- Move to class definition and capture class name
  vim.cmd([[normal! [{]])
  local class_name = vim.fn.search('class\\s\\+\\zs\\h\\+', 'b')
  class_name = vim.fn.expand('<cword>')

  -- Create declarations for header file
  local getter_decl = string.format('    %s get_%s() const;', type, member)
  local setter_decl = string.format('    void set_%s(const %s& value);', member, type)

  -- Find or create public section
  vim.cmd([[normal! /{]]) -- Move to start of class body
  local found_public = vim.fn.search('public:', 'W', vim.fn.line('}'))

  if not found_public then
    -- If no public section exists, create one at the start of the class
    vim.cmd([[normal! /{o]])
    vim.api.nvim_put({ 'public:' }, 'l', true, true)
  else
    -- Move to the line after 'public:'
    vim.cmd('normal! o')
  end

  -- Insert declarations in public section
  vim.api.nvim_put({ getter_decl, '', setter_decl }, 'l', true, true)

  -- Create implementations
  local getter_impl = {
    '',
    string.format('%s %s::get_%s() const', type, class_name, member),
    '{',
    string.format('    return %s;', member),
    '}'
  }

  local setter_impl = {
    string.format('void %s::set_%s(const %s& value)', class_name, member, type),
    '{',
    string.format('    %s = value;', member),
    '}'
  }

  -- Switch to implementation file
  local current_file = vim.fn.expand('%:p:r')
  vim.cmd('edit ' .. current_file .. '.cpp')

  -- Go to end of namespace
  vim.cmd('normal! G')   -- Go to end of file
  vim.cmd([[normal! O]]) -- Open new line above

  vim.api.nvim_put(getter_impl, 'l', false, true)
  vim.api.nvim_put(setter_impl, 'l', true, false)

  -- Restore original view
  vim.fn.winrestview(state)
end

-- Create a command to call the function
vim.api.nvim_create_user_command('CreateGetterSetter', create_getter_setter, {})
