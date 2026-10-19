-- Shape check for anonymized fixtures: the new fixture must lay out exactly
-- like the old one. Usage (exit 0 = identical shape, 1 = mismatch, 2 = usage):
--   nvim -l lua/custom/mdtable/tests/fixture_shape.lua OLD_DIR NEW_DIR [file ...] [-- OLD=NEW ...]
-- Files default to needs.md needs-live.md ledger.md. Compared per line: byte
-- length, display width and skeleton (letters -> a, digits -> 0, all else
-- kept). Per table: rows, columns, aligns; per row: kind, raw width, cells; per
-- cell: byte span, display width, longest word, word spans, conceal spans; per
-- layout (widths 60..300, separators off/on): column widths, row heights, and
-- every chunk (byte span, width, padding). Each OLD=NEW search pair must match
-- at the same (line, byte) positions, case-sensitive and ignoring case.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local hp = here .. "/helpers.lua"
if vim.fn.filereadable(hp) == 0 then hp = vim.fn.stdpath("config") .. "/lua/custom/mdtable/tests/helpers.lua" end
local H = dofile(hp)
local scan = require("custom.mdtable.scan")
local layout = require("custom.mdtable.layout")

local argv, files, pairs_ = _G.arg, {}, {}
local old_dir, new_dir = argv[1], argv[2]
if not old_dir or not new_dir then print("usage: OLD_DIR NEW_DIR [file ...] [-- OLD=NEW ...]"); os.exit(2) end
local in_pairs = false
for i = 3, #argv do
  if argv[i] == "--" then in_pairs = true
  elseif in_pairs then local o, n = argv[i]:match("^(.-)=(.*)$"); pairs_[#pairs_ + 1] = { o, n }
  else files[#files + 1] = argv[i] end
end
if #files == 0 then files = { "needs.md", "needs-live.md", "ledger.md" } end
local WIDTHS = { 60, 80, 95, 115, 135, 160, 200, 300 }

-- Flat list of "key=value" facts describing the shape of one file.
local function shape(lines)
  local out = {}
  local function put(k, v) out[#out + 1] = k .. "=" .. vim.inspect(v, { newline = "", indent = "" }) end
  put("nlines", #lines)
  for i, l in ipairs(lines) do
    put(("L%d.bytes"):format(i), #l)
    put(("L%d.width"):format(i), vim.api.nvim_strwidth(l))
    put(("L%d.skel"):format(i), (l:gsub("%a", "a"):gsub("%d", "0")))
  end
  H.with_buffer(lines, function(buf)
    local tbls = scan.tables(buf)
    put("ntables", #tbls)
    for ti, t in ipairs(tbls) do
      local p = "T" .. ti
      put(p .. ".pos", { t.start_row, t.end_row, t.header_row, t.delim_row, t.ncols, t.indent })
      put(p .. ".aligns", t.aligns)
      for ri, r in ipairs(t.rows) do
        local rp = ("%s.R%d"):format(p, ri)
        put(rp, { r.lnum, r.kind, r.ragged or false, r.raw_width, #r.cells, r.indent })
        for ci, c in ipairs(r.cells) do
          put(("%s.C%d"):format(rp, ci), { c.s, c.e, c.width, c.lw, c.wb, c.we, c.ww, c.cs, c.ce, #c.marks })
        end
      end
      for _, W in ipairs(WIDTHS) do
        for _, sep in ipairs({ false, true }) do
          local L = layout.table(t, { width = W, separators = sep })
          local lp = ("%s.W%d%s"):format(p, W, sep and "s" or "")
          put(lp .. ".widths", L.widths)
          put(lp .. ".height", L.height)
          for ri, r in ipairs(L.rows) do
            put(("%s.R%d.lines"):format(lp, ri), r.lines)
            for ci, c in ipairs(r.cells or {}) do
              local ch = {}
              for _, k in ipairs(c.chunks) do ch[#ch + 1] = { k.s, k.e, k.width, k.pad_left, k.pad_right, k.fill or false } end
              put(("%s.R%d.C%d.chunks"):format(lp, ri, ci), ch)
            end
          end
        end
      end
    end
  end)
  return out
end

local function hits(lines, pat, nocase)
  local out = {}
  if nocase then pat = pat:lower() end
  for i, l in ipairs(lines) do
    if nocase then l = l:lower() end
    local s = 1
    while true do
      local a = l:find(pat, s, true)
      if not a then break end
      out[#out + 1] = i .. ":" .. a; s = a + 1
    end
  end
  return table.concat(out, " ")
end

local bad = 0
for _, f in ipairs(files) do
  local old, new = H.readfile and nil, nil
  old = vim.fn.readfile(old_dir .. "/" .. f, "b")
  new = vim.fn.readfile(new_dir .. "/" .. f, "b")
  local a, b = shape(old), shape(new)
  local diffs = 0
  for i = 1, math.max(#a, #b) do
    if a[i] ~= b[i] then
      diffs = diffs + 1
      if diffs <= 20 then print(("  %s\n- %s\n+ %s"):format(f, tostring(a[i]), tostring(b[i]))) end
    end
  end
  for _, pr in ipairs(pairs_) do
    for _, nc in ipairs({ false, true }) do
      local ho, hn = hits(old, pr[1], nc), hits(new, pr[2], nc)
      if ho ~= hn then
        diffs = diffs + 1
        print(("  %s search %s -> %s (%s): %s vs %s"):format(f, pr[1], pr[2], nc and "nocase" or "case", ho, hn))
      end
    end
  end
  print(("%s %s: %d facts compared, %d differ"):format(diffs == 0 and "SAME" or "DIFF", f, #a, diffs))
  bad = bad + diffs
end
os.exit(bad == 0 and 0 or 1)
