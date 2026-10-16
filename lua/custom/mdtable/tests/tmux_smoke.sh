#!/usr/bin/env bash
# tmux smoke on a real file (never saved: every session ends with :qa!).
# usage: tmux_smoke.sh FILE WIDTH HEIGHT OUTDIR
# Captures after each step go to OUTDIR/NN-step.txt; frames.txt holds the
# redraw count per `j` (decoration provider on_start = one frame).
set -u
f=$1 w=$2 h=$3 out=$4
here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$out"
rm -f "$out/frames.log" "$out/frames.log.tmp" "$out/ABORT" "$out"/fr[0-9]
T="tmux -L wpB"
$T kill-server 2>/dev/null
$T new-session -d -s d -x "$w" -y "$h" "nvim -c 'luafile $here/tmux_helper.lua' '$f'"
sleep 7
n=0
alive() { $T has-session -t d 2>/dev/null || { echo "ABORT: tmux session died before step $1" | tee "$out/ABORT"; exit 3; }; }
cap() { n=$((n + 1)); sleep "${2:-0.6}"; alive "$1"; $T capture-pane -p -t d > "$out/$(printf %02d $n)-$1.txt"; }
cmd() { $T send-keys -t d Escape; $T send-keys -t d ":$1" Enter; }
keys() { $T send-keys -t d "$@"; }
cap open 0.2
cmd "lua MDGO(1, 1, 1)"; cap header
for r in 2 3 4; do for j in 1 3 0; do cmd "lua MDGO(1, $r, $j)"; cap "row$r-cell$j"; done; done
for j in 1 3 0; do
  cmd "lua MDGO(1, 2, $j)"; keys i; keys -l xxxxx; cap "type-cell$j-insert"
  keys Escape; cap "type-cell$j-esc"
done
cmd "lua MDGO(1, 99, 1)"; cap lastrow
# append after the table's last row (the table need not be at EOF)
cmd "lua vim.fn.feedkeys('o' .. MDROW(1) .. '\\27', 't')"; cap append
# frames per j inside a wrapped cell: snapshot, 10 x j, snapshot; overhead of the snapshot measured alone
cmd "lua MDGO(1, 2, 3)"; sleep 0.5
cmd "lua MDFRAMES('$out/fr0')"; sleep 0.5
cmd "lua MDFRAMES('$out/fr1')"; sleep 0.5
for i in 1 2 3 4 5; do keys j; sleep 0.25; keys k; sleep 0.25; done
cmd "lua MDFRAMES('$out/fr2')"; sleep 0.5
alive frames
# a missing or non-numeric snapshot is a failure, not a number
rc=0
for x in fr0 fr1 fr2; do
  v=$(cat "$out/$x" 2>/dev/null)
  case "$v" in ''|*[!0-9]*) echo "FAIL frames: $out/$x missing or not a number (${v:-empty})" >> "$out/frames.log.tmp"; rc=4 ;; esac
done
if [ $rc -eq 0 ]; then
  a=$(cat "$out/fr0") b=$(cat "$out/fr1") c=$(cat "$out/fr2")
  echo "frames: snapshot overhead $((b - a)); 10 keys (j/k alternating): $((c - b - (b - a)))" > "$out/frames.log"
else
  mv "$out/frames.log.tmp" "$out/frames.log"
  echo "FAIL frames" > "$out/ABORT"
fi
cmd "lua vim.fn.writefile(vim.split(vim.fn.execute('messages'), '\\n'), '$out/messages.log')"; sleep 0.5
cmd "qa!"; sleep 1
$T kill-server 2>/dev/null
cat "$out/frames.log"
exit $rc
