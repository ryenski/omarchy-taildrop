import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

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

  // Shares the [menu] surface tokens so themes that style the menu style us.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(560), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(420), panel.height - Style.gapsOut * 2)

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
    root.opened = true
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
      height: root.cardHeight
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
          if (event.key === Qt.Key_Escape) {
            root.dismiss()
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Row {
          width: parent.width
          spacing: Style.spacing.lg

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

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: "Scaffold — device tiles and the payload footer land in the next step."
          color: root.foreground
          opacity: 0.58
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          wrapMode: Text.WordWrap
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          text: "payload: " + JSON.stringify(root.payload)
          color: root.foreground
          opacity: 0.58
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
