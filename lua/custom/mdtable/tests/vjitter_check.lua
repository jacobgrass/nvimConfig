-- WP-I: no vertical movement when moving between the cells of one row.
-- Run by run.sh (nvim -l vjitter_check.lua; ONLY=<substring> picks cases).
-- Runs tests/probe_vjitter.lua in a child nvim with a UI of each size
-- (tests/uidriver.lua): Ctrl-l across every cell of the header, the next two
-- rows, the middle and the last row and back with Ctrl-h; in "flow" (the
-- default) every step must leave the view, the header float, the row's
-- screen span and grid lines and every other screen row (markers included)
-- unchanged. Ctrl-j from the header to the last row: unless the entering
-- row is clipped at the bottom (scroll-to-fit scrolls) or a clip is re-cut
-- (its marker moves or changes, or the header float changes), the screen
-- rows above both rows stay: the entering row grows downward. "row" and "cell" keep their blank spill rows, so their
-- rows may change height by cell: measured and printed, not asserted.
local here = vim.fn.fnamemodify(_G.arg[0], ":p:h")
local H = dofile(here .. "/helpers.lua")
local D = dofile(here .. "/uidriver.lua")
local ONLY = os.getenv("ONLY")
D.timeout_ms = 180000

local SIZES = { { 120, 45 }, { 100, 30 }, { 140, 50 }, { 97, 31 } }
local RUNS = {
  { "needs.md", "flow" }, { "ledger.md", "flow" }, { "needs-live.md", "flow" },
  { "needs.md", "row" }, { "needs.md", "cell" },
}

for _, run in ipairs(RUNS) do
  for _, sz in ipairs(SIZES) do
    local fx, mode, W, Hh = run[1], run[2], sz[1], sz[2]
    local strict = mode == "flow"
    local name = ("V1 %s %dx%d spill=%s: %s"):format(fx, W, Hh, mode, strict
      and "cell moves change nothing but the cursor; row moves keep the rows above"
      or "cell and row moves measured")
    if not ONLY or name:find(ONLY, 1, true) then
      H.run(name, function()
        local c = D.start(W, Hh + 1)
        local ok, err = xpcall(function()
          c.lua("_G.S = dofile(...); _G.M = require('custom.mdtable'); vim.g.mdtable_spill = select(2, ...)",
            here .. "/screen.lua", mode)
          c.lua("_G.BUF, _G.WIN = S.open(...)", fx)
          local res = c.lua("return dofile(...).run()", here .. "/probe_vjitter.lua")
          print(("INFO %s %dx%d %s: %d cell steps (%d violations), %d row moves (%d fitted, %d clip re-cuts, %d re-anchored, %d with the rows below shifted by a row's own growth, %d violations)")
            :format(fx, W, Hh, mode, res.steps, #res.cell_violations, res.rowmoves or 0, res.scrolls or 0, res.clipped or 0,
              res.reanchored or 0, res.shifted or 0, #res.row_violations))
          H.ok(res.steps > 10, "cell steps taken: " .. res.steps)
          -- WP-J: rows taller than the window are virtual, never raw
          print(("INFO %s %dx%d %s: virtual (tall) rows %s; raw rows %s"):format(fx, W, Hh, mode,
            table.concat(res.virtual or {}, ","), table.concat(res.raw or {}, ",")))
          if strict then H.eq({}, res.raw, "rows drawn raw") end
          -- the row moves the check does not compare, and how far the rows
          -- above moved (nil: the leaving row's first line left the screen)
          for _, sk in ipairs(res.skipped) do
            print(("INFO   skipped row move %d -> %d: %s; rows above shifted by %s"):format(sk[1], sk[2], sk[3], tostring(sk[4])))
          end
          if strict then
            H.eq({}, res.cell_violations, "cell-move violations")
            H.eq({}, res.row_violations, "row-move violations")
          end
          if fx == "ledger.md" and W == 100 and Hh == 30 and strict then
            -- WP-I item 7: entering the last row (GM6, clipped at the bottom)
            -- shifts the rows above by the minimal 5 rows (was 7: a clip
            -- re-cut plus the header float's seat)
            local got
            for _, sk in ipairs(res.skipped) do if sk[1] == 12 and sk[2] == 13 then got = sk[4] end end
            H.eq(5, got, "ledger 100x30 row move 12 -> 13: rows above shifted by")
          end
          local msgs = c.lua("return vim.fn.execute('messages')")
          H.ok(not msgs:find("E%d+:") and not msgs:find("rror"), "no errors in :messages: " .. msgs)
        end, debug.traceback)
        c.stop()
        if not ok then error(err, 0) end
      end)
    end
  end
end

H.done()
