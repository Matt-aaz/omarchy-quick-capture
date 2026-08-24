#!/bin/bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
APPEND="$ROOT/bin/append-capture"
TMP=$(mktemp -d)
trap 'chmod -R u+w "$TMP" 2>/dev/null || true; rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  local expected=$1 file=$2
  [[ -f $file ]] || fail "missing file: $file"
  local actual
  actual=$(<"$file")
  [[ $actual == "$expected" ]] || {
    printf 'EXPECTED:\n%s\nACTUAL:\n%s\n' "$expected" "$actual" >&2
    fail "file content differs"
  }
}

[[ -x $APPEND ]] || fail "append helper is not executable"

# New files and missing parent directories are created.
new_path="$TMP/Notes with spaces/Capture.md"
printf '%s' $'## 2026-08-22 21:03\n#capture\n\nRemember to revisit this tomorrow.\n' | "$APPEND" "$new_path"
assert_file $'## 2026-08-22 21:03\n#capture\n\nRemember to revisit this tomorrow.' "$new_path"

# Existing Markdown is appended, never overwritten, with one blank separator.
printf '%s' $'## Earlier\n#capture\n\nExisting note.\n' > "$new_path"
printf '%s' $'## 2026-08-22 21:17\n#capture #reading\n\nCompare these two approaches before making a decision.\n' | "$APPEND" "$new_path"
assert_file $'## Earlier\n#capture\n\nExisting note.\n\n## 2026-08-22 21:17\n#capture #reading\n\nCompare these two approaches before making a decision.' "$new_path"

# Unicode and multiline text survive unchanged.
unicode_path="$TMP/Unicode.md"
printf '%s' $'## 2026-08-22 21:19\n#capture\n\nFirst line.\nSecond line — café ✓.\n' | "$APPEND" "$unicode_path"
assert_file $'## 2026-08-22 21:19\n#capture\n\nFirst line.\nSecond line — café ✓.' "$unicode_path"

# Empty payloads are rejected without creating a file.
empty_path="$TMP/Empty.md"
if printf '' | "$APPEND" "$empty_path" 2>/dev/null; then
  fail "empty payload unexpectedly succeeded"
fi
[[ ! -e $empty_path ]] || fail "empty capture created a file"

# A directory destination fails clearly and leaves it intact.
dir_path="$TMP/Destination.md"
mkdir -p "$dir_path"
if printf 'note' | "$APPEND" "$dir_path" 2>"$TMP/error"; then
  fail "directory destination unexpectedly succeeded"
fi
grep -qi 'not a regular file' "$TMP/error" || fail "missing friendly invalid-path error"

# An existing unwritable file is not changed and reports one friendly line.
unwritable="$TMP/Unwritable.md"
printf 'Existing note.\n' > "$unwritable"
chmod 400 "$unwritable"
unwritable_error="$TMP/unwritable-error"
if printf 'new note' | "$APPEND" "$unwritable" 2>"$unwritable_error"; then
  fail "unwritable destination unexpectedly succeeded"
fi
chmod 600 "$unwritable"
assert_file 'Existing note.' "$unwritable"
[[ $(wc -l < "$unwritable_error") -eq 1 ]] || fail "unwritable error leaked utility diagnostics"
grep -qx 'Could not create or open the capture file.' "$unwritable_error" || fail "missing friendly unwritable error"

# A read-only system path reports one friendly line, not utility diagnostics.
readonly_error="$TMP/readonly-error"
if printf 'note' | "$APPEND" "/sys/quick-capture/Capture.md" 2>"$readonly_error"; then
  fail "read-only destination unexpectedly succeeded"
fi
[[ $(wc -l < "$readonly_error") -eq 1 ]] || fail "read-only error leaked utility diagnostics"
grep -qx 'Could not create the capture directory.' "$readonly_error" || fail "missing friendly read-only error"

# Concurrent captures serialize under a lock and each appears exactly once.
rapid="$TMP/Rapid.md"
for i in 1 2 3 4 5; do
  printf 'capture-%s\n' "$i" | "$APPEND" "$rapid" &
done
wait
for i in 1 2 3 4 5; do
  [[ $(grep -c "^capture-$i$" "$rapid") -eq 1 ]] || fail "capture-$i missing or duplicated"
done
[[ $(grep -c '^capture-' "$rapid") -eq 5 ]] || fail "rapid capture count differs"

printf 'PASS: append helper safety suite\n'
