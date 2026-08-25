import fs from "node:fs";
import vm from "node:vm";
import assert from "node:assert/strict";

const sourcePath = new URL("../CaptureLogic.js", import.meta.url);
if (!fs.existsSync(sourcePath)) throw new Error("CaptureLogic.js is missing");
const code = fs.readFileSync(sourcePath, "utf8").replace(/^\.pragma library\s*$/m, "");
const context = {};
vm.createContext(context);
vm.runInContext(code, context, { filename: "CaptureLogic.js" });

assert.equal(context.expandHome("~/Documents/Notes/Capture.md", "/home/test"), "/home/test/Documents/Notes/Capture.md");
assert.equal(context.expandHome("/tmp/Notes/Capture.md", "/home/test"), "/tmp/Notes/Capture.md");
assert.equal(context.expandHome("relative.md", "/home/test"), "");

assert.equal(context.normalizeTags(["capture", "#reading", "  later  "]), "#capture #reading #later");
assert.equal(context.normalizeTags("capture reading"), "#capture #reading");
assert.equal(context.normalizeTags([]), "");

const date = new Date(2026, 7, 22, 21, 3, 4);
assert.equal(context.formatTimestamp(date, "%Y-%m-%d %H:%M"), "2026-08-22 21:03");
assert.equal(context.formatTimestamp(date, "%d/%m/%Y %H:%M:%S"), "22/08/2026 21:03:04");

assert.equal(context.buildSource("Firefox", "Research article", true, true), "Source: Firefox — Research article");
assert.equal(context.buildSource("Reader", "Chapter 4", false, true), "Source: Chapter 4");
assert.equal(context.buildSource("Browser", "Documentation", true, false), "Source: Browser");
assert.equal(context.buildSource("", "", true, true), "");

const rendered = context.renderTemplate(
  "## {{timestamp}}\n{{tags}}\n\n{{content}}\n\n{{source}}",
  {
    timestamp: "2026-08-22 21:17",
    tags: "#capture #reading",
    content: "This section makes a useful distinction that I want to revisit later.",
    app: "Reader",
    window_title: "Chapter 4",
    source: "Source: Reader — Chapter 4"
  }
);
assert.equal(rendered, "## 2026-08-22 21:17\n#capture #reading\n\nThis section makes a useful distinction that I want to revisit later.\n\nSource: Reader — Chapter 4");

const noOptionalLines = context.renderTemplate(
  "## {{timestamp}}\n{{tags}}\n\n{{content}}\n\n{{source}}",
  { timestamp: "", tags: "", content: "Remember to revisit this tomorrow.", app: "", window_title: "", source: "" }
);
assert.equal(noOptionalLines, "Remember to revisit this tomorrow.");

assert.equal(context.isEmptyCapture("  \n\t"), true);
assert.equal(context.isEmptyCapture(" A thought. "), false);

assert.equal(context.utf8ByteLength("plain ASCII"), 11);
assert.equal(context.utf8ByteLength("café ✓"), 9);
assert.equal(context.utf8ByteLength("😀"), 4);
assert.equal(context.utf8ByteLength("a".repeat(256 * 1024)), 256 * 1024);
assert.equal(context.utf8ByteLength("a".repeat(256 * 1024) + "b"), 256 * 1024 + 1);

assert.equal(
  JSON.stringify(context.initialCardPosition(2400, 1350, 700, 320, "center", 5)),
  JSON.stringify({ x: 850, y: 515 })
);
assert.equal(
  JSON.stringify(context.initialCardPosition(2400, 1350, 700, 320, "top", 5)),
  JSON.stringify({ x: 850, y: 162 })
);
assert.equal(
  JSON.stringify(context.clampCardPosition(-20, 1400, 2400, 1350, 700, 320)),
  JSON.stringify({ x: 0, y: 1030 })
);

assert.equal(
  JSON.stringify(context.savedCardPosition('{"screen":"DP-1","x":120,"y":80}', "DP-1", 2400, 1350, 700, 260)),
  JSON.stringify({ x: 120, y: 80 })
);
assert.equal(
  JSON.stringify(context.savedCardPosition('{"screen":"DP-1","x":9999,"y":9999}', "DP-1", 2400, 1350, 700, 260)),
  JSON.stringify({ x: 1700, y: 1090 })
);
assert.equal(context.savedCardPosition('{"screen":"DP-2","x":120,"y":80}', "DP-1", 2400, 1350, 700, 260), null);
assert.equal(context.savedCardPosition('not json', "DP-1", 2400, 1350, 700, 260), null);

console.log("PASS: capture logic suite");
