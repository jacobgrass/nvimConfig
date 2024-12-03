local function reorganize_cpp_files()
  -- Helper function to sort lines
  local function sort_lines(lines)
    table.sort(lines)
    return lines
  end

  -- Helper function to organize includes
  local function organize_includes(lines)
    local includes = {
      system = {},
      project = {},
      other = {}
    }

    for _, line in ipairs(lines) do
      if line:match("^%s*#include%s*<.*>") then
        table.insert(includes.system, line)
      elseif line:match("^%s*#include%s*\".*\"") then
        table.insert(includes.project, line)
      else
        table.insert(includes.other, line)
      end
    end

    sort_lines(includes.system)
    sort_lines(includes.project)
    return includes.system, includes.project, includes.other
  end

  -- Function to reorganize header file
  local function reorganize_header()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local has_pragma_once = false
    local system_includes, project_includes, other_lines = organize_includes(lines)
    local namespace_name = nil
    local class_content = { public = {}, protected = {}, private = {} }
    local final_content = {}

    -- First pass to find pragma and namespace
    for _, line in ipairs(lines) do
      if line:match("^%s*#pragma%s+once") then
        has_pragma_once = true
      elseif line:match("^%s*namespace%s+(%w+)%s*{") then
        namespace_name = line:match("^%s*namespace%s+(%w+)")
      end
    end

    -- Build final content
    if has_pragma_once then
      table.insert(final_content, "#pragma once")
      table.insert(final_content, "")
    end

    -- Add includes
    vim.list_extend(final_content, system_includes)
    if #system_includes > 0 then table.insert(final_content, "") end
    vim.list_extend(final_content, project_includes)
    if #project_includes > 0 then table.insert(final_content, "") end

    if namespace_name then
      table.insert(final_content, string.format("namespace %s {", namespace_name))
      table.insert(final_content, "")
    end

    -- Process class content
    local current_access = "private"
    local current_comment = {}
    local class_comment = {}
    local in_class = false
    local in_comment = false

    for _, line in ipairs(other_lines) do
      if line:match("^%s*/[*]") then
        in_comment = true
        if not in_class then
          table.insert(class_comment, line)
        else
          table.insert(current_comment, line)
        end
      elseif in_comment then
        if not in_class then
          table.insert(class_comment, line)
        else
          table.insert(current_comment, line)
        end
        if line:match("[*]/%s*$") then
          in_comment = false
        end
      elseif line:match("^%s*class%s+%w+") then
        in_class = true
        vim.list_extend(final_content, class_comment)
        table.insert(final_content, line)
        table.insert(final_content, "{")
      elseif in_class then
        if line:match("^%s*public:") then
          current_access = "public"
        elseif line:match("^%s*protected:") then
          current_access = "protected"
        elseif line:match("^%s*private:") then
          current_access = "private"
        elseif #line:gsub("%s+", "") > 0 and not line:match("^%s*{") and not line:match("^%s*};") then
          if #current_comment > 0 then
            vim.list_extend(class_content[current_access], current_comment)
            current_comment = {}
          end
          table.insert(class_content[current_access], line)
        end
      end
    end

    -- Add class members by access level
    for _, access in ipairs({ "public", "protected", "private" }) do
      if #class_content[access] > 0 then
        table.insert(final_content, access .. ":")
        vim.list_extend(final_content, class_content[access])
        table.insert(final_content, "")
      end
    end

    table.insert(final_content, "};")

    if namespace_name then
      table.insert(final_content, string.format("} // namespace %s", namespace_name))
    end

    -- Set the buffer content
    vim.api.nvim_buf_set_lines(0, 0, -1, false, final_content)
  end
  -- Function to reorganize implementation file
  local function reorganize_cpp()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    local system_includes, project_includes, other_lines = organize_includes(lines)
    local implementations = {}
    local other_content = {}
    local current_impl = {}
    local final_content = {}

    -- Collect implementations
    for _, line in ipairs(other_lines) do
      if line:match("^%w+::%w+") then
        if #current_impl > 0 then
          implementations[#implementations + 1] = current_impl
        end
        current_impl = { line }
      elseif #current_impl > 0 then
        table.insert(current_impl, line)
      else
        table.insert(other_content, line)
      end
    end

    if #current_impl > 0 then
      implementations[#implementations + 1] = current_impl
    end

    -- Sort implementations based on their first line
    table.sort(implementations, function(a, b)
      return a[1] < b[1]
    end)

    -- Build final content
    vim.list_extend(final_content, system_includes)
    if #system_includes > 0 then table.insert(final_content, "") end
    vim.list_extend(final_content, project_includes)
    if #project_includes > 0 then table.insert(final_content, "") end
    vim.list_extend(final_content, other_content)
    if #other_content > 0 then table.insert(final_content, "") end

    -- Add implementations
    for _, impl in ipairs(implementations) do
      vim.list_extend(final_content, impl)
      table.insert(final_content, "")
    end

    -- Set the buffer content
    vim.api.nvim_buf_set_lines(0, 0, -1, false, final_content)
  end


  -- Determine file type and reorganize accordingly
  local file_ext = vim.fn.expand("%:e")
  if file_ext == "h" or file_ext == "hpp" then
    reorganize_header()
  elseif file_ext == "cpp" or file_ext == "cc" then
    reorganize_cpp()
  end
end

-- Create command (only need to create it once)
vim.api.nvim_create_user_command('ReorganizeCpp', reorganize_cpp_files, {})
