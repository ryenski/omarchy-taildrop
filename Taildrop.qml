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

        // Footer: payload summary lands in the next step; for now the hints.
        Item {
          width: parent.width
          height: footerRow.implicitHeight

          Text {
            textFormat: Text.PlainText
            anchors.left: parent.left
            anchors.right: footerRow.left
            anchors.rightMargin: Style.spacing.lg
            anchors.verticalCenter: parent.verticalCenter
            text: root.lastChoice ? "Chose " + root.lastChoice + " (sending lands in step 4)" : "payload: " + JSON.stringify(root.payload)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Row {
            id: footerRow
            anchors.right: parent.right
            spacing: Style.spacing.xl

            Repeater {
              model: [["↵", "send"], ["r", "refresh"], ["esc", "close"]]

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
