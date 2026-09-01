import QtQuick
import Quickshell.Io
import qs.Ui
import "Model.js" as Model

// Bar pill for the next fixture. All state and fetching live in Panel.qml —
// this reads the label off it and owns only the button. Same split the
// first-party clock and weather widgets use.
BarWidget {
  id: root
  moduleName: "tsubaie.next-match"

  // Sanitized: WidgetButton's Text uses AutoText, which would rich-text-parse
  // a crafted setting out of shell.json.
  readonly property string icon: Model.plainText(setting("icon", "⚽"))
  readonly property bool hideWhenIdle: setting("hideWhenIdle", false) === true

  readonly property string pillText: panelLoader.item ? panelLoader.item.pillLabel : ""
  readonly property bool configured: panelLoader.item ? panelLoader.item.configured : false
  readonly property bool idle: panelLoader.item ? panelLoader.item.idle : false

  // An unconfigured widget still has to be visible, or the settings that fix
  // it are unreachable from the bar it is missing from.
  readonly property bool concealSelf: hideWhenIdle && configured && idle

  readonly property string label: concealSelf ? "" : (pillText === "" ? "…" : pillText)

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

  // Forwarded so this widget can stand in for the panel as the bar's popout
  // identity.
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
    text: root.vertical ? root.icon : root.icon + "  " + root.label
    // Red while something needs the user: no key, bad key, quota gone.
    active: panelLoader.item ? panelLoader.item.needsAttention : false
    tooltipText: panelLoader.item ? panelLoader.item.tooltip : ""

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.togglePanel()
    }
  }
}
