-- Generated stress table for the mdtable tests (deterministic).
local WORDS = { "contractor", "explorer", "**bold**", "`code`", "page", "prod", "Impossibly", "widget",
  "the", "and", "[link](https://example.com/a)", "scope", "before", "promotion", "R30", "DS1–DS6" }

-- 20 rows (header + delimiter + 18 body) x 7 columns, ~300-char cells.
local function big_table(salt)
  local lines = { "# Generated", "" }
  local hdr = {}
  for j = 1, 7 do hdr[j] = "Column " .. j end
  lines[#lines + 1] = "| " .. table.concat(hdr, " | ") .. " |"
  lines[#lines + 1] = "|" .. string.rep(" --- |", 7)
  local seed = 7 + (salt or 0)
  for r = 1, 18 do
    local cells = {}
    for j = 1, 7 do
      local parts, len = {}, 0
      while len < 300 do
        seed = (seed * 16807) % 2147483647 -- Park-Miller: exact in doubles
        local w = WORDS[math.floor(seed / 65536) % #WORDS + 1]
        parts[#parts + 1] = w
        len = len + #w + 1
      end
      cells[j] = table.concat(parts, " ")
    end
    lines[#lines + 1] = "| " .. table.concat(cells, " | ") .. " |"
  end
  lines[#lines + 1] = ""
  return lines
end

return { big_table = big_table }
