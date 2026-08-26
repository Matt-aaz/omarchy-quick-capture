import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "CaptureLogic.js" as Logic

Item {
  id: root

  property var shell: null
  property var manifest: null
  readonly property string home: Quickshell.env("HOME")
  readonly property string pluginDir: manifest && manifest.__sourceDir ? String(manifest.__sourceDir) : ""
  readonly property string configPath: home + "/.config/omarchy/quick-capture.json"
  readonly property string positionPath: home + "/.local/state/omarchy/quick-capture-position.json"
  readonly property int maxNoteBytes: 256 * 1024
  readonly property int maxConfigBytes: 64 * 1024
  readonly property int maxPositionBytes: 4 * 1024
  readonly property string noteSizeError: "Note is too large (256 KiB maximum)."

  property bool opened: false
  property bool saving: false
  property string errorMessage: ""
  property string pendingMarkdown: ""
  property string pendingPosition: ""
  property string sourceApp: ""
  property string sourceWindowTitle: ""
  property var activeScreen: null
  property var config: defaultConfig()
  property string savedPositionRaw: ""
  property int cardX: 0
  property int cardY: 0
  property bool interactionReleased: false
  property bool pointerSampled: false
  property real pointerSampleX: 0
  property real pointerSampleY: 0
  property string lastCloseReason: ""
  property bool dismissRequested: false
  property string acceptedEditorText: ""
  property bool restoringEditorText: false

  readonly property color panelBackground: Color.menu.background
  readonly property color panelText: Color.menu.text
  readonly property color panelBorder: Color.menu.border

  readonly property color panelAccent: Color.accent
  readonly property color panelMuted: Color.muted
  readonly property color panelUrgent: Color.urgent
  readonly property int cardWidth: Math.min(numberSetting("panel_width", 700, 420, 1400), panel.width - Style.gapsOut * 2)
  readonly property int cardHeight: Math.min(numberSetting("panel_height", 230, 210, 900), panel.height - Style.gapsOut * 2)
  readonly property string destinationLabel: {
    var path = String(config.capture_file || "~/Documents/Notes/Capture.md")
    var parts = path.split("/")
    return "Append to " + (parts[parts.length - 1] || "Capture.md")
  }
  readonly property string sourceLine: Logic.buildSource(
    sourceApp,
    sourceWindowTitle,
    boolSetting("include_app", true),
    boolSetting("include_window_title", true)
  )
  readonly property string tagsLine: Logic.normalizeTags(config.default_tags)

  function defaultConfig() {
    return {
      capture_file: "~/Documents/Notes/Capture.md",
      default_tags: ["capture"],
      include_timestamp: true,
      timestamp_format: "%Y-%m-%d %H:%M",
      include_app: true,
      include_window_title: true,
      panel_width: 700,
      panel_height: 230,
      panel_position: "center",
      notify_on_save: false,
      template: "## {{timestamp}}\n{{tags}}\n\n{{content}}\n\n{{source}}"
    }
  }

  function boolSetting(name, fallback) {
    return config && typeof config[name] === "boolean" ? config[name] : fallback
  }

  function numberSetting(name, fallback, minimum, maximum) {
    var value = config ? Number(config[name]) : NaN
    if (!isFinite(value)) value = fallback
    return Math.max(minimum, Math.min(maximum, Math.round(value)))
  }

  function acceptEditorText(text) {
    if (restoringEditorText) return
    var candidate = String(text || "")
    if (Logic.utf8ByteLength(candidate) <= maxNoteBytes) {
      acceptedEditorText = candidate
      if (errorMessage === noteSizeError) errorMessage = ""
      return
    }

    restoringEditorText = true
    editor.text = acceptedEditorText
    restoringEditorText = false
    errorMessage = noteSizeError
    editor.forceActiveFocus()
  }

  function loadConfig(raw) {
    var next = defaultConfig()
    var rawText = String(raw || "")
    if (Logic.utf8ByteLength(rawText) > maxConfigBytes) {
      config = next
      errorMessage = "Configuration is too large (64 KiB maximum). Fix " + configPath + " and retry."
      return
    }
    try {
      var parsed = JSON.parse(rawText)
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        for (var key in parsed) next[key] = parsed[key]
      }
      errorMessage = ""
    } catch (e) {
      errorMessage = "Configuration is invalid. Fix " + configPath + " and retry."
    }
    config = next
  }

  function screenForFocusedMonitor() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    var screens = Quickshell.screens || []
    for (var i = 0; i < screens.length; i++) {
      if (String(screens[i].name || "") === name) return screens[i]
    }
    return screens.length ? screens[0] : null
  }

  function rememberSourceContext() {
    // Read this before the layer-shell surface maps and takes keyboard focus.
    var toplevel = ToplevelManager.activeToplevel
    sourceApp = toplevel ? String(toplevel.appId || "").trim() : ""
    sourceWindowTitle = toplevel ? String(toplevel.title || "").trim() : ""
  }

  function positionCard() {
    var screenName = activeScreen ? String(activeScreen.name || "") : ""
    var saved = Logic.savedCardPosition(
      savedPositionRaw,
      screenName,
      panel.width,
      panel.height,
      cardWidth,
      cardHeight
    )
    if (saved) {
      cardX = saved.x
      cardY = saved.y
      return
    }
    var point = Logic.initialCardPosition(
      panel.width,
      panel.height,
      cardWidth,
      cardHeight,
      config.panel_position,
      Style.gapsOut
    )
    cardX = point.x
    cardY = point.y
  }

  function moveCard(x, y) {
    var point = Logic.clampCardPosition(x, y, panel.width, panel.height, cardWidth, cardHeight)
    cardX = point.x
    cardY = point.y
  }

  function saveCardPosition() {
    if (!activeScreen) return
    pendingPosition = JSON.stringify({
      screen: String(activeScreen.name || ""),
      x: cardX,
      y: cardY
    }) + "\n"
    positionWriteProc.command = [pluginDir + "/bin/bounded-file", "replace", String(maxPositionBytes), positionPath]
    positionWriteProc.stdinEnabled = true
    positionWriteProc.running = true
  }

  function open(payloadJson) {
    rememberSourceContext()
    activeScreen = screenForFocusedMonitor()
    errorMessage = ""
    configReadProc.command = [pluginDir + "/bin/bounded-file", "read", String(maxConfigBytes), configPath]
    positionReadProc.command = [pluginDir + "/bin/bounded-file", "read", String(maxPositionBytes), positionPath]
    configReadProc.running = true
    positionReadProc.running = true
    interactionReleased = false
    pointerSampled = false
    opened = true
    positionTimer.restart()
    Qt.callLater(function() {
      editor.forceActiveFocus()
      editor.cursorPosition = editor.length
    })
  }

  function close() {
    if (!dismissRequested) lastCloseReason = "host-close"
    opened = false
    dismissRequested = false
  }

  function dismiss() {
    if (saving) return
    errorMessage = ""
    lastCloseReason = "user-dismiss"
    dismissRequested = true
    if (shell && typeof shell.hide === "function")
      shell.hide((manifest && manifest.id) || "quick-capture")
    else {
      opened = false
      dismissRequested = false
    }
  }

  function renderCapture(content) {
    var timestamp = boolSetting("include_timestamp", true)
      ? Logic.formatTimestamp(new Date(), String(config.timestamp_format || "%Y-%m-%d %H:%M"))
      : ""
    return Logic.renderTemplate(String(config.template || "{{content}}"), {
      timestamp: timestamp,
      tags: tagsLine,
      content: String(content || "").trim(),
      app: sourceApp,
      window_title: sourceWindowTitle,
      source: sourceLine
    })
  }

  function save() {
    if (saving) return
    if (Logic.isEmptyCapture(editor.text)) {
      errorMessage = "Write something before saving."
      editor.forceActiveFocus()
      return
    }

    var path = Logic.expandHome(config.capture_file, home)
    if (!path) {
      errorMessage = "Capture path is invalid. Use ~/… or an absolute path."
      editor.forceActiveFocus()
      return
    }

    var markdown = renderCapture(editor.text)
    if (Logic.isEmptyCapture(markdown)) {
      errorMessage = "The configured template produced an empty note."
      editor.forceActiveFocus()
      return
    }
    if (Logic.utf8ByteLength(markdown) > maxNoteBytes) {
      errorMessage = noteSizeError
      editor.forceActiveFocus()
      return
    }

    errorMessage = ""
    pendingMarkdown = markdown
    saveProc.command = [pluginDir + "/bin/append-capture", path]
    saveProc.stdinEnabled = true
    saving = true
    saveProc.running = true
  }

  // Minimal operational state for shell health checks. Never add draft,
  // destination, source-context, error, or geometry data here.
  function status(_arg) {
    return JSON.stringify({
      opened: opened,
      saving: saving,
      panelVisible: panel.visible
    })
  }

  Process {
    id: configReadProc
    stdout: StdioCollector { id: configReadOut; waitForEnd: true }
    stderr: StdioCollector { id: configReadError; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode === 0 && configReadOut.text) root.loadConfig(configReadOut.text)
      else if (exitCode === 0) {
        root.config = root.defaultConfig()
        root.errorMessage = ""
      }
      else {
        root.config = root.defaultConfig()
        var detail = String(configReadError.text || "")
        root.errorMessage = detail.indexOf("exceeds") >= 0
          ? "Configuration is too large (64 KiB maximum). Fix " + root.configPath + " and retry."
          : "Configuration could not be read. Fix " + root.configPath + " and retry."
      }
    }
  }

  Process {
    id: positionReadProc
    stdout: StdioCollector { id: positionReadOut; waitForEnd: true }
    onExited: function(exitCode) {
      root.savedPositionRaw = exitCode === 0 ? positionReadOut.text : ""
      if (root.opened) positionTimer.restart()
    }
  }

  Process {
    id: positionWriteProc
    stdinEnabled: true
    onStarted: {
      write(root.pendingPosition)
      stdinEnabled = false
    }
  }

  Process {
    id: saveProc
    stdinEnabled: true
    stderr: StdioCollector {
      id: saveStderr
      waitForEnd: true
    }
    onStarted: {
      write(root.pendingMarkdown)
      // EOF tells the helper the complete payload arrived. The property is
      // re-enabled before every later save.
      stdinEnabled = false
    }
    onExited: function(exitCode) {
      var success = exitCode === 0
      root.saving = false
      if (!success) {
        var detail = String(saveStderr.text || "").trim()
        root.errorMessage = detail || "Could not save note. Check the destination and try again."
        editor.forceActiveFocus()
        return
      }

      // Data-loss invariant: text is cleared only after the helper exits 0,
      // after its append, lock, and fsync have all succeeded.
      editor.text = ""
      root.pendingMarkdown = ""
      root.errorMessage = ""
      if (root.boolSetting("notify_on_save", false))
        Quickshell.execDetached(["notify-send", "Quick Capture", "Note saved"])
      root.dismiss()
    }
  }

  Timer {
    id: positionTimer
    interval: 50
    onTriggered: if (root.opened) root.positionCard()
  }

  PanelWindow {
    id: panel
    screen: root.activeScreen
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "quick-capture"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.opened
      ? (root.interactionReleased ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
      : WlrKeyboardFocus.None

    // Mapping is asynchronous: focus the editor again once the layer-shell
    // backing window exists. Exclusive focus remains until the user moves the
    // pointer outside the card to interact with an underlying application.
    onBackingWindowVisibleChanged: if (backingWindowVisible && root.opened) {
      positionTimer.restart()
      Qt.callLater(function() { if (root.opened) editor.forceActiveFocus() })
    }

    // Initially cover the output so Exclusive reliably focuses the editor.
    // Once deliberate pointer movement reaches the area outside the card,
    // shrink the input region to the card and switch to OnDemand. The user's
    // following click then reaches the underlying application in one action.
    mask: Region {
      item: root.interactionReleased ? card : null
      width: root.interactionReleased ? 0 : panel.width
      height: root.interactionReleased ? 0 : panel.height
    }

    MouseArea {
      id: releaseArea
      anchors.fill: parent
      enabled: root.opened && !root.interactionReleased
      hoverEnabled: true
      acceptedButtons: Qt.NoButton

      onPositionChanged: function(mouse) {
        if (!root.pointerSampled) {
          root.pointerSampled = true
          root.pointerSampleX = mouse.x
          root.pointerSampleY = mouse.y
          return
        }
        if (Math.abs(mouse.x - root.pointerSampleX) + Math.abs(mouse.y - root.pointerSampleY) >= 3)
          root.interactionReleased = true
      }
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      x: root.cardX
      y: root.cardY
      radius: Math.max(0, Style.cornerRadius)
      color: root.panelBackground
      borderSpec: Border.flat(root.panelBorder, 1)
      padding: Style.space(6)

      MouseArea { anchors.fill: parent; onClicked: {} }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: Style.space(4)

        Item {
            width: parent.width
            height: Style.space(14)

            MouseArea {
                id: dragHandle
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton
                hoverEnabled: true
                cursorShape: pressed ? Qt.ClosedHandCursor : Qt.OpenHandCursor

                property real pressPointerX: 0
                property real pressPointerY: 0
                property real pressCardX: 0
                property real pressCardY: 0

                onPressed: function(mouse) {
                    pressPointerX = mouse.x + card.x
                    pressPointerY = mouse.y + card.y
                    pressCardX = card.x
                    pressCardY = card.y
                }

                onPositionChanged: function(mouse) {
                    if (!pressed) return

                    var pointerX = mouse.x + card.x
                    var pointerY = mouse.y + card.y

                    root.moveCard(
                        pressCardX + pointerX - pressPointerX,
                        pressCardY + pointerY - pressPointerY
                    )
                }

                onReleased: root.saveCardPosition()
            }

            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.verticalCenter: parent.verticalCenter

                width: Style.space(24)
                height: 2
                radius: 1

                color: root.panelMuted
                opacity: 0.55
            }
        }

        Item {
            width: parent.width
            height: Math.max(Style.space(60), parent.height - Style.space(55))

            ScrollView {
                anchors.fill: parent
                clip: true
                ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
                ScrollBar.vertical.policy: ScrollBar.AsNeeded

                TextArea {
                    id: editor

                    placeholderText: "Type a note…"
                    color: root.panelText
                    placeholderTextColor: root.panelMuted

                    selectionColor: Style.selectionFillFor(
                        root.panelText,
                        root.panelAccent
                    )
                    selectedTextColor: root.panelText

                    font.family: Style.font.family
                    font.pixelSize: Style.font.body

                    wrapMode: TextEdit.Wrap
                    background: null

                    padding: Style.space(4)
                    enabled: !root.saving
                    onTextChanged: root.acceptEditorText(text)

                    Keys.onPressed: function(event) {
                        if (event.key === Qt.Key_Escape) {
                            root.dismiss()
                            event.accepted = true
                        } else if (
                            (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                            && (event.modifiers & Qt.ControlModifier)
                        ) {
                            root.save()
                            event.accepted = true
                        }
                    }
                }
            }
        }

        Column {
            width: parent.width
            spacing: Style.space(3)

            // Reserved line for errors/messages
            Item {
                width: parent.width
                height: Style.space(16)

                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter

                    text: root.errorMessage

                    color: root.panelUrgent
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption

                    elide: Text.ElideRight
                }
            }

            // Shortcut line
            Row {
                id: shortcutRow
                spacing: Style.space(10)

                Row {
                    spacing: Style.space(4)

                    Rectangle {
                        width: escKey.implicitWidth + Style.space(6)
                        height: escKey.implicitHeight + Style.space(2)
                        radius: Style.space(1)

                        color: Style.normalFillFor(
                            root.panelText,
                            root.panelAccent
                        )

                        Text {
                            id: escKey
                            anchors.centerIn: parent
                            text: "Esc"
                            color: root.panelText
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                        }
                    }

                    Text {
                        text: "Cancel"
                        color: root.panelMuted
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                    }
                }

                Row {
                    spacing: Style.space(4)

                    Rectangle {
                        width: saveKey.implicitWidth + Style.space(6)
                        height: saveKey.implicitHeight + Style.space(2)
                        radius: Style.space(1)

                        color: Style.normalFillFor(
                            root.panelText,
                            root.panelAccent
                        )

                        Text {
                            id: saveKey
                            anchors.centerIn: parent
                            text: "Ctrl+Enter"
                            color: root.panelText
                            font.family: Style.font.family
                            font.pixelSize: Style.font.caption
                        }
                    }

                    Text {
                        text: root.saving ? "Saving…" : "Save"
                        color: root.panelMuted
                        font.family: Style.font.family
                        font.pixelSize: Style.font.caption
                    }
                }
            }
        }
      }
    }
  }
}
