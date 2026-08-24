#!/bin/bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

bash tests/test-append-capture.sh
node tests/test-capture-logic.mjs
omarchy plugin validate .

jq -e '.schemaVersion == 1 and .id == "io.github.matt-aaz.quick-capture" and .version == "0.1.0" and .author == "matt-aaz" and .license == "MIT" and (.kinds | index("panel")) and .entryPoints.panel == "QuickCapture.qml"' manifest.json >/dev/null
jq -e '.capture_file == "~/Documents/Notes/Capture.md" and .default_tags == ["capture"] and .include_timestamp == true and .panel_width == 700 and .panel_height == 230' config.example.json >/dev/null

# Reject common credential formats and private key material from release files.
if grep -RniE --exclude-dir=.git --exclude='test-release.sh' '(BEGIN (RSA|OPENSSH|EC|PGP) PRIVATE KEY|gh[pousr]_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16})' .; then
  printf 'FAIL: possible credential or private key found\n' >&2
  exit 1
fi

# The note payload must travel over stdin; QML must not interpolate it into a shell command.
grep -Fq 'stdinEnabled = true' QuickCapture.qml
grep -Fq 'write(root.pendingMarkdown)' QuickCapture.qml
grep -Fq 'item: root.interactionReleased ? card : null' QuickCapture.qml
grep -Fq 'WlrKeyboardFocus.OnDemand' QuickCapture.qml
grep -Fq 'onBackingWindowVisibleChanged: if (backingWindowVisible && root.opened)' QuickCapture.qml
grep -Fq 'id: releaseArea' QuickCapture.qml
grep -Fq 'editorFocused: editor.activeFocus' QuickCapture.qml
grep -Fq 'id: dragHandle' QuickCapture.qml
grep -Fq 'id: positionFile' QuickCapture.qml
if grep -Fq 'id: closeButton' QuickCapture.qml; then
  printf 'FAIL: close button should not be present\n' >&2
  exit 1
fi
if grep -RniE --exclude-dir=.git --exclude='test-release.sh' '\beval\b' .; then
  printf 'FAIL: unsafe eval found\n' >&2
  exit 1
fi

printf 'PASS: release checks\n'
