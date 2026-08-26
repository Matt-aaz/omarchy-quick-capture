#!/bin/bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT/bin/bounded-file"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ -x $HELPER ]] || fail "bounded-file helper is not executable"

printf '12345678' > "$TMP/exact"
[[ $("$HELPER" read 8 "$TMP/exact") == 12345678 ]] || fail "exact-size read failed"
printf '123456789' > "$TMP/large"
if "$HELPER" read 8 "$TMP/large" > "$TMP/out" 2> "$TMP/error"; then
  fail "oversized read succeeded"
fi
[[ ! -s $TMP/out ]] || fail "oversized read exposed content"
grep -qx 'File exceeds the 8-byte limit.' "$TMP/error" || fail "missing size error"

ln -s "$TMP/exact" "$TMP/link"
if "$HELPER" read 8 "$TMP/link" >/dev/null 2> "$TMP/error"; then
  fail "symlink read succeeded"
fi
grep -qx 'File is not a regular file.' "$TMP/error" || fail "missing type error"

mkfifo "$TMP/fifo"
if timeout 2 "$HELPER" read 8 "$TMP/fifo" >/dev/null 2> "$TMP/error"; then
  fail "FIFO read succeeded"
else
  status=$?
fi
[[ $status -ne 124 ]] || fail "FIFO read blocked"
grep -qx 'File is not a regular file.' "$TMP/error" || fail "missing FIFO error"

"$HELPER" read 8 "$TMP/missing" > "$TMP/out"
[[ ! -s $TMP/out ]] || fail "missing file produced output"

printf 'state' | "$HELPER" replace 8 "$TMP/state"
[[ $(<"$TMP/state") == state ]] || fail "atomic replace failed"
if printf '123456789' | "$HELPER" replace 8 "$TMP/state" 2> "$TMP/error"; then
  fail "oversized replace succeeded"
fi
[[ $(<"$TMP/state") == state ]] || fail "oversized replace changed file"

printf 'PASS: bounded file safety suite\n'
