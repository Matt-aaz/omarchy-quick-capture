import fs from "node:fs";
import assert from "node:assert/strict";
import vm from "node:vm";

const qml = fs.readFileSync(new URL("../QuickCapture.qml", import.meta.url), "utf8");

function functionBody(source, name) {
  const signature = new RegExp(`\\bfunction\\s+${name}\\s*\\([^)]*\\)\\s*\\{`, "m");
  const match = signature.exec(source);
  assert.ok(match, `missing function ${name}()`);
  const open = source.indexOf("{", match.index);
  let depth = 0;
  let quote = "";
  let escaped = false;
  for (let i = open; i < source.length; i += 1) {
    const ch = source[i];
    if (quote) {
      if (escaped) escaped = false;
      else if (ch === "\\") escaped = true;
      else if (ch === quote) quote = "";
      continue;
    }
    if (ch === '"' || ch === "'") {
      quote = ch;
      continue;
    }
    if (ch === "{") depth += 1;
    else if (ch === "}") {
      depth -= 1;
      if (depth === 0) return source.slice(open + 1, i);
    }
  }
  assert.fail(`unterminated function ${name}()`);
}

assert.doesNotMatch(qml, /\bfunction\s+setTextForTest\s*\(/, "production QML exposes draft mutation over IPC");
assert.doesNotMatch(qml, /\bfunction\s+saveForTest\s*\(/, "production QML exposes draft saving over IPC");

const status = functionBody(qml, "status");
const fields = [...status.matchAll(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:/gm)].map(match => match[1]);
assert.deepEqual(fields, ["opened", "saving", "panelVisible"], "status() must expose only the boolean operational allow-list");
assert.match(status, /opened\s*:\s*opened\b/);
assert.match(status, /saving\s*:\s*saving\b/);
assert.match(status, /panelVisible\s*:\s*panel\.visible\b/);
assert.doesNotMatch(
  status,
  /editor\.text|pendingMarkdown|errorMessage|captureFile|capture_file|sourceApp|sourceWindowTitle|activeScreen|lastCloseReason|card[XY]|(?:panel|card)(?:Width|Height)|editorFocused|interactionReleased|backingWindowVisible/,
  "status() exposes sensitive draft metadata or unnecessary operational detail"
);

assert.match(qml, /readonly property int maxNoteBytes:\s*256\s*\*\s*1024/);
assert.match(qml, /readonly property int maxConfigBytes:\s*64\s*\*\s*1024/);

const loadConfig = functionBody(qml, "loadConfig");
assert.match(loadConfig, /Logic\.utf8ByteLength\s*\([^)]*\)\s*>\s*maxConfigBytes/);
assert.ok(
  loadConfig.indexOf("utf8ByteLength") < loadConfig.indexOf("JSON.parse"),
  "config size must be checked before JSON parsing"
);
assert.match(loadConfig, /Configuration is too large/);

let parseCalled = false;
const configSandbox = {
  Logic: { utf8ByteLength: value => Buffer.byteLength(String(value), "utf8") },
  maxConfigBytes: 64 * 1024,
  configPath: "/home/test/.config/omarchy/quick-capture.json",
  config: null,
  errorMessage: "",
  defaultConfig: () => ({ capture_file: "default.md" }),
  JSON: { parse: () => { parseCalled = true; throw new Error("oversized config was parsed"); } },
};
const loadConfigForTest = vm.runInNewContext(`(function(raw) {${loadConfig}})`, configSandbox);
loadConfigForTest("x".repeat(64 * 1024 + 1));
assert.equal(parseCalled, false, "oversized config reached JSON.parse");
assert.deepEqual(configSandbox.config, { capture_file: "default.md" });
assert.match(configSandbox.errorMessage, /Configuration is too large \(64 KiB maximum\)/);

const save = functionBody(qml, "save");
assert.match(save, /Logic\.utf8ByteLength\s*\(markdown\)\s*>\s*maxNoteBytes/);
assert.ok(
  save.indexOf("utf8ByteLength(markdown)") < save.indexOf("saveProc.running = true"),
  "rendered note size must be checked before starting the helper"
);
assert.match(qml, /onTextChanged\s*:\s*root\.acceptEditorText\s*\(text\)/);

console.log("PASS: QML security and size-limit suite");
