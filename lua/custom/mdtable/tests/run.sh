#!/usr/bin/env bash
# Run every mdtable unit test (and the WP-I jitter check) with `nvim -l`;
# exit non-zero if any fails.
cd "$(dirname "$0")" || exit 2
fail=0 files=0 passed=0 failed=0
for t in test_*.lua vjitter_check.lua; do
  files=$((files + 1))
  out=$(nvim -l "$t" 2>&1); rc=$?
  printf '%s\n' "$out"
  p=$(printf '%s\n' "$out" | grep -c '^PASS ')
  f=$(printf '%s\n' "$out" | grep -c '^FAIL ')
  passed=$((passed + p)); failed=$((failed + f))
  if [ $rc -ne 0 ]; then fail=1; echo "!! $t exited $rc"; fi
done
echo "TOTAL: $files files, $passed tests passed, $failed failed"
exit $fail
