import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Share-sheet overlay for Taildrop. The shell loads this as an `overlay`
// plugin and drives it through the duck-typed contract: open(payloadJson),
// close(), and the `opened` flag. dismiss() is the plugin-initiated close that
// also tells the shell, so its open-panel bookkeeping stays in sync.
Item {
  id: root

  // Injected by the shell when present on the entry point.
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string pluginId: (root.manifest && root.manifest.id) || "io.github.ryenski.taildrop"

  property bool opened: false
  property var payload: ({})

  // loading | running | stopped | needsLogin | noFileSharing | notInstalled | error
  property string status: "loading"
  property string statusMessage: ""
  property int onlineCount: 0
  property bool refreshing: false

  // Tiles are sorted online-first, so the selectable ones are the first
  // `onlineCount` entries and the cursor only ever walks that prefix.
  property int cursorIndex: 0
  property bool cursorActive: false
  property string lastChoice: ""

  // What will be sent. kind: staging | text | image | files | none | sensitive
  property string payloadKind: "staging"
  property string payloadSource: ""     // selection | clipboard | nautilus | chooser
  property string payloadPath: ""       // staged clipboard file
  property string payloadPreview: ""
  property int payloadBytes: 0
  property string payloadMime: ""
  property var payloadFiles: []
  property int payloadStamp: 0          // bumps so the thumbnail reloads a same-named file
  readonly property bool payloadReady: payloadKind === "text" || payloadKind === "image" || payloadKind === "files"
  readonly property string sendSh: localPath(Qt.resolvedUrl("send.sh"))

  // Shares the [menu] surface tokens so themes that style the menu style us.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  readonly property color dim: Util.alpha(foreground, 0.58)
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.lg
  property int cardWidth: Math.min(Style.space(600), panel.width - Style.gapsOut * 2)

  property int cellWidth: Style.space(132)
  property int cellHeight: Style.space(96)
  readonly property int gridWidth: cardWidth - contentMargin * 2
  readonly property int columns: Math.max(1, Math.floor(gridWidth / cellWidth))
  readonly property int rows: Math.ceil(tileModel.count / columns)
  readonly property int maxGridHeight: Math.min(cellHeight * 3, panel.height - Style.space(260))
  readonly property int bodyHeight: root.status === "running" && tileModel.count > 0
    ? Math.min(maxGridHeight, rows * cellHeight)
    : Style.space(120)

  // Files next to this QML (send.sh) are addressed by absolute path, since the
  // public manifest hides the plugin's source directory.
  function localPath(url) {
    var result = String(url || "")
    if (result.indexOf("file://") === 0) result = result.slice(7)
    try { return decodeURIComponent(result) } catch (e) { return result }
  }

  function parsePayload(payloadJson) {
    if (!payloadJson) return {}
    try {
      var parsed = JSON.parse(payloadJson)
      return (parsed && typeof parsed === "object") ? parsed : {}
    } catch (e) {
      console.warn("taildrop: ignoring invalid payload: " + payloadJson)
      return {}
    }
  }

  function open(payloadJson) {
    root.payload = parsePayload(payloadJson)
    root.lastChoice = ""
    root.opened = true
    // Force a rebuild so a `target` in the payload can move the cursor.
    root.tileSignature = ""
    root.refresh()
    var files = Array.isArray(root.payload.files) ? root.payload.files.filter(function(f) { return typeof f === "string" && f !== "" }) : []
    if (files.length > 0) setFilesPayload(files, String(root.payload.source || "files"))
    else stageClipboard(false)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId)
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function setFilesPayload(files, source) {
    root.payloadFiles = files
    root.payloadSource = source
    root.payloadPath = ""
    root.payloadBytes = 0
    root.payloadPreview = files.map(function(f) { return String(f).split("/").pop() }).join(", ")
    root.payloadKind = "files"
  }

  function stageClipboard(clipboardOnly) {
    if (stageProcess.running) return
    root.payloadKind = "staging"
    root.payloadFiles = []
    stageProcess.command = clipboardOnly
      ? [root.sendSh, "stage-clipboard", "--no-primary"]
      : [root.sendSh, "stage-clipboard"]
    stageProcess.running = true
  }

  function applyStaged(exitCode, stdout) {
    var info = {}
    try { info = JSON.parse(String(stdout || "").trim() || "{}") } catch (e) { info = {} }
    var kind = String(info.kind || "")
    if (exitCode !== 0 || kind === "") {
      root.payloadKind = "none"
      root.payloadPreview = ""
      console.warn("taildrop: stage-clipboard failed (exit " + exitCode + "): " + stdout)
      return
    }
    root.payloadSource = String(info.source || "")
    root.payloadPath = String(info.path || "")
    root.payloadBytes = Number(info.bytes || 0)
    root.payloadMime = String(info.mime || "")
    root.payloadPreview = String(info.preview || "")
    root.payloadStamp = root.payloadStamp + 1
    root.payloadKind = kind
  }

  // Human label for the footer chip.
  readonly property string payloadLabel: {
    if (payloadKind === "files") return payloadFiles.length === 1 ? "1 file" : payloadFiles.length + " files"
    if (payloadKind === "image") return "Image"
    if (payloadKind === "text") return payloadSource === "selection" ? "Selection" : "Clipboard"
    if (payloadKind === "staging") return "Reading clipboard…"
    if (payloadKind === "sensitive") return "Clipboard is private"
    return "Nothing to send"
  }
  readonly property string payloadDetail: {
    if (payloadKind === "image") return payloadMime.replace("image/", "").toUpperCase() + " from the clipboard · " + formatBytes(payloadBytes)
    if (payloadKind === "sensitive") return "Your password manager marked it — copy something else"
    if (payloadKind === "none") return "Highlight or copy text, or press f to pick files"
    return payloadPreview
  }
  readonly property string payloadGlyph: {
    if (payloadKind === "files") return "󰈔"
    if (payloadKind === "image") return "󰋩"
    if (payloadKind === "text") return payloadSource === "selection" ? "󰗧" : "󰅇"
    if (payloadKind === "sensitive") return "󰌾"
    return "󰅇"
  }

  function formatBytes(n) {
    if (n < 1024) return n + " B"
    if (n < 1024 * 1024) return (n / 1024).toFixed(0) + " KB"
    return (n / (1024 * 1024)).toFixed(1) + " MB"
  }

  function refresh() {
    if (statusProcess.running) return
    root.refreshing = true
    statusProcess.running = true
  }

  function applyStatus(exitCode, stdout, stderr) {
    root.refreshing = false
    if (exitCode === 127) {
      setStatus("notInstalled", "The tailscale command is not installed")
      return
    }
    if (exitCode !== 0) {
      var detail = String(stderr || "").trim().split("\n")[0]
      setStatus("stopped", detail || "Tailscale is not running")
      return
    }
    var parsed = Model.parseStatus(stdout)
    if (parsed.state !== "running") {
      setStatus(parsed.state, parsed.message)
      return
    }
    root.statusMessage = ""
    root.status = "running"
    root.onlineCount = parsed.onlineCount
    rebuildTiles(parsed.peers)
  }

  function setStatus(state, message) {
    root.status = state
    root.statusMessage = message || ""
    root.onlineCount = 0
    tileModel.clear()
    root.cursorActive = false
  }

  // Rebuilding the model re-creates every delegate, and a fresh delegate
  // under the pointer reports hover and steals the cursor. So only rebuild
  // when the device list actually changed.
  property string tileSignature: ""

  function rebuildTiles(peers) {
    var signature = peers.map(function(p) { return p.target + "|" + p.name + "|" + (p.online ? 1 : 0) }).join("\n")
    if (signature === root.tileSignature && tileModel.count === peers.length) return
    root.tileSignature = signature

    var keepTarget = root.cursorActive && root.cursorIndex < tileModel.count
      ? tileModel.get(root.cursorIndex).target : ""
    var preselect = String(root.payload.target || "")

    tileModel.clear()
    for (var i = 0; i < peers.length; i++) {
      var p = peers[i]
      tileModel.append({
        name: p.name,
        target: p.target,
        icon: p.icon,
        caption: p.online ? Model.osLabel(p.os) : "offline",
        online: p.online
      })
    }

    var next = -1
    for (var j = 0; j < root.onlineCount; j++) {
      var t = tileModel.get(j).target
      if (t === keepTarget || (next < 0 && preselect !== "" && (t === preselect || tileModel.get(j).name === preselect))) {
        next = j
        if (t === keepTarget) break
      }
    }
    if (next < 0 && root.onlineCount > 0) next = 0
    root.cursorIndex = Math.max(0, next)
    root.cursorActive = next >= 0
  }

  function moveCursor(delta) {
    if (root.onlineCount === 0) return
    if (!root.cursorActive) {
      root.cursorActive = true
      root.cursorIndex = delta < 0 ? root.onlineCount - 1 : 0
      return
    }
    root.cursorIndex = (root.cursorIndex + delta + root.onlineCount) % root.onlineCount
    tileGrid.positionViewAtIndex(root.cursorIndex, GridView.Contain)
  }

  function moveCursorRow(delta) {
    if (root.onlineCount === 0) return
    if (!root.cursorActive) { moveCursor(delta); return }
    var next = root.cursorIndex + delta * root.columns
    if (next < 0 || next >= root.onlineCount) return
    root.cursorIndex = next
    tileGrid.positionViewAtIndex(root.cursorIndex, GridView.Contain)
  }

  function activateTile(index) {
    if (index < 0 || index >= root.onlineCount) return
    if (!root.payloadReady) return
    var tile = tileModel.get(index)
    // Sending lands in a later step; for now record the choice.
    root.lastChoice = tile.name
  }

  ListModel { id: tileModel }

  Process {
    id: statusProcess
    // Resolve the binary here so a missing CLI is one exit code rather than
    // a failed spawn.
    command: ["bash", "-c", "command -v tailscale >/dev/null || exit 127; exec tailscale status --json"]
    stdout: StdioCollector { id: statusStdout; waitForEnd: true }
    stderr: StdioCollector { id: statusStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.applyStatus(exitCode, statusStdout.text, statusStderr.text)
    }
  }

  Process {
    id: stageProcess
    stdout: StdioCollector { id: stageStdout; waitForEnd: true }
    onExited: function(exitCode) {
      root.applyStaged(exitCode, stageStdout.text)
    }
  }

  // Devices flip online as the user opens Tailscale on them; keep the tiles
  // honest while the sheet is up without hammering the daemon.
  Timer {
    interval: 3000
    repeat: true
    running: root.opened
    onTriggered: root.refresh()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-taildrop"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: card.contentTopInset + content.implicitHeight + card.contentBottomInset
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          var key = event.key
          var text = String(event.text || "").toLowerCase()
          if (key === Qt.Key_Escape) {
            root.dismiss()
          } else if (key === Qt.Key_Left || (key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
            root.moveCursor(-1)
          } else if (key === Qt.Key_Right || key === Qt.Key_Tab || key === Qt.Key_Backtab) {
            root.moveCursor(key === Qt.Key_Backtab ? -1 : 1)
          } else if (key === Qt.Key_Up) {
            root.moveCursorRow(-1)
          } else if (key === Qt.Key_Down) {
            root.moveCursorRow(1)
          } else if (key === Qt.Key_Return || key === Qt.Key_Enter || key === Qt.Key_Space) {
            if (root.cursorActive) root.activateTile(root.cursorIndex)
          } else if (text === "r") {
            root.refresh()
          } else if (text === "c") {
            root.stageClipboard(true)
          } else {
            return
          }
          event.accepted = true
        }
      }

      Column {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        // Header: glyph, title, refresh.
        Item {
          width: parent.width
          height: Math.max(titleRow.implicitHeight, refreshButton.implicitHeight)

          Row {
            id: titleRow
            spacing: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter

            Text {
              textFormat: Text.PlainText
              text: "󰒊"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              textFormat: Text.PlainText
              text: "Send via Taildrop"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              anchors.verticalCenter: parent.verticalCenter
            }
          }

          PanelActionButton {
            id: refreshButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰑐"
            tooltipText: "Refresh devices"
            foreground: root.foreground
            fontFamily: root.fontFamily
            opacity: root.refreshing ? 0.4 : 1
            onClicked: root.refresh()
          }
        }

        // Body: device tiles, or a message explaining why there are none.
        Item {
          width: parent.width
          height: root.bodyHeight

          GridView {
            id: tileGrid
            anchors.fill: parent
            visible: root.status === "running" && tileModel.count > 0
            model: tileModel
            clip: true
            cellWidth: root.cellWidth
            cellHeight: root.cellHeight
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            delegate: Item {
              id: tile
              required property int index
              required property string name
              required property string target
              required property string icon
              required property string caption
              required property bool online

              readonly property bool hasCursor: root.cursorActive && index === root.cursorIndex

              width: root.cellWidth
              height: root.cellHeight

              CursorSurface {
                anchors.fill: parent
                anchors.margins: Style.spacing.xs
                hasCursor: tile.hasCursor
                foreground: root.foreground
                opacity: tile.online ? 1 : 0.4

                Column {
                  anchors.centerIn: parent
                  width: parent.width - Style.spacing.lg * 2
                  spacing: Style.spacing.xxs

                  Text {
                    textFormat: Text.PlainText
                    text: tile.icon
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.display
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: tile.name
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                  }

                  Text {
                    textFormat: Text.PlainText
                    text: tile.caption
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                  }
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: tile.online
                enabled: tile.online
                cursorShape: tile.online ? Qt.PointingHandCursor : Qt.ArrowCursor
                onContainsMouseChanged: if (containsMouse) {
                  root.cursorActive = true
                  root.cursorIndex = tile.index
                }
                onClicked: {
                  root.cursorActive = true
                  root.cursorIndex = tile.index
                  root.activateTile(tile.index)
                }
              }
            }
          }

          Column {
            anchors.centerIn: parent
            width: parent.width
            spacing: Style.spacing.md
            visible: !tileGrid.visible

            Text {
              textFormat: Text.PlainText
              text: root.status === "loading" ? "󰑐" : (root.status === "running" ? "󰒊" : "󰅙")
              color: root.foreground
              opacity: 0.8
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              textFormat: Text.PlainText
              text: {
                if (root.status === "loading") return "Reading your tailnet…"
                if (root.status === "running") return "No devices can receive right now"
                return root.statusMessage
              }
              color: root.foreground
              opacity: 0.85
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              text: {
                if (root.status === "running") return "Open Tailscale on the device — this list refreshes on its own."
                if (root.status === "stopped") return "Start it with `tailscale up`, then press r."
                if (root.status === "needsLogin") return "Run `tailscale up` in a terminal to sign in."
                return ""
              }
              visible: text !== ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
            }
          }
        }

        // Status line for offline-but-listed devices when the grid is up.
        Text {
          textFormat: Text.PlainText
          visible: tileGrid.visible && root.onlineCount < tileModel.count
          width: parent.width
          text: root.onlineCount === 0
            ? "None of your devices can receive right now — open Tailscale on one and it will light up."
            : (tileModel.count - root.onlineCount) + " offline"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // Footer: what will be sent, and the key hints.
        Item {
          width: parent.width
          height: Math.max(payloadChip.implicitHeight, footerRow.implicitHeight)

          Row {
            id: payloadChip
            anchors.left: parent.left
            anchors.right: footerRow.left
            anchors.rightMargin: Style.spacing.xl
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.lg

            Image {
              id: thumbnail
              visible: root.payloadKind === "image" && root.payloadPath !== ""
              source: visible ? Util.fileUrl(root.payloadPath) + "?" + root.payloadStamp : ""
              cache: false
              asynchronous: true
              fillMode: Image.PreserveAspectFit
              height: Style.space(40)
              width: visible ? Math.max(Style.space(24), Math.min(Style.space(96), implicitWidth * (height / Math.max(1, implicitHeight)))) : 0
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              textFormat: Text.PlainText
              visible: !thumbnail.visible
              text: root.payloadGlyph
              color: root.payloadReady ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.iconLarge
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              width: payloadChip.width - payloadChip.spacing - (thumbnail.visible ? thumbnail.width : Style.font.iconLarge)
              spacing: Style.spacing.xxs
              anchors.verticalCenter: parent.verticalCenter

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: root.lastChoice ? root.payloadLabel + " → " + root.lastChoice + " (sending lands in step 4)" : root.payloadLabel
                color: root.payloadReady ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                visible: text !== ""
                text: root.payloadDetail
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }
          }

          Row {
            id: footerRow
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.spacing.xl

            Repeater {
              model: [["↵", "send"], ["c", "clipboard"], ["r", "refresh"], ["esc", "close"]]

              Row {
                required property var modelData
                spacing: Style.spacing.xs

                Text {
                  textFormat: Text.PlainText
                  text: parent.modelData[0]
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                Text {
                  textFormat: Text.PlainText
                  text: parent.modelData[1]
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }
      }
    }
  }
}
