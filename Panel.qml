import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Owns the fixture data: settings, fetching, caching and pacing. BarWidget.qml
// reads `pillLabel` off this and draws the button.
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

  // "thesportsdb" (default: free, no key needed, covers leagues api-football's
  // free tier locks away) or "api-football" (needs a paid key for the current
  // season).
  readonly property string provider: String(root.setting("provider", "thesportsdb"))
  readonly property bool isSdb: provider !== "api-football"

  readonly property string apiKeySpec: String(root.setting("apiKey", ""))
  readonly property var keySpec: Model.parseKeySpec(apiKeySpec)
  readonly property int teamId: Model.validTeamId(root.setting("teamId", 0))
  readonly property bool showLive: root.setting("showLive", true) === true
  readonly property int baseMinutes: {
    var n = parseInt(root.setting("refreshMinutes", 60), 10)
    return isFinite(n) && n >= 15 ? n : 60
  }

  // Which fixture query this account is allowed to use. Discovered once on a
  // plan refusal and then remembered, so the fallback costs at most a couple of
  // extra requests in the widget's lifetime rather than on every poll.
  readonly property string queryMode: String(root.setting("queryMode", "next"))

  readonly property bool hasKey: keySpec.mode !== "none"
  // TheSportsDB works on its shared test key, so a team id is the only thing
  // it actually needs from the user.
  readonly property bool configured: (isSdb || hasKey) && teamId > 0

  // --------------------------------------------------------------------- state

  property var fixture: null
  property string errorText: ""
  // The API's verbatim refusal, shown in the panel so a plan problem is
  // readable rather than guessed at.
  property string errorDetail: ""
  property string triedModes: ""
  property double lastFetchMs: 0
  // Guards against the same query going out twice in a burst: a startup fetch
  // and a fallback retry can otherwise land on the same URL a second apart and
  // spend two of the day's requests to learn one thing.
  property string lastUrl: ""
  property double lastUrlAt: 0
  property bool fetching: false
  property string quotaText: ""

  // Advanced by a timer rather than read from Date.now() at use sites, so every
  // binding that shows a countdown re-evaluates together.
  property double nowMs: Date.now()

  readonly property bool idle: configured && errorText === "" && fixture === null
  readonly property bool needsAttention: !configured || errorText !== ""

  readonly property string cachePath: Quickshell.env("HOME") + "/.cache/omarchy-next-match/fixture.json"
  // Resolved when a fetch starts rather than bound: `range` embeds today's
  // date, and a binding on the ticking clock would rewrite the command line
  // every 30 seconds.
  property string fetchUrl: ""

  readonly property var whenParts: {
    var ko = Model.kickoffMs(root.fixture)
    if (!isFinite(ko)) return null
    var d = new Date(ko)
    return { weekday: Qt.formatDateTime(d, "ddd"), time: Qt.formatDateTime(d, "HH:mm") }
  }

  readonly property string pillLabel: {
    // TheSportsDB needs no key of the user's own, so only api-football may ask.
    if (!isSdb && !hasKey) return "Add API key"
    if (teamId <= 0) return "Set team ID"
    if (errorText !== "") return errorText
    if (fixture === null) return lastFetchMs === 0 ? "…" : "No match"
    return Model.pillLabel(root.fixture, root.nowMs, {
      teamId: root.teamId,
      showLive: root.showLive,
      when: root.whenParts
    })
  }

  readonly property string tooltip: {
    if (!configured) return "Next Match — open to finish setup"
    if (errorText !== "") return "Next Match — " + errorText
    if (!fixture) return "Next Match — nothing scheduled"
    var s = Model.sides(root.fixture, root.teamId)
    if (!s) return "Next Match"
    return s.home.name + " v " + s.away.name
  }

  // ------------------------------------------------------------------ lifecycle

  function refresh(force) {
    if (!configured || fetchProc.running) return
    // A reload storm (theme switch, plugin rescan) must not spend the daily
    // budget: ignore anything that comes back inside a minute unless a human
    // asked for it.
    if (!force && root.lastFetchMs > 0 && Date.now() - root.lastFetchMs < 60000) return
    var url = root.isSdb
      ? Model.sdbNextUrl(root.keySpec.mode === "inline" ? root.keySpec.value : "", root.teamId)
      : Model.fixtureUrl(root.teamId, root.queryMode, Date.now())
    if (url === root.lastUrl && Date.now() - root.lastUrlAt < 5000) return
    root.lastUrl = url
    root.lastUrlAt = Date.now()
    root.fetchUrl = url
    root.fetching = true
    fetchProc.running = true
  }

  function applyPayload(payload, fromCache) {
    // The free plan refuses `next`. That is not a user error: try the next
    // query shape, remember it, and say nothing.
    var refusal = fromCache ? "" : Model.planRefusal(payload)
    if (refusal !== "") {
      root.errorDetail = Model.rawApiError(payload)
      console.log("next-match: '" + root.queryMode + "' refused (" + refusal + ") — " + root.errorDetail)

      // A season the account cannot see is the end of the road: every query
      // shape asks about the same season, so there is nothing left to try.
      if (refusal === "season") {
        var hint = Model.seasonHint(payload)
        root.errorText = "Plan has no current season"
        if (hint !== "") root.errorDetail += "\n\nThis key can only read " + hint
          + ", so there is no upcoming fixture for it to return."
        // Nothing will change until the account does. Check twice a day rather
        // than hourly, so an unusable key costs 2 requests a day, not 48.
        refreshTimer.interval = 12 * 3600 * 1000
        refreshTimer.restart()
        return
      }

      root.triedModes = (root.triedModes ? root.triedModes + ", " : "") + root.queryMode
      var fallback = Model.nextQueryMode(root.queryMode)
      if (fallback !== "") {
        persistSettings({ queryMode: fallback })
        Qt.callLater(function() { root.refresh(true) })
        return
      }
      root.errorText = "Plan cannot read fixtures"
      return
    }

    var err = Model.apiError(payload)
    if (err !== "") {
      root.errorText = err
      // A cached fixture is better than an error pill while the key is being
      // fixed, so keep whatever is already on screen.
      return
    }
    root.errorText = ""
    root.errorDetail = ""
    root.triedModes = ""
    root.fixture = Model.pickNextFixture(payload, Date.now())
    if (!fromCache) root.lastFetchMs = Date.now()
    if (payload && payload.paging !== undefined && payload.results !== undefined)
      root.quotaText = ""
    scheduleNext()
  }

  function onFetched(raw) {
    root.fetching = false
    var text = String(raw || "").trim()
    if (text === "") {
      // curl failed (offline, DNS, timeout). Keep the last good fixture and
      // try again on the normal schedule rather than blanking the bar.
      root.errorText = root.fixture ? "" : "Offline"
      scheduleNext()
      return
    }
    try {
      var parsed = JSON.parse(text)
      applyPayload(root.isSdb ? Model.sdbFixtures(parsed) : parsed, false)
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
      var parsedCache = JSON.parse(raw)
      applyPayload(root.isSdb ? Model.sdbFixtures(parsedCache) : parsedCache, true)
      // Cached data is shown immediately but is not proof of a recent fetch;
      // refresh() decides on its own whether the network is due.
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
  onTeamIdChanged: { root.fixture = null; root.errorText = ""; if (configured) refresh(true) }
  onApiKeySpecChanged: { root.errorText = ""; if (configured) refresh(true) }

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
    onLoadFailed: function(error) { /* no cache yet; first fetch writes one */ }
  }

  // The key reaches bash through the environment and the header reaches curl
  // through a config file on stdin, so it appears in neither process's argv.
  // `ps` on a shared machine shows the URL and nothing else.
  Process {
    id: fetchProc
    running: false
    command: ["bash", "-c", root.fetchScript]
    environment: ({
      "NM_KEY": root.keySpec.mode === "inline" ? root.keySpec.value : "",
      "NM_KEY_REF": root.keySpec.mode === "inline" ? "" : root.keySpec.value,
      "NM_URL": root.fetchUrl,
      "NM_CACHE": root.cachePath
    })
    // onStreamFinished fires even when curl dies early, with empty text, so
    // there is no need for an onExited handler to clear `fetching` as well.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onFetched(text)
    }
  }

  readonly property string fetchScript:
    'key=$(' + Model.keyResolverScript(root.apiKeySpec) + ')\n' +
    'key=$(printf %s "$key" | tr -d "[:space:]")\n' +
    (root.isSdb ? '' : 'if [ -z "$key" ]; then printf %s \'{"errors":{"token":"missing"}}\'; exit 0; fi\n') +
    'out=$(printf \'header = "x-apisports-key: %s"\\nurl = "%s"\\n\' "$key" "$NM_URL" | curl -fsS --max-time 20 -K -) || out=""\n' +
    'if [ -n "$out" ]; then mkdir -p "$(dirname "$NM_CACHE")" && printf %s "$out" > "$NM_CACHE".tmp && mv -f "$NM_CACHE".tmp "$NM_CACHE"; fi\n' +
    'printf %s "$out"\n'

  // ------------------------------------------------------------------ settings

  // Omarchy 4 renders no settings form for a third-party bar widget — the
  // manifest schema is metadata nothing consumes yet — so the plugin carries
  // its own. Writing goes through the shell's own updateEntryInline, the same
  // call the built-in clock uses to persist a cycled format: it is in-process,
  // so the key never becomes an argument to anything, and it writes shell.json
  // through the shell's FileView, which follows a symlink instead of replacing
  // it (the case if you stow your dotfiles).
  property bool showSettings: false
  readonly property bool settingsOpen: showSettings || !configured

  property string savedNote: ""
  property var searchResults: []
  property string searchNote: ""
  property bool searching: false

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function saveFields() {
    var team = parseInt(String(teamField.text).trim(), 10)
    persistSettings({
      apiKey: String(keyField.text).trim(),
      teamId: isFinite(team) && team > 0 ? team : 0
    })
    root.savedNote = "Saved"
    savedNoteTimer.restart()
    root.errorText = ""
    root.refresh(true)
  }

  function syncFields() {
    keyField.text = root.apiKeySpec
    teamField.text = root.teamId > 0 ? String(root.teamId) : ""
  }

  function pickTeam(id, name) {
    teamField.text = String(id)
    root.searchResults = []
    root.searchNote = "Selected " + name
    saveFields()
  }

  function searchTeams() {
    var q = String(searchField.text).trim()
    if (!Model.searchValid(q)) { root.searchNote = "Type at least 3 characters"; return }
    if (!isSdb && !hasKey) { root.searchNote = "Add your API key first"; return }
    if (searchProc.running) return
    root.searchResults = []
    root.searchNote = "Searching…"
    root.searching = true
    searchProc.running = true
  }

  function onSearched(raw) {
    root.searching = false
    var text = String(raw || "").trim()
    if (text === "") { root.searchNote = "No answer — check your connection"; return }
    try {
      var payload = JSON.parse(text)
      var err = Model.apiError(payload)
      if (err !== "") { root.searchNote = err; return }
      var teams = root.isSdb ? Model.sdbTeams(payload) : Model.parseTeams(payload)
      root.searchResults = teams
      root.searchNote = teams.length === 0 ? "Nothing matched" : ""
    } catch (e) {
      root.searchNote = "Bad response"
    }
  }

  Timer {
    id: savedNoteTimer
    interval: 2500
    onTriggered: root.savedNote = ""
  }

  // Same key handling as the fixture fetch: environment in, config file on
  // stdin, nothing secret in argv.
  Process {
    id: searchProc
    running: false
    command: ["bash", "-c", root.fetchScriptFor]
    environment: ({
      "NM_KEY": root.keySpec.mode === "inline" ? root.keySpec.value : "",
      "NM_KEY_REF": root.keySpec.mode === "inline" ? "" : root.keySpec.value,
      "NM_URL": root.isSdb
        ? Model.sdbSearchUrl(root.keySpec.mode === "inline" ? root.keySpec.value : "", searchField.text)
        : Model.teamsUrl(searchField.text),
      "NM_CACHE": ""
    })
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onSearched(text)
    }
  }

  // The fixture script caches; the search must not overwrite that cache, so it
  // reuses the same key handling with the caching step skipped.
  readonly property string fetchScriptFor:
    'key=$(' + Model.keyResolverScript(root.apiKeySpec) + ')\n' +
    'key=$(printf %s "$key" | tr -d "[:space:]")\n' +
    'if [ -z "$key" ]; then printf %s \'{"errors":{"token":"missing"}}\'; exit 0; fi\n' +
    'printf \'header = "x-apisports-key: %s"\\nurl = "%s"\\n\' "$key" "$NM_URL" | curl -fsS --max-time 20 -K -\n'

  onOpenedChanged: if (opened) syncFields()

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
    contentWidth: panel.fittedContentWidth(Style.space(320))
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

        // ---- settings form. Shown automatically until the widget is usable,
        // and on demand afterwards.
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.settingsOpen

          Text {
            text: root.configured ? "Settings" : "Next Match needs setting up"
            color: root.fg
            font.family: root.fontFam
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            text: "Data source"
            color: Qt.darker(root.fg, 1.3)
            font.family: root.fontFam
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            spacing: Style.space(6)

            Button {
              text: "TheSportsDB (free)"
              bordered: true
              selected: root.isSdb
              foreground: root.fg
              fontFamily: root.fontFam
              fontSize: Style.font.bodySmall
              onClicked: if (!root.isSdb) {
                // Team ids differ between sources, so switching clears the old
                // one rather than silently looking up a stranger.
                teamField.text = ""
                root.searchResults = []
                root.persistSettings({ provider: "thesportsdb", teamId: 0 })
                root.syncFields()
              }
            }

            Button {
              text: "api-football"
              bordered: true
              selected: !root.isSdb
              foreground: root.fg
              fontFamily: root.fontFam
              fontSize: Style.font.bodySmall
              onClicked: if (root.isSdb) {
                teamField.text = ""
                root.searchResults = []
                root.persistSettings({ provider: "api-football", teamId: 0, queryMode: "next" })
                root.syncFields()
              }
            }
          }

          Text {
            width: body.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            visible: !root.isSdb
            text: "api-football's free plan cannot read the current season, so it cannot show an upcoming fixture. This source needs a paid key."
            color: Qt.darker(root.fg, 1.7)
            font.family: root.fontFam
            font.pixelSize: Style.font.caption
          }

          Text {
            text: root.isSdb ? "API key (optional)" : "API key"
            color: Qt.darker(root.fg, 1.3)
            font.family: root.fontFam
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: keyField
            width: parent.width
            // A pasted key is masked; a file:/env: reference is a path, not a
            // secret, so it stays readable.
            password: Model.keyIsSecret(text)
            placeholderText: root.isSdb ? "optional — leave blank to use the free key" : "paste your api-football key"
            foreground: root.fg
            font.family: root.fontFam
            font.pixelSize: Style.font.bodySmall
            onAccepted: root.saveFields()
          }

          Text {
            width: body.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.isSdb ? "TheSportsDB works without a key. Add your own only if you want your own rate limit." : "From dashboard.api-football.com. To keep it out of shell.json, enter file:~/.config/omarchy/next-match.key or env:API_FOOTBALL_KEY instead."
            color: Qt.darker(root.fg, 1.7)
            font.family: root.fontFam
            font.pixelSize: Style.font.caption
          }

          Text {
            text: "Team ID"
            color: Qt.darker(root.fg, 1.3)
            font.family: root.fontFam
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: teamField
            width: parent.width
            placeholderText: "e.g. 40"
            validator: IntValidator { bottom: 0; top: 9999999 }
            foreground: root.fg
            font.family: root.fontFam
            font.pixelSize: Style.font.bodySmall
            onAccepted: root.saveFields()
          }

          // Nobody knows their team's numeric id, so it can be looked up here
          // rather than in a terminal.
          Row {
            width: parent.width
            spacing: Style.space(6)

            TextField {
              id: searchField
              width: parent.width - searchBtn.width - Style.space(6)
              placeholderText: "or search by name, e.g. liverpool"
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
                      + "  ·  " + modelData.id
                foreground: root.fg
                fontFamily: root.fontFam
                fontSize: Style.font.bodySmall
                onClicked: root.pickTeam(modelData.id, modelData.name)
              }
            }
          }

          Row {
            spacing: Style.space(8)

            Button {
              text: "Save"
              bordered: true
              foreground: root.fg
              fontFamily: root.fontFam
              fontSize: Style.font.bodySmall
              onClicked: root.saveFields()
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              visible: root.savedNote !== ""
              text: root.savedNote
              color: Qt.darker(root.fg, 1.4)
              font.family: root.fontFam
              font.pixelSize: Style.font.bodySmall
            }
          }
        }

        // ---- error
        Text {
          width: body.width
          visible: !root.settingsOpen && root.configured && root.errorText !== ""
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.errorText
          color: root.bar ? root.bar.urgent : Color.urgent
          font.family: root.fontFam
          font.pixelSize: Style.font.bodySmall
        }

        // ---- the API's own words, so a plan refusal is readable
        Text {
          width: body.width
          visible: !root.settingsOpen && root.errorDetail !== ""
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.errorDetail
                + (root.triedModes !== "" ? "\n\nTried: " + root.triedModes
                   + "\nRun scripts/plan-probe to see what your plan allows." : "")
          color: Qt.darker(root.fg, 1.4)
          font.family: root.fontFam
          font.pixelSize: Style.font.caption
        }

        // ---- nothing scheduled
        Text {
          visible: !root.settingsOpen && root.configured && root.errorText === "" && root.fixture === null && root.lastFetchMs > 0
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
                  : ""
            color: Qt.darker(root.fg, 1.4)
            font.family: root.fontFam
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: body.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.sidesNow
                  ? Model.plainText(root.sidesNow.home.name) + "   v   " + Model.plainText(root.sidesNow.away.name)
                  : ""
            color: root.fg
            font.family: root.fontFam
            font.pixelSize: Style.font.body
            font.bold: true
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
              return Model.plainText(v.name) + (v.city ? ", " + Model.plainText(v.city) : "")
            }
            color: Qt.darker(root.fg, 1.4)
            font.family: root.fontFam
            font.pixelSize: Style.font.bodySmall
          }

          Text {
            width: body.width
            visible: root.sidesNow !== null
            textFormat: Text.PlainText
            text: root.sidesNow ? (root.sidesNow.atHome ? "Home" : "Away") : ""
            color: Qt.darker(root.fg, 1.4)
            font.family: root.fontFam
            font.pixelSize: Style.font.bodySmall
          }
        }

        PanelSeparator { width: parent.width }

        Button {
          visible: root.configured
          text: root.showSettings ? "Done" : "Settings"
          bordered: false
          foreground: Qt.darker(root.fg, 1.4)
          fontFamily: root.fontFam
          fontSize: Style.font.bodySmall
          onClicked: {
            root.showSettings = !root.showSettings
            if (root.showSettings) root.syncFields()
            else root.searchResults = []
          }
        }

        Text {
          width: body.width
          visible: !root.settingsOpen
          textFormat: Text.PlainText
          text: {
            if (root.fetching) return "Refreshing…"
            if (root.lastFetchMs === 0) return "Middle-click the pill to refresh"
            var mins = Math.floor((root.nowMs - root.lastFetchMs) / 60000)
            var ago = mins < 1 ? "just now" : (mins < 60 ? mins + "m ago" : Math.floor(mins / 60) + "h ago")
            return "Updated " + ago + "   ·   middle-click to refresh"
          }
          color: Qt.darker(root.fg, 1.6)
          font.family: root.fontFam
          font.pixelSize: Style.font.bodySmall
        }
      }
    }
  }
}
