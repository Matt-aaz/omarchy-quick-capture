.pragma library

function expandHome(path, home) {
  var value = String(path || "").trim()
  if (value === "~") return String(home || "")
  if (value.indexOf("~/") === 0) return String(home || "").replace(/\/$/, "") + value.slice(1)
  if (value.charAt(0) === "/") return value
  return ""
}

function normalizeTags(value) {
  var raw = []
  if (Array.isArray(value)) raw = value
  else if (typeof value === "string") raw = value.split(/[\s,]+/)

  var out = []
  for (var i = 0; i < raw.length; i++) {
    var tag = String(raw[i] || "").trim().replace(/^#+/, "")
    if (!tag) continue
    var rendered = "#" + tag
    if (out.indexOf(rendered) === -1) out.push(rendered)
  }
  return out.join(" ")
}

function pad(value, width) {
  var text = String(value)
  while (text.length < width) text = "0" + text
  return text
}

function formatTimestamp(date, format) {
  var d = date || new Date()
  var replacements = {
    "%Y": pad(d.getFullYear(), 4),
    "%m": pad(d.getMonth() + 1, 2),
    "%d": pad(d.getDate(), 2),
    "%H": pad(d.getHours(), 2),
    "%M": pad(d.getMinutes(), 2),
    "%S": pad(d.getSeconds(), 2),
    "%%": "%"
  }
  return String(format || "%Y-%m-%d %H:%M").replace(/%%|%[YmdHMS]/g, function(token) {
    return replacements[token] !== undefined ? replacements[token] : token
  })
}

function buildSource(app, windowTitle, includeApp, includeWindowTitle) {
  var parts = []
  if (includeApp && String(app || "").trim()) parts.push(String(app).trim())
  if (includeWindowTitle && String(windowTitle || "").trim()) {
    var title = String(windowTitle).trim()
    if (parts.length === 0 || title !== parts[0]) parts.push(title)
  }
  return parts.length ? "Source: " + parts.join(" — ") : ""
}

function renderTemplate(templateText, values) {
  var output = String(templateText || "{{content}}")
  var keys = ["timestamp", "tags", "content", "app", "window_title", "source"]
  for (var i = 0; i < keys.length; i++) {
    var key = keys[i]
    var value = values && values[key] !== undefined ? String(values[key]) : ""
    output = output.split("{{" + key + "}}").join(value)
  }

  var lines = output.replace(/\r\n/g, "\n").split("\n")
  var compact = []
  var blank = false
  for (var j = 0; j < lines.length; j++) {
    var line = lines[j].replace(/[ \t]+$/g, "")
    // If an optional placeholder was the only content in a Markdown heading,
    // remove the now-empty marker line instead of storing a stray "##".
    if (/^\s*#{1,6}\s*$/.test(line)) line = ""
    if (!line.trim()) {
      if (compact.length && !blank) compact.push("")
      blank = true
    } else {
      compact.push(line)
      blank = false
    }
  }
  while (compact.length && compact[compact.length - 1] === "") compact.pop()
  return compact.join("\n").replace(/^\s+|\s+$/g, "")
}

function clampCardPosition(x, y, panelWidth, panelHeight, cardWidth, cardHeight) {
  var maxX = Math.max(0, Number(panelWidth) - Number(cardWidth))
  var maxY = Math.max(0, Number(panelHeight) - Number(cardHeight))
  return {
    x: Math.round(Math.max(0, Math.min(Number(x) || 0, maxX))),
    y: Math.round(Math.max(0, Math.min(Number(y) || 0, maxY)))
  }
}

function savedCardPosition(raw, screenName, panelWidth, panelHeight, cardWidth, cardHeight) {
  try {
    var parsed = JSON.parse(String(raw || ""))
    if (!parsed || String(parsed.screen || "") !== String(screenName || "")) return null
    var x = Number(parsed.x)
    var y = Number(parsed.y)
    if (!isFinite(x) || !isFinite(y)) return null
    return clampCardPosition(x, y, panelWidth, panelHeight, cardWidth, cardHeight)
  } catch (e) {
    return null
  }
}

function initialCardPosition(panelWidth, panelHeight, cardWidth, cardHeight, position, gap) {
  var x = (Number(panelWidth) - Number(cardWidth)) / 2
  var y
  var mode = String(position || "center").toLowerCase()
  if (mode === "top") y = Math.max(Number(gap) || 0, Number(panelHeight) * 0.12)
  else if (mode === "bottom") y = Math.max(Number(gap) || 0, Number(panelHeight) - Number(cardHeight) - Number(panelHeight) * 0.12)
  else y = (Number(panelHeight) - Number(cardHeight)) / 2
  return clampCardPosition(x, y, panelWidth, panelHeight, cardWidth, cardHeight)
}

function isEmptyCapture(content) {
  return String(content || "").trim().length === 0
}
