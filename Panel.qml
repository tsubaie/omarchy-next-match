import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Owns the fixture data: settings, fetching, caching and pacing. BarWidget.qml
// reads `pillLabel` and `badgeUrl` off this and draws the button.
Panel {
  id: root
  moduleName: "tsubaie.next-match"
  ipcTarget: "tsubaie.next-match"
  manageIpc: false

  property var anchorItem: null
  property bool openedFromHotkey: false

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so everything the bar identifies a panel by must be that
  // widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ------------------------------------------------------------------ settings

  readonly property int teamId: Model.validTeamId(root.setting("teamId", 0))
  readonly property bool showLive: root.setting("showLive", true) === true
  readonly property bool showBadge: root.setting("showBadge", true) === true
  readonly property int baseMinutes: {
    var n = parseInt(root.setting("refreshMinutes", 60), 10)
    return isFinite(n) && n >= 15 ? n : 60
  }

  // TheSportsDB serves this widget on its shared key, so there is nothing to
  // paste. `apiKey` stays readable for anyone who wants their own rate limit
  // (omarchy bar set tsubaie.next-match apiKey <key>) but no field asks for it.
  readonly property string sdbKey: String(root.setting("apiKey", "")).trim()

  // A team is the only thing the widget actually needs.
  readonly property bool configured: teamId > 0

  // --------------------------------------------------------------------- state

  property var fixture: null
  property string errorText: ""
  property double lastFetchMs: 0
  property bool fetching: false
  property string lastUrl: ""
  property double lastUrlAt: 0

  // Advanced by a timer rather than read at each use site, so every binding
  // showing a countdown re-evaluates together.
  property double nowMs: Date.now()

  readonly property bool idle: configured && errorText === "" && fixture === null
  readonly property bool needsAttention: !configured || errorText !== ""

  readonly property string cachePath: Quickshell.env("HOME") + "/.cache/omarchy-next-match/fixture.json"
  property string fetchUrl: ""

  readonly property string badgeUrl: root.showBadge ? Model.opponentBadge(root.fixture, root.teamId) : ""

  // The bar draws both clubs, so it needs the parts rather than one string:
  // a crest cannot be interleaved into a Text.
  readonly property string homeName: root.sidesNow ? Model.plainText(root.sidesNow.home.name) : ""
  readonly property string awayName: root.sidesNow ? Model.plainText(root.sidesNow.away.name) : ""
  readonly property string homeBadgeUrl: root.showBadge && root.fixture && root.fixture.badges ? root.fixture.badges.home : ""
  readonly property string awayBadgeUrl: root.showBadge && root.fixture && root.fixture.badges ? root.fixture.badges.away : ""

  // "v" normally; the scoreline once it is being played.
  readonly property string barMiddle: {
    if (!root.fixture) return ""
    if (Model.matchState(root.fixture) === "live" && root.showLive) {
      var g = root.fixture.goals || {}
      var h = g.home === null || g.home === undefined ? 0 : g.home
      var a = g.away === null || g.away === undefined ? 0 : g.away
      return h + " - " + a
    }
    return "v"
  }

  // The clock or the countdown that trails the two clubs.
  readonly property string barTrailing: {
    if (!root.fixture) return ""
    var state = Model.matchState(root.fixture)
    if (state === "live" && root.showLive) {
      if (Model.statusShort(root.fixture) === "HT") return "HT"
      var el = root.fixture.fixture.status.elapsed
      return el ? el + "'" : "live"
    }
    if (state === "off") return "postponed"
    var ko = Model.kickoffMs(root.fixture)
    var delta = ko - root.nowMs
    if (!isFinite(delta)) return ""
    if (delta <= 0) return "kick-off"
    if (delta > 24 * 3600 * 1000) return root.whenParts ? Model.whenLabel(root.whenParts) : ""
    return "in " + Model.countdown(delta)
  }

  // Up to three fixtures after the one in the hero.
  property var laterFixtures: []

  readonly property var whenParts: {
    var ko = Model.kickoffMs(root.fixture)
    if (!isFinite(ko)) return null
    var d = new Date(ko)
    return { weekday: Qt.formatDateTime(d, "ddd"), time: Qt.formatDateTime(d, "HH:mm") }
  }

  readonly property string pillLabel: {
    if (teamId <= 0) return "Pick a team"
    if (errorText !== "") return errorText
    if (fixture === null) return lastFetchMs === 0 ? "…" : "No match"
    return Model.pillLabel(root.fixture, root.nowMs, {
      teamId: root.teamId,
      showLive: root.showLive,
      when: root.whenParts
    })
  }

  readonly property string tooltip: {
    if (!configured) return "Next Match — click to pick a team"
    if (errorText !== "") return "Next Match — " + errorText
    if (!fixture) return "Next Match — nothing scheduled"
    var s = Model.sides(root.fixture, root.teamId)
    return s ? s.home.name + " v " + s.away.name : "Next Match"
  }

  // ------------------------------------------------------------------ fetching

  function refresh(force) {
    if (!configured || fetchProc.running) return
    // A reload storm (theme switch, plugin rescan) must not re-fetch on every
    // pass: ignore anything inside a minute unless a human asked.
    if (!force && root.lastFetchMs > 0 && Date.now() - root.lastFetchMs < 60000) return
    var url = Model.sdbNextUrl(root.sdbKey, root.teamId)
    if (url === root.lastUrl && Date.now() - root.lastUrlAt < 5000) return
    root.lastUrl = url
    root.lastUrlAt = Date.now()
    root.fetchUrl = url
    root.fetching = true
    fetchProc.running = true
  }

  function applyPayload(payload, fromCache) {
    root.errorText = ""
    var all = Model.upcomingFixtures(Model.sdbFixtures(payload), Date.now(), 4)
    root.fixture = all.length > 0 ? all[0] : null
    root.laterFixtures = all.slice(1, 4)
    if (!fromCache) root.lastFetchMs = Date.now()
    scheduleNext()
  }

  function onFetched(raw) {
    root.fetching = false
    var text = String(raw || "").trim()
    if (text === "") {
      // curl failed (offline, DNS, timeout). Keep the last good fixture rather
      // than blanking the bar, and try again on the normal schedule.
      root.errorText = root.fixture ? "" : "Offline"
      scheduleNext()
      return
    }
    try {
      applyPayload(JSON.parse(text), false)
    } catch (e) {
      root.errorText = "Bad response"
      scheduleNext()
    }
  }

  function loadCache(text) {
    if (root.fixture !== null) return
    var raw = String(text || "").trim()
    if (raw === "") return
    try {
      applyPayload(JSON.parse(raw), true)
    } catch (e) {
      // A corrupt cache is not worth reporting; the next fetch overwrites it.
    }
  }

  function scheduleNext() {
    var mins = Model.refreshMinutes(root.fixture, root.nowMs, root.baseMinutes, root.showLive)
    refreshTimer.interval = Math.max(60000, mins * 60000)
    refreshTimer.restart()
  }

  onConfiguredChanged: if (configured) refresh(true)
  onTeamIdChanged: { root.fixture = null; root.laterFixtures = []; root.errorText = ""; if (configured) refresh(true) }

  Component.onCompleted: {
    cacheFile.reload()
    if (configured) refresh(true)
    scheduleNext()
  }

  // --------------------------------------------------------------------- timers

  // Drives the countdown text. Ticking a label is free; refetching is not.
  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  Timer {
    id: refreshTimer
    interval: 3600000
    running: root.configured
    repeat: true
    onTriggered: root.refresh(false)
  }

  // ---------------------------------------------------------------------- I/O

  FileView {
    id: cacheFile
    path: root.cachePath
    watchChanges: false
    printErrors: false
    onLoaded: root.loadCache(text())
    onLoadFailed: function(error) { /* no cache yet; the first fetch writes one */ }
  }

  // The URL travels in the environment and reaches curl through a config file
  // on stdin, so a personal key put in the path stays out of argv.
  Process {
    id: fetchProc
    running: false
    command: ["bash", "-c", root.fetchScript]
    environment: ({ "NM_URL": root.fetchUrl, "NM_CACHE": root.cachePath })
    // onStreamFinished fires even when curl dies early, with empty text, so
    // there is no need for an onExited handler to clear `fetching` as well.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onFetched(text)
    }
  }

  readonly property string fetchScript:
    'out=$(printf \'url = "%s"\\n\' "$NM_URL" | curl -fsS --max-time 20 -K -) || out=""\n' +
    'if [ -n "$out" ]; then mkdir -p "$(dirname "$NM_CACHE")" && printf %s "$out" > "$NM_CACHE".tmp && mv -f "$NM_CACHE".tmp "$NM_CACHE"; fi\n' +
    'printf %s "$out"\n'

  // ------------------------------------------------------------------ settings

  // Omarchy 4 renders no settings form for a third-party bar widget — the
  // manifest schema is metadata nothing consumes yet — so the plugin carries
  // its own. Writing goes through the shell's own updateEntryInline, the call
  // the built-in clock uses to persist a cycled format: in-process, and it
  // writes shell.json through the shell's FileView, which follows a symlink
  // instead of replacing it (the case if you stow your dotfiles).
  property bool showSettings: false
  readonly property bool settingsOpen: showSettings || !configured

  property string savedNote: ""
  property var searchResults: []
  property string searchNote: ""
  property bool searching: false
  property var searchQueue: []

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function pickTeam(id, name) {
    root.searchResults = []
    root.searchQueue = []
    root.searchNote = ""
    searchField.text = ""
    root.savedNote = "Now following " + name
    savedNoteTimer.restart()
    root.errorText = ""
    persistSettings({ teamId: id })
    root.showSettings = false
  }

  // TheSportsDB's club search misses on punctuation and is inconsistent about
  // alternate names, so one query is not enough: try the name, then the name
  // with punctuation loosened, then the same text as a league to browse. The
  // first that returns anything wins.
  function searchTeams() {
    var q = String(searchField.text).trim()
    if (!Model.searchValid(q)) { root.searchNote = "Type at least 3 characters"; return }
    if (searchProc.running) return

    var queue = []
    var variants = Model.sdbSearchVariants(q)
    for (var i = 0; i < variants.length; ++i)
      queue.push(Model.sdbSearchUrl(root.sdbKey, variants[i]))
    queue.push(Model.sdbLeagueTeamsUrl(root.sdbKey, q))

    root.searchQueue = queue
    root.searchResults = []
    root.searchNote = "Searching…"
    root.searching = true
    runNextSearch()
  }

  function runNextSearch() {
    if (root.searchQueue.length === 0) {
      root.searching = false
      root.searchNote = "Nothing matched. Try the full club name, or a league name to browse it."
      return
    }
    var queue = root.searchQueue.slice()
    root.searchUrl = queue.shift()
    root.searchQueue = queue
    searchProc.running = true
  }

  property string searchUrl: ""

  function onSearched(raw) {
    var text = String(raw || "").trim()
    var teams = []
    if (text !== "") {
      try { teams = Model.sdbTeams(JSON.parse(text)) } catch (e) { teams = [] }
    }
    if (teams.length === 0) { runNextSearch(); return }
    root.searching = false
    root.searchResults = teams
    root.searchNote = ""
  }

  Timer {
    id: savedNoteTimer
    interval: 2500
    onTriggered: root.savedNote = ""
  }

  Process {
    id: searchProc
    running: false
    command: ["bash", "-c", 'printf \'url = "%s"\\n\' "$NM_URL" | curl -fsS --max-time 20 -K -']
    environment: ({ "NM_URL": root.searchUrl })
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onSearched(text)
    }
  }

  // -------------------------------------------------------------- panel plumbing

  function open() {
    openedFromHotkey = false
    root.controller.show()
    root.refresh(false)
  }

  function openFromHotkey() {
    openedFromHotkey = true
    root.controller.show()
    root.refresh(false)
  }

  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.openFromHotkey() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  onOpenedChanged: if (opened) searchField.text = ""

  // ------------------------------------------------------------------- the popup

  readonly property color fg: root.bar ? root.bar.barForeground : Color.foreground
  readonly property string fontFam: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property var sidesNow: Model.sides(root.fixture, root.teamId)

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(body.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: body
        width: parent.width
        spacing: Style.space(10)

        // ---- pick a team. Shown until the widget is usable, then on demand.
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.settingsOpen

          Text {
            text: root.configured ? "Change team" : "Pick your team"
            color: root.fg
            font.family: root.fontFam
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: searchField
              width: parent.width - searchBtn.width - Style.space(6)
              placeholderText: "club or league name"
              foreground: root.fg
              font.family: root.fontFam
              font.pixelSize: Style.font.bodySmall
              onAccepted: root.searchTeams()
            }

            Button {
              id: searchBtn
              text: root.searching ? "…" : "Search"
              bordered: true
              foreground: root.fg
              fontFamily: root.fontFam
              fontSize: Style.font.bodySmall
              onClicked: root.searchTeams()
            }
          }

          Text {
            width: body.width
            visible: root.searchNote !== ""
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.searchNote
            color: Qt.darker(root.fg, 1.5)
            font.family: root.fontFam
            font.pixelSize: Style.font.caption
          }

          Column {
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: root.searchResults

              Button {
                required property var modelData
                width: body.width
                bordered: false
                text: modelData.name
                      + (modelData.country ? "  ·  " + modelData.country : "")
                      + (modelData.code ? "  ·  " + modelData.code : "")
                foreground: root.fg
                fontFamily: root.fontFam
                fontSize: Style.font.bodySmall
                onClicked: root.pickTeam(modelData.id, modelData.name)
              }
            }
          }

          Text {
            width: body.width
            visible: root.savedNote !== ""
            text: root.savedNote
            color: Qt.darker(root.fg, 1.4)
            font.family: root.fontFam
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---- error
        Text {
          width: body.width
          visible: !root.settingsOpen && root.errorText !== ""
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.errorText
          color: root.bar ? root.bar.urgent : Color.urgent
          font.family: root.fontFam
          font.pixelSize: Style.font.bodySmall
        }

        // ---- nothing scheduled
        Text {
          visible: !root.settingsOpen && root.configured && root.errorText === ""
                   && root.fixture === null && root.lastFetchMs > 0
          text: "No upcoming fixture"
          color: Qt.darker(root.fg, 1.4)
          font.family: root.fontFam
          font.pixelSize: Style.font.bodySmall
          font.italic: true
        }

        // ---- the fixture
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: !root.settingsOpen && root.fixture !== null && root.errorText === ""

          Text {
            width: body.width
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: root.fixture && root.fixture.league
                  ? Model.plainText(root.fixture.league.name)
                    + (root.fixture.league.round ? "  ·  " + Model.plainText(root.fixture.league.round) : "")
                  : ""
            color: Qt.darker(root.fg, 1.4)
            font.family: root.fontFam
            font.pixelSize: Style.font.bodySmall
          }

          // Crests either side of the scoreline. Badges are remote PNGs;
          // sourceSize caps the decode so a 500px crest is not held in memory
          // at full size for a 28px slot.
          Row {
            width: parent.width
            spacing: Style.space(8)

            Image {
              id: homeBadge
              width: Style.space(28); height: Style.space(28)
              anchors.verticalCenter: parent.verticalCenter
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              cache: true
              sourceSize.width: Style.space(56)
              sourceSize.height: Style.space(56)
              visible: source != "" && status === Image.Ready
              source: root.fixture && root.fixture.badges ? root.fixture.badges.home : ""
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: body.width - homeBadge.width - awayBadge.width - Style.space(24)
              wrapMode: Text.WordWrap
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: root.sidesNow
                    ? Model.plainText(root.sidesNow.home.name) + "  v  " + Model.plainText(root.sidesNow.away.name)
                    : ""
              color: root.fg
              font.family: root.fontFam
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Image {
              id: awayBadge
              width: Style.space(28); height: Style.space(28)
              anchors.verticalCenter: parent.verticalCenter
              fillMode: Image.PreserveAspectFit
              asynchronous: true
              cache: true
              sourceSize.width: Style.space(56)
              sourceSize.height: Style.space(56)
              visible: source != "" && status === Image.Ready
              source: root.fixture && root.fixture.badges ? root.fixture.badges.away : ""
            }
          }

          Text {
            width: body.width
            textFormat: Text.PlainText
            text: {
              if (!root.fixture) return ""
              var ko = Model.kickoffMs(root.fixture)
              if (!isFinite(ko)) return ""
              var d = new Date(ko)
              var state = Model.matchState(root.fixture)
              if (state === "live") return "Live now"
              if (state === "finished") return "Finished"
              var delta = ko - root.nowMs
              return Qt.formatDateTime(d, "dddd d MMMM, HH:mm")
                     + (delta > 0 ? "   ·   in " + Model.countdown(delta) : "")
            }
            color: root.fg
            font.family: root.fontFam
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: body.width
            visible: text !== ""
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: {
              if (!root.fixture || !root.fixture.fixture) return ""
              var v = root.fixture.fixture.venue
              if (!v || !v.name) return ""
              return Model.plainText(v.name) + (root.sidesNow ? (root.sidesNow.atHome ? "   ·   Home" : "   ·   Away") : "")
            }
            color: Qt.darker(root.fg, 1.4)
            font.family: root.fontFam
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---- the three fixtures after this one. TheSportsDB only publishes a
        // few rounds ahead early in a season, so this fills in over time
        // rather than always holding three.
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: !root.settingsOpen && root.fixture !== null && root.errorText === ""

          PanelSeparator { width: parent.width }

          Text {
            text: "Then"
            color: Qt.darker(root.fg, 1.5)
            font.family: root.fontFam
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.laterFixtures

            Row {
              required property var modelData
              width: body.width
              spacing: Style.space(6)

              readonly property var rowSides: Model.sides(modelData, root.teamId)
              readonly property string rowOpponent: rowSides ? Model.plainText(rowSides.them.name) : ""
              readonly property string rowBadge: Model.opponentBadge(modelData, root.teamId)

              Image {
                anchors.verticalCenter: parent.verticalCenter
                width: status === Image.Ready ? Style.space(16) : 0
                height: width
                fillMode: Image.PreserveAspectFit
                asynchronous: true
                cache: true
                visible: status === Image.Ready
                sourceSize.width: Style.space(32)
                sourceSize.height: Style.space(32)
                source: parent.rowBadge
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: body.width - Style.space(150)
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: (parent.rowSides && parent.rowSides.atHome ? "vs " : "at ") + parent.rowOpponent
                color: root.fg
                font.family: root.fontFam
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                horizontalAlignment: Text.AlignRight
                textFormat: Text.PlainText
                text: {
                  var ko = Model.kickoffMs(parent.modelData)
                  if (!isFinite(ko)) return ""
                  return Qt.formatDateTime(new Date(ko), "ddd d MMM  HH:mm")
                }
                color: Qt.darker(root.fg, 1.4)
                font.family: root.fontFam
                font.pixelSize: Style.font.bodySmall
              }
            }
          }

          Text {
            width: body.width
            visible: root.laterFixtures.length === 0
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: "Nothing further published yet."
            color: Qt.darker(root.fg, 1.6)
            font.family: root.fontFam
            font.pixelSize: Style.font.caption
            font.italic: true
          }
        }

        PanelSeparator { width: parent.width }

        Row {
          spacing: Style.space(10)

          Button {
            visible: root.configured
            text: root.showSettings ? "Done" : "Change team"
            bordered: false
            foreground: Qt.darker(root.fg, 1.4)
            fontFamily: root.fontFam
            fontSize: Style.font.bodySmall
            onClicked: {
              root.showSettings = !root.showSettings
              if (!root.showSettings) { root.searchResults = []; root.searchNote = "" }
            }
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.settingsOpen
            textFormat: Text.PlainText
            text: {
              if (root.fetching) return "Refreshing…"
              if (root.lastFetchMs === 0) return "middle-click to refresh"
              var mins = Math.floor((root.nowMs - root.lastFetchMs) / 60000)
              var ago = mins < 1 ? "just now" : (mins < 60 ? mins + "m ago" : Math.floor(mins / 60) + "h ago")
              return "Updated " + ago
            }
            color: Qt.darker(root.fg, 1.6)
            font.family: root.fontFam
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
