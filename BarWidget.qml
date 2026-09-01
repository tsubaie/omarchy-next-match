import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar pill for the next fixture. All state and fetching live in Panel.qml —
// this reads the label off it and owns only the button. Same split the
// first-party clock and weather widgets use.
BarWidget {
  id: root
  moduleName: "tsubaie.next-match"

  // Sanitized: the label renders through a Text using AutoText, which would
  // rich-text-parse a crafted setting out of shell.json.
  readonly property string icon: Model.plainText(setting("icon", "⚽"))
  readonly property bool hideWhenIdle: setting("hideWhenIdle", false) === true

  readonly property string pillText: panelLoader.item ? panelLoader.item.pillLabel : ""
  readonly property bool configured: panelLoader.item ? panelLoader.item.configured : false
  readonly property bool idle: panelLoader.item ? panelLoader.item.idle : false
  readonly property string homeName: panelLoader.item ? panelLoader.item.homeName : ""
  readonly property string awayName: panelLoader.item ? panelLoader.item.awayName : ""
  readonly property string homeBadgeUrl: panelLoader.item ? panelLoader.item.homeBadgeUrl : ""
  readonly property string awayBadgeUrl: panelLoader.item ? panelLoader.item.awayBadgeUrl : ""
  readonly property string barMiddle: panelLoader.item ? panelLoader.item.barMiddle : ""
  readonly property string barTrailing: panelLoader.item ? panelLoader.item.barTrailing : ""

  // The full fixture is only drawn when there is one and the bar runs
  // horizontally; a vertical bar gets the icon alone, and anything else (no
  // team picked, an error, nothing scheduled) falls back to the plain label.
  readonly property bool showFixture: !root.vertical && root.homeName !== "" && root.awayName !== ""

  // An unconfigured widget still has to be visible, or the settings that fix it
  // are unreachable from the bar it is missing from.
  readonly property bool concealSelf: hideWhenIdle && configured && idle

  readonly property string label: concealSelf ? "" : (pillText === "" ? "…" : pillText)

  // A crest is drawn only once it has actually loaded; until then the row is
  // just the names, which is better than a gap that pops.
  readonly property bool homeBadgeReady: homeBadge.status === Image.Ready && root.homeBadgeUrl !== ""
  readonly property bool awayBadgeReady: awayBadge.status === Image.Ready && root.awayBadgeUrl !== ""

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function refresh() {
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh(true)
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for shell.summon/hide/toggle routing: Bar.findPanelWidget
  // requires open/close/opened on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey()
  }

  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  implicitWidth: concealSelf ? 0 : button.implicitWidth
  implicitHeight: concealSelf ? 0 : button.implicitHeight
  visible: !concealSelf

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "tsubaie.next-match"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function refresh(): void { root.refresh() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // The button stays the interaction surface, but the crest and label are
    // drawn separately so an image can sit in the run of text.
    text: " "
    fixedWidth: labelRow.implicitWidth + scaledHorizontalMargin * 2
    foreground: "transparent"
    active: panelLoader.item ? panelLoader.item.needsAttention : false
    tooltipText: panelLoader.item ? panelLoader.item.tooltip : ""

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }

  Row {
    id: labelRow
    anchors.left: button.left
    anchors.leftMargin: button.scaledHorizontalMargin
    anchors.verticalCenter: button.verticalCenter
    spacing: Style.space(5)

    readonly property real crest: Math.round(button.fontSize * 1.3)
    readonly property color ink: button.active && button.useActiveColor
      ? button.activeColor
      : (root.bar ? root.bar.barForeground : Color.foreground)

    // Fallback: the icon, shown when there is no fixture to draw.
    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: !root.showFixture
      text: root.icon
      textFormat: Text.PlainText
      color: labelRow.ink
      font.family: button.fontFamily
      font.pixelSize: button.fontSize
      renderType: Text.NativeRendering
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: !root.showFixture && !root.vertical
      text: root.label
      textFormat: Text.PlainText
      color: labelRow.ink
      font.family: button.fontFamily
      font.pixelSize: button.fontSize
      renderType: Text.NativeRendering
    }

    // Home crest, home club, "v" or the score, away club, away crest, then the
    // countdown or the clock.
    Image {
      id: homeBadge
      anchors.verticalCenter: parent.verticalCenter
      width: root.showFixture && root.homeBadgeReady ? labelRow.crest : 0
      height: width
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      cache: true
      visible: root.showFixture && root.homeBadgeReady
      // Cap the decode: crests are ~500px PNGs going into a slot the height of
      // a line of bar text.
      sourceSize.width: Math.round(button.fontSize * 2.6)
      sourceSize.height: Math.round(button.fontSize * 2.6)
      source: root.homeBadgeUrl
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.showFixture
      text: root.homeName
      textFormat: Text.PlainText
      color: labelRow.ink
      font.family: button.fontFamily
      font.pixelSize: button.fontSize
      renderType: Text.NativeRendering
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.showFixture
      text: root.barMiddle
      textFormat: Text.PlainText
      color: Qt.darker(labelRow.ink, 1.35)
      font.family: button.fontFamily
      font.pixelSize: button.fontSize
      renderType: Text.NativeRendering
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.showFixture
      text: root.awayName
      textFormat: Text.PlainText
      color: labelRow.ink
      font.family: button.fontFamily
      font.pixelSize: button.fontSize
      renderType: Text.NativeRendering
    }

    Image {
      id: awayBadge
      anchors.verticalCenter: parent.verticalCenter
      width: root.showFixture && root.awayBadgeReady ? labelRow.crest : 0
      height: width
      fillMode: Image.PreserveAspectFit
      asynchronous: true
      cache: true
      visible: root.showFixture && root.awayBadgeReady
      sourceSize.width: Math.round(button.fontSize * 2.6)
      sourceSize.height: Math.round(button.fontSize * 2.6)
      source: root.awayBadgeUrl
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.showFixture && root.barTrailing !== ""
      text: "  " + root.barTrailing
      textFormat: Text.PlainText
      color: Qt.darker(labelRow.ink, 1.35)
      font.family: button.fontFamily
      font.pixelSize: button.fontSize
      renderType: Text.NativeRendering
    }
  }
}
