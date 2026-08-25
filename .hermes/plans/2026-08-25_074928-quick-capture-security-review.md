# Quick Capture Marketplace Security Review Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Close the marketplace security findings at current HEAD while making normal Quick Capture use look and feel exactly the same.

**Architecture:** Keep the QML panel and its existing save flow, but put clear byte limits at both layers: the panel prevents an oversized draft/config from being used, and the helper independently refuses oversized stdin. Replace the Bash append implementation with a small Python-standard-library helper because Bash cannot securely request `O_NOFOLLOW` and then verify, lock, append, and `fsync` one file descriptor. Keep note text on stdin and the destination as an argv value.

**Tech Stack:** QML/Quickshell, JavaScript, Python 3 standard library (`os`, `stat`, `fcntl`, `errno`), Node.js tests, Bash release tests.

---

## Plain-English picture

Think of the capture file as a mailbox:

- Right now, the plugin looks at the mailbox name, then opens that name later. A bad actor could swap the mailbox for a shortcut (a symlink) between those two moments.
- The fix opens the mailbox once with “do not follow shortcuts” turned on. It then checks the already-open mailbox is a normal file, locks that exact open file, writes to it, and flushes that same file to disk.
- The note gets a 256 KiB limit and the config gets a 64 KiB limit. The panel checks first for a friendly experience, but the file-writing helper checks again so IPC or direct command use cannot bypass the limit.
- The public `status()` call becomes a tiny set of booleans. Remote callers will not be able to read the draft, app/window name, destination path, errors, screen name, or position. The two IPC test-writing functions will be removed completely.

## Current context and assumptions

- Repository: `/home/ethos/Projects/omarchy-quick-capture`
- Planned against exact clean `main` HEAD `d36cd70df4d7c36757af89cabc45311240186f96` (`Initial public release v0.1.0`). This is the revision named by the marketplace security report.
- The report’s three concrete findings map directly to this plan: `status()` leaks the unsaved draft and focused-window metadata; public test hooks can replace/save that draft; and the helper’s check-then-open sequence can follow a replacement symlink.
- Existing user-visible flow must remain: summon, type, `Ctrl+Enter`, append with one blank separator, clear only after a successful durable write, optionally notify, dismiss.
- Existing persistence behavior must remain: the draft stays in the editor after helper failure; the helper exits successfully only after append and `fsync` succeed.
- Proposed constants:
  - Maximum rendered note sent to the helper: `256 * 1024` UTF-8 bytes.
  - Maximum config JSON accepted for parsing: `64 * 1024` UTF-8 bytes.
- Python 3 is the practical implementation choice because its standard library exposes `O_NOFOLLOW`, descriptor-based `fstat`, `flock`, `write`, and `fsync`. No third-party package will be added.
- The destination’s parent directory chain is assumed to be controlled by the user, as it is for the normal `~/Documents/...` destination. `O_NOFOLLOW` protects the final destination component. Fully forbidding symlinks in every parent component would break legitimate setups such as a symlinked Documents/notes directory and is outside this request.
- Advisory `flock` coordinates Quick Capture writers. Another process that ignores locks and can rename entries in the parent directory can still rename/unlink the pathname while the verified descriptor is open. The helper must never follow a replacement symlink or write to its target; tests should permit a clean failure or a write to the originally opened regular inode during an active rename race.

## Task 1: Add reusable byte-limit logic and tests first

**Objective:** Define one UI-side understanding of UTF-8 byte size, including Unicode, before wiring limits into QML.

**Files:**
- Modify: `CaptureLogic.js`
- Modify: `tests/test-capture-logic.mjs`

**Steps:**

1. Add failing tests for a `utf8ByteLength(text)` helper:
   - ASCII byte count.
   - Multibyte text such as `café ✓`.
   - A supplementary Unicode character/emoji represented by a surrogate pair.
   - Boundary values at and just over 256 KiB.
2. Run `node tests/test-capture-logic.mjs`; expect the new assertions to fail because the helper does not exist.
3. Implement `utf8ByteLength` without assuming browser-only `TextEncoder` exists in QML. Count UTF-8 bytes correctly for one-, two-, three-, and four-byte code points, including valid surrogate pairs. Convert the input with `String(...)` consistently with the current logic helpers.
4. Re-run `node tests/test-capture-logic.mjs`; expect the complete logic suite to pass.

## Task 2: Remove IPC write hooks and make `status()` private-by-design

**Objective:** Ensure shell IPC cannot read a note or sensitive metadata and cannot inject/save note text through production test functions.

**Files:**
- Modify: `QuickCapture.qml:239-274`
- Create: `tests/test-qml-security.mjs`
- Modify: `tests/test-release.sh`

**Steps:**

1. Write a failing static security test that reads `QuickCapture.qml` and safely extracts the complete `status()` function body (brace-aware rather than a fragile one-line grep).
2. Assert that no function named `setTextForTest` or `saveForTest` exists anywhere in production QML.
3. Give `status()` an explicit allow-list of boolean operational keys only. Recommended response:
   - `opened`
   - `saving`
   - `panelVisible`

   Do not expose free-form strings, paths, dimensions, coordinates, focus state, source context, close reasons, config, pending markdown, or error text.
4. In the test, reject known sensitive identifiers (`text`, `pendingMarkdown`, `captureFile`, `sourceApp`, `sourceWindowTitle`, `errorMessage`, screen/geometry fields) and reject any status value that is not one of the allow-listed boolean expressions. This guards against later privacy regressions, not just today’s fields.
5. Run `node tests/test-qml-security.mjs`; expect failure against current HEAD.
6. Remove `setTextForTest()` and `saveForTest()` from `QuickCapture.qml`; do not add an IPC authentication mechanism solely to preserve production test hooks.
7. Reduce `status()` to the three allow-listed booleans. Retaining this minimal operational method satisfies the product requirement while removing all note content and focused-window metadata.
8. Remove the old release assertion that expects `editorFocused` in QML, invoke the new security test from `tests/test-release.sh`, and re-run the test; expect pass.

## Task 3: Enforce 256 KiB note and 64 KiB config limits in QML

**Objective:** Stop oversized data before save/config parsing while leaving all normal-size interactions unchanged.

**Files:**
- Modify: `QuickCapture.qml`
- Modify: `tests/test-qml-security.mjs`
- Modify: `tests/test-capture-logic.mjs` if additional boundary coverage is useful

**Steps:**

1. Add failing QML security assertions for named read-only constants equivalent to 256 KiB and 64 KiB, and for checks at config load and save time.
2. Add `maxNoteBytes` and `maxConfigBytes` constants near the existing paths/state.
3. Update `loadConfig(raw)` so it computes the UTF-8 size before `JSON.parse`:
   - If over 64 KiB, keep/reset to `defaultConfig()`.
   - Set a useful message such as `Configuration is too large (64 KiB maximum). Fix <config path> and retry.`
   - Return without parsing the oversized JSON.
   - Keep the existing friendly invalid-JSON behavior for normal-size malformed config.
4. Enforce the editor limit in the UI without changing normal typing behavior:
   - Track the last editor text that was within the UTF-8 byte limit.
   - On an edit/paste that would exceed 256 KiB, restore the last accepted text, retain focus, and show `Note is too large (256 KiB maximum).`
   - Avoid recursive `onTextChanged` handling with a small guard boolean.
   - Reset the accepted-text state when a successful save clears the editor.
5. Independently check the final rendered Markdown in `save()`, because a large template/tags/source metadata can push a valid draft over the limit. Refuse to start `saveProc`, keep the draft, focus the editor, and show the same useful size error.
6. Ensure the existing empty-note, invalid-path, saving guard, error handling, notification, and dismiss behavior are untouched.
7. Run `node tests/test-capture-logic.mjs` and `node tests/test-qml-security.mjs`; expect pass.

## Task 4: Rewrite `append-capture` around one verified descriptor

**Objective:** Remove symlink/TOCTOU exposure and independently reject oversized stdin while preserving append formatting, locking, and durability.

**Files:**
- Replace implementation: `bin/append-capture` (retain executable bit and command-line contract)
- Modify: `tests/test-append-capture.sh`

**Steps:**

1. Extend the helper tests first and run `bash tests/test-append-capture.sh`; expect the new security cases to fail against the Bash implementation.
2. Replace the helper internals with Python 3 standard-library code while keeping usage exactly `append-capture ABSOLUTE_PATH` and reading note bytes only from stdin.
3. Keep `umask(0o077)`, absolute-path validation, parent creation, friendly one-line stderr, and non-zero categorized exits.
4. Read stdin with a hard cap: read at most `256 KiB + 1` bytes. If the extra byte exists, return a clear `Could not save note: note exceeds the 256 KiB limit.` error before creating/opening the destination. Normalize only trailing LF bytes and reject an empty result as today.
5. Create missing parent directories before opening the destination. Report parent-creation failures without raw traceback/system utility diagnostics.
6. Open the destination exactly once using flags equivalent to:
   - `O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW`
   - `O_NONBLOCK` during open if needed to avoid blocking on a FIFO, then clear it after regular-file verification.
   - creation mode `0o600`.
7. On that descriptor, in order:
   - `fstat()` and require `stat.S_ISREG`.
   - acquire `fcntl.flock(fd, LOCK_EX)`.
   - `fstat()` again if useful for defensive clarity.
   - use descriptor-based reads (`os.pread`) to inspect the existing last byte; never call `open`, `stat`, `tail`, `sync -f PATH`, or any other pathname-based operation on the destination after opening.
   - calculate the existing separator exactly as today (no separator for empty file, otherwise ensure the old content ends in LF and insert one blank line).
   - append separator + normalized payload + one LF using a loop around `os.write` so short writes are handled.
   - call `os.fsync(fd)` and report success only afterward.
   - unlock/close in `finally` blocks.
8. Map symlink (`ELOOP`), directory, FIFO/socket/device, permission, lock, write, and flush failures to concise useful errors. Do not leak a Python traceback.
9. Preserve the key failure contract: QML receives non-zero on any validation/open/lock/write/fsync failure, so it does not clear the draft.

## Task 5: Cover helper security and behavior comprehensively

**Objective:** Prove both ordinary behavior and the requested attack cases.

**Files:**
- Modify: `tests/test-append-capture.sh`
- Optionally create: `tests/race-destination.py` if a small deterministic race helper makes the shell suite clearer

**Test cases:**

1. **Normal append:** existing Markdown is preserved and the new note appears once with exactly one blank line.
2. **New-file creation:** missing parent directories and destination are created; destination is a regular file with private permissions under the helper’s `077` umask.
3. **Unicode/multiline:** byte-for-byte interior content is preserved.
4. **Empty note:** rejected without creating a destination.
5. **Exact size boundary:** exactly 256 KiB (after the defined trailing-LF normalization rule) is accepted.
6. **Oversized note:** 256 KiB + 1 is rejected with one useful line; a missing destination is not created and an existing destination remains byte-for-byte unchanged.
7. **Destination symlink:** a symlink to a real “victim” file is rejected; the victim remains unchanged.
8. **Broken symlink:** rejected rather than creating the symlink target.
9. **Non-regular destinations:** directory, FIFO, and (when safely available) Unix socket are rejected quickly. Wrap FIFO/socket cases in `timeout` so a regression cannot hang CI.
10. **Replacement race (practical stress test):** repeatedly swap the final path between a regular file and symlink while invoking the helper. Assert the symlink target/decoy is never modified. Accept only documented outcomes: a safe append to an atomically opened regular file or a clean rejection. Keep the loop bounded so release tests remain fast and non-flaky.
11. **Concurrency:** preserve the existing five-writer lock test and verify each capture appears exactly once.
12. **Write/open errors:** preserve friendly one-line errors and unchanged existing data where the operation fails before append.

Run `bash tests/test-append-capture.sh`; expect all cases to pass with no hangs or leaked tracebacks.

## Task 6: Integrate release checks and document security behavior

**Objective:** Make the security rules part of every release and state the remaining assumptions clearly.

**Files:**
- Modify: `tests/test-release.sh`
- Modify: `README.md`
- Modify: `CHANGELOG.md`

**Steps:**

1. Ensure `tests/test-release.sh` runs:
   - `bash tests/test-append-capture.sh`
   - `node tests/test-capture-logic.mjs`
   - `node tests/test-qml-security.mjs`
   - `omarchy plugin validate .`
2. Add release checks that production QML has no test IPC hooks and the helper remains executable.
3. Update README configuration/security notes with the 256 KiB rendered-note limit, 64 KiB config limit, final-component symlink rejection, regular-file-only destination rule, and Python 3 standard-library runtime requirement if it is not already an explicit Omarchy baseline.
4. Add a changelog entry describing the hardening without implying the marketplace approval itself is a security audit.
5. Document remaining assumptions:
   - trusted/user-controlled parent directory components;
   - advisory locks only coordinate cooperating writers;
   - a process with permission to modify the destination directory can rename/unlink entries despite a lock, but `O_NOFOLLOW` plus descriptor-only I/O prevents writing through a replacement symlink;
   - `fsync(fd)` confirms file contents/metadata for the opened file, not full directory-entry durability after creating a new file. If crash-durable creation is required by the review, additionally open the parent directory and `fsync` it after first creation.

## Task 7: Full verification at current HEAD

**Objective:** Verify functionality, security invariants, and clean repository state before summarizing.

**Files:**
- No new code expected; fixes only if verification finds a problem.

**Steps:**

1. Run `bash tests/test-release.sh`; expect every suite and `omarchy plugin validate .` to pass.
2. Run a syntax check on the rewritten helper, for example `python3 -m py_compile bin/append-capture`, while directing bytecode outside release files or removing generated `__pycache__` afterward.
3. Run `git diff --check`; expect no whitespace errors.
4. Inspect `git diff -- QuickCapture.qml CaptureLogic.js bin/append-capture tests README.md CHANGELOG.md` and confirm no normal UX/layout/shortcut/template behavior changed.
5. Run `git status --short`; ensure only intended source/test/doc files are modified and no generated payloads, bytecode, or temporary race files remain.
6. If a live Omarchy shell is available and changing the installed copy is explicitly approved during implementation, perform a bounded manual smoke test: summon, type a small note, save, confirm append, and confirm `status()` returns booleans only. Do not overwrite the installed plugin automatically merely to satisfy unit tests.
7. Final report must list exact files changed, exact limits, IPC fields retained, helper open flags/descriptor sequence, tests actually run and their real outputs, and the remaining assumptions above.

## Risks and trade-offs

- **Python dependency:** gives correct low-level file APIs with much less custom code than C. Confirm Python 3 is part of the supported Omarchy environment before release.
- **UTF-8 semantics:** the limit is bytes, not visible characters. Emoji and non-ASCII characters use more bytes, which is the correct bound for stdin/file storage. The panel error should say KiB rather than implying a character count.
- **Template expansion:** a draft below 256 KiB can still be rejected if the rendered template crosses the byte limit. This is intentional and prevents bypass via oversized config fields.
- **Partial filesystem failures:** as with the current append design, an I/O failure after some bytes were accepted by the kernel can leave a partial append while the panel keeps the draft. The helper must never claim success before `fsync`; fully transactional append would require a different whole-file replace design and would conflict with efficient concurrent append behavior.
- **Directory rename attackers:** no per-file advisory lock can stop an attacker who controls the parent directory from renaming entries. Descriptor-only I/O and `O_NOFOLLOW` prevent the key attack—following a swapped symlink into another file—but availability/pathname continuity still depends on trusted parent-directory permissions.

## Acceptance checklist

- [ ] No production `setTextForTest()` or `saveForTest()` functions.
- [ ] `status()` returns only allow-listed booleans and no strings/metadata.
- [ ] QML prevents oversized draft use and rejects rendered notes over 256 KiB.
- [ ] QML refuses to parse config over 64 KiB and gives a useful error.
- [ ] Helper independently refuses stdin over 256 KiB before touching the destination.
- [ ] Destination is opened once with no-follow semantics.
- [ ] The same descriptor is `fstat`-verified, locked, read for separator state, appended, and `fsync`ed.
- [ ] Symlinks and all non-regular destination types are rejected.
- [ ] Normal append, new creation, Unicode, concurrency, and failure draft-retention contracts remain.
- [ ] Replacement-race test never changes the symlink target.
- [ ] Full release suite and plugin validation pass.
