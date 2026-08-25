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
[[ $(stat -c '%a' "$new_path") == 600 ]] || fail "new capture file is not mode 600"

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

# The byte limit is inclusive and is enforced before touching the destination.
limit_path="$TMP/Limit.md"
python3 -c 'import sys; sys.stdout.buffer.write(b"a" * (256 * 1024))' | "$APPEND" "$limit_path"
[[ $(stat -c '%s' "$limit_path") -eq $((256 * 1024 + 1)) ]] || fail "exact-size capture was not stored"

oversized_path="$TMP/Oversized.md"
oversized_error="$TMP/oversized-error"
if python3 -c 'import sys; sys.stdout.buffer.write(b"a" * (256 * 1024 + 1))' | "$APPEND" "$oversized_path" 2>"$oversized_error"; then
  fail "oversized capture unexpectedly succeeded"
fi
[[ ! -e $oversized_path ]] || fail "oversized capture created a destination"
grep -qx 'Could not save note: note exceeds the 256 KiB limit.' "$oversized_error" || fail "missing oversized-note error"

existing_oversized="$TMP/Existing-oversized.md"
printf 'Existing note.\n' > "$existing_oversized"
if python3 -c 'import sys; sys.stdout.buffer.write(b"b" * (256 * 1024 + 1))' | "$APPEND" "$existing_oversized" 2>/dev/null; then
  fail "oversized capture changed an existing destination"
fi
assert_file 'Existing note.' "$existing_oversized"

# Final-component symlinks, including broken links, are never followed.
victim="$TMP/Victim.md"
printf 'Do not modify.\n' > "$victim"
symlink_path="$TMP/Symlink.md"
ln -s "$victim" "$symlink_path"
if printf 'attacker-controlled append' | "$APPEND" "$symlink_path" 2>"$TMP/symlink-error"; then
  fail "symlink destination unexpectedly succeeded"
fi
assert_file 'Do not modify.' "$victim"
grep -qi 'symbolic link' "$TMP/symlink-error" || fail "missing friendly symlink error"

broken_path="$TMP/Broken.md"
ln -s "$TMP/Does-not-exist.md" "$broken_path"
if printf 'note' | "$APPEND" "$broken_path" 2>"$TMP/broken-error"; then
  fail "broken symlink destination unexpectedly succeeded"
fi
[[ ! -e $TMP/Does-not-exist.md ]] || fail "broken symlink target was created"
grep -qi 'symbolic link' "$TMP/broken-error" || fail "missing broken-symlink error"

# A replacement race may append to the regular file opened at that instant or
# fail cleanly, but it must never follow a swapped-in symlink to the victim.
python3 - "$APPEND" "$TMP" <<'PY'
import os
import pathlib
import subprocess
import sys
import threading

helper = sys.argv[1]
root = pathlib.Path(sys.argv[2])
destination = root / "Race.md"
victim = root / "Race-victim.md"
victim.write_bytes(b"Do not modify.\n")
destination.write_bytes(b"regular\n")
stop = threading.Event()
race_errors = []
swap_count = 0

def swap_destination():
    global swap_count
    counter = 0
    try:
        while not stop.is_set():
            symlink_tmp = root / f".race-link-{counter}"
            regular_tmp = root / f".race-file-{counter}"
            counter += 1
            try:
                os.symlink(victim, symlink_tmp)
                os.replace(symlink_tmp, destination)
                regular_tmp.write_bytes(b"regular\n")
                os.replace(regular_tmp, destination)
                swap_count += 1
            finally:
                symlink_tmp.unlink(missing_ok=True)
                regular_tmp.unlink(missing_ok=True)
    except BaseException as exc:
        race_errors.append(exc)

thread = threading.Thread(target=swap_destination)
thread.start()
try:
    for _ in range(40):
        subprocess.run(
            [helper, str(destination)],
            input=b"race note",
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=2,
        )
finally:
    stop.set()
    thread.join()

if race_errors:
    raise race_errors[0]
if swap_count < 10:
    raise SystemExit("replacement race did not exercise enough swaps")
if victim.read_bytes() != b"Do not modify.\n":
    raise SystemExit("replacement race modified symlink target")
PY

# A directory destination fails clearly and leaves it intact.
dir_path="$TMP/Destination.md"
mkdir -p "$dir_path"
if printf 'note' | "$APPEND" "$dir_path" 2>"$TMP/error"; then
  fail "directory destination unexpectedly succeeded"
fi
grep -qi 'not a regular file' "$TMP/error" || fail "missing friendly invalid-path error"

# FIFOs must be rejected without blocking, even if another process has one open.
fifo_path="$TMP/Destination.fifo"
mkfifo "$fifo_path"
if printf 'note' | timeout 2 "$APPEND" "$fifo_path" 2>"$TMP/fifo-error"; then
  fail "FIFO destination unexpectedly succeeded"
else
  fifo_status=$?
fi
[[ $fifo_status -ne 124 ]] || fail "FIFO destination blocked"
grep -qi 'not a regular file' "$TMP/fifo-error" || fail "missing FIFO error"

# Unix sockets are also non-regular destinations.
socket_path="$TMP/Destination.sock"
python3 - "$socket_path" <<'PY' &
import socket
import sys
import time

sock = socket.socket(socket.AF_UNIX)
sock.bind(sys.argv[1])
time.sleep(5)
PY
socket_pid=$!
for _ in $(seq 1 100); do [[ -S $socket_path ]] && break; sleep 0.01; done
[[ -S $socket_path ]] || fail "socket fixture was not created"
if printf 'note' | timeout 2 "$APPEND" "$socket_path" 2>"$TMP/socket-error"; then
  fail "socket destination unexpectedly succeeded"
else
  socket_status=$?
fi
[[ $socket_status -ne 124 ]] || fail "socket destination blocked"
kill "$socket_pid" 2>/dev/null || true
wait "$socket_pid" 2>/dev/null || true
grep -qi 'not a regular file' "$TMP/socket-error" || fail "missing socket error"

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
