local dap = require("dap")
-- Set colors for debugging
vim.api.nvim_set_hl(0, 'DapBreakpoint', { fg = '#993939', bg = '#31353f' })
vim.api.nvim_set_hl(0, 'DapLogPoint', { fg = '#61afef', bg = '#31353f' })
vim.api.nvim_set_hl(0, 'DapStopped', { fg = '#98c379', bg = '#31353f' })

-- Set signs
vim.fn.sign_define('DapBreakpoint', {
  text = '●',
  texthl = 'DapBreakpoint',
  linehl = 'DapBreakpoint',
  numhl =
  'DapBreakpoint'
})
vim.fn.sign_define('DapBreakpointCondition',
  { text = '●', texthl = 'DapBreakpoint', linehl = 'DapBreakpoint', numhl = 'DapBreakpoint' })
vim.fn.sign_define('DapBreakpointRejected',
  { text = '●', texthl = 'DapBreakpoint', linehl = 'DapBreakpoint', numhl = 'DapBreakpoint' })
vim.fn.sign_define('DapLogPoint', { text = '◆', texthl = 'DapLogPoint', linehl = 'DapLogPoint', numhl = 'DapLogPoint' })
vim.fn.sign_define('DapStopped', { text = '▶', texthl = 'DapStopped', linehl = 'DapStopped', numhl = 'DapStopped' })

dap.adapters.codelldb = {
  type = 'server',
  port = "${port}",
  executable = {
    command = vim.fn.stdpath("data") .. '/mason/packages/codelldb/extension/adapter/codelldb',
    args = { "--port", "${port}" },
  }
}

dap.configurations.cpp = {
  {
    name = "Launch Tests w output",
    type = "codelldb",
    request = "launch",
    program = function()
      -- Show building indication
      print("Building tests...")
      vim.cmd('redraw') -- Force immediate display of the message

      -- Run test.sh first
      local build_handle = io.popen('bash ' .. vim.fn.getcwd() .. '/test.sh')
      if build_handle then
        local build_output = build_handle:read("*a")
        build_handle:close()
        print("\nBuild output:")
        print(build_output)
      else
        print("\nFailed to run test.sh")
        return nil
      end

      print("\nLocating test executable...")
      vim.cmd('redraw') -- Force immediate display of the message

      -- Give the system a moment to finish writing files
      os.execute("sleep 0.5")

      -- Now find the newest test executable
      local handle = io.popen([[
            find ]] .. vim.fn.getcwd() .. [[/build -type f -executable -name "*[Tt]est*" \
            -printf '%T@ %p\n' | sort -n | tail -1 | cut -f2- -d' '
        ]])

      if handle == nil then
        print("Failed to locate test executable")
        return nil
      end

      local executable = handle:read("*a")
      handle:close()

      -- Trim whitespace
      executable = executable:gsub("^%s*(.-)%s*$", "%1")

      if executable ~= "" then
        print("Found test executable: " .. executable)
        return executable
      end

      print("No test executable found automatically")
      -- Fallback: ask user directly
      return vim.fn.input('Path to test executable: ', vim.fn.getcwd() .. '/build/', 'file')
    end,
    cwd = '${workspaceFolder}',
    stopOnEntry = false,
    runInTerminal = true,
    sourceLanguages = { "c++" },
    args = {},
    preLaunchTask = "", -- Clear any default build task
  },
  {
    name = "Launch file",
    type = "codelldb",
    request = "launch",
    program = function()
      return vim.fn.input('Path to executable: ', vim.fn.getcwd() .. '/', 'file')
    end,
    cwd = '${workspaceFolder}',
    stopOnEntry = false,
  },

}

dap.configurations.c = dap.configurations.cpp
