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

  // The scheduled fixture, and — while one is being played — the live feed's
  // version of it. Display reads `displayFixture`; pacing and the "then" list
  // read `fixture`, which is the schedule.
  property var fixture: null
  property var liveFixture: null
  readonly property var displayFixture: root.liveFixture ? root.liveFixture : root.fixture
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

  readonly property string badgeUrl: root.showBadge ? Model.opponentBadge(root.displayFixture, root.teamId) : ""

  // The bar draws both clubs, so it needs the parts rather than one string:
  // a crest cannot be interleaved into a Text.
  readonly property string homeName: root.sidesNow ? Model.plainText(root.sidesNow.home.name) : ""
  readonly property string awayName: root.sidesNow ? Model.plainText(root.sidesNow.away.name) : ""
  readonly property string homeBadgeUrl: root.showBadge && root.displayFixture && root.displayFixture.badges ? root.displayFixture.badges.home : ""
  readonly property string awayBadgeUrl: root.showBadge && root.displayFixture && root.displayFixture.badges ? root.displayFixture.badges.away : ""

  // "v" normally; the scoreline once it is being played.
  readonly property string barMiddle: {
    if (!root.displayFixture) return ""
    if (Model.matchState(root.displayFixture) === "live" && root.showLive) {
      var g = root.displayFixture.goals || {}
      var h = g.home === null || g.home === undefined ? 0 : g.home
      var a = g.away === null || g.away === undefined ? 0 : g.away
      return h + " - " + a
    }
    return "v"
  }

  // The clock or the countdown that trails the two clubs.
  readonly property string barTrailing: {
    if (!root.displayFixture) return ""
    var state = Model.matchState(root.displayFixture)
    if (state === "live" && root.showLive) {
      if (Model.statusShort(root.displayFixture) === "HT") return "HT"
      var el = root.displayFixture.fixture.status.elapsed
      return el ? el + "'" : "live"
    }
    if (state === "off") return "postponed"
    var ko = Model.kickoffMs(root.displayFixture)
    if (!isFinite(ko)) return ""
    return Model.timingLabel(ko - root.nowMs, root.whenText)
  }


  // "Sun 08:30 PM" — the shape used while a match is inside a week.
  readonly property string whenText: {
    var ko = Model.kickoffMs(root.displayFixture)
    if (!isFinite(ko)) return ""
    var d = new Date(ko)
    var kind = Model.dayKind(ko, root.nowMs)
    var day = kind === "today" ? "Today"
            : (kind === "tomorrow" ? "Tomorrow" : Qt.formatDateTime(d, "ddd"))
    return day + " " + Qt.formatDateTime(d, "hh:mm AP")
  }

  readonly property string pillLabel: {
    if (teamId <= 0) return "Pick a team"
    if (errorText !== "") return errorText
    if (displayFixture === null) return lastFetchMs === 0 ? "…" : "No match"
    return Model.pillLabel(root.displayFixture, root.nowMs, {
      teamId: root.teamId,
      showLive: root.showLive,
      whenText: root.whenText
    })
  }

  readonly property string tooltip: {
    if (!configured) return "Next Match — click to pick a team"
    if (errorText !== "") return "Next Match — " + errorText
    if (!displayFixture) return "Next Match — nothing scheduled"
    var s = Model.sides(root.displayFixture, root.teamId)
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
    root.fixture = Model.pickNextFixture(Model.sdbFixtures(payload), Date.now())
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
    if (Model.rateLimited(text)) {
      // Transient and not the user's doing: keep the last good fixture and
      // come back later rather than replacing it with an error.
      if (!root.fixture) root.errorText = "Rate limited"
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

  function pollLive() {
    if (!root.showLive || liveProc.running) return
    root.liveUrl = Model.sdbLiveUrl(root.sdbKey)
    liveProc.running = true
  }

  property string liveUrl: ""

  function onLive(raw) {
    var text = String(raw || "").trim()
    if (text === "") return
    try {
      var found = Model.sdbLiveForTeam(JSON.parse(text), root.teamId)
      root.liveFixture = found
      // The match has dropped off the live feed, so it is over: ask the
      // schedule for whatever is next rather than showing a stale scoreline.
      if (!found && root.fixture && Model.matchState(root.fixture) !== "live") {
        var ko = Model.kickoffMs(root.fixture)
        if (isFinite(ko) && Date.now() > ko + 2 * 3600 * 1000) root.refresh(true)
      }
    } catch (e) {
      // A malformed live feed just leaves the scheduled fixture showing.
    }
  }

  function scheduleNext() {
    var mins = Model.refreshMinutes(root.fixture, root.nowMs, root.baseMinutes, root.showLive)
    refreshTimer.interval = Math.max(60000, mins * 60000)
    refreshTimer.restart()
  }

  onConfiguredChanged: if (configured) refresh(true)
  onTeamIdChanged: {
    root.fixture = null
    root.liveFixture = null
    root.errorText = ""
    if (configured) refresh(true)
  }

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

  // While a match is on, `eventsnext` has nothing to say about it — it lists
  // only fixtures that have not started — so the live feed is polled instead.
  Timer {
    id: liveTimer
    interval: 180000
    repeat: true
    running: root.showLive && root.configured && Model.liveWindow(root.fixture, root.nowMs)
    triggeredOnStart: true
    onTriggered: root.pollLive()
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

  // Picking a club by typing its name does not work reliably: TheSportsDB
  // matches an alternate-names field, so "Al-Hilal" finds nothing where
  // "Al Hilal SFC" finds it. Browsing does work, and it is also how you find a
  // club whose exact name you do not know — so the picker walks
  // country -> league -> club, with a filter box at each step.
  property string browseStage: "country"     // country | team
  property string chosenCountry: ""
  property var countryList: []
  property var teamList: []
  property string browseNote: ""
  property bool browsing: false
  property string browseUrl: ""
  property string browseKind: ""

  readonly property var visibleRows: {
    var q = String(filterField.text).trim()
    var src = root.browseStage === "country" ? root.countryList : root.teamList
    if (q === "") return src
    var out = []
    for (var i = 0; i < src.length; ++i)
      if (Model.matchesQuery(src[i].name, q)) out.push(src[i])
    return out
  }

  function startBrowse() {
    root.browseStage = "country"
    root.chosenCountry = ""
    root.teamList = []
    filterField.text = ""
    root.browseNote = ""
    // Show the built-in list at once rather than an empty panel, then fold in
    // whatever the API adds. Its own list stops at Costa Rica, so this is the
    // part that actually has Saudi Arabia in it.
    if (root.countryList.length === 0) {
      root.countryList = Model.sdbCountries(null)
      fetchBrowse("country", Model.sdbCountriesUrl(root.sdbKey))
    }
  }

  function fetchBrowse(kind, url) {
    if (browseProc.running) return
    root.browseKind = kind
    root.browseUrl = url
    root.browseNote = "Loading…"
    root.browsing = true
    browseProc.running = true
  }

  function chooseCountry(name) {
    root.chosenCountry = name
    root.browseStage = "team"
    root.teamList = []
    filterField.text = ""
    fetchBrowse("team", Model.sdbCountryTeamsUrl(root.sdbKey, name))
  }

  // The shared key returns only ten clubs per country, alphabetically — the
  // Saudi list stops before Al-Hilal and the English one before Liverpool — so
  // the list alone cannot reach most clubs. Searching by name does, and its
  // hits are merged into the list, dropping anything from another country.
  function searchTeamsByName() {
    var q = String(filterField.text).trim()
    if (q.length < 3 || browseProc.running) return
    root.searchVariants = Model.sdbSearchVariants(q)
    root.browseNote = "Searching…"
    root.browsing = true
    runTeamSearch()
  }

  property var searchVariants: []

  function runTeamSearch() {
    if (root.searchVariants.length === 0) {
      root.browsing = false
      root.browseNote = "No club matched. Punctuation matters here — try \"Al Nassr\" rather than \"Al-Nassr\"."
      return
    }
    var rest = root.searchVariants.slice()
    var next = rest.shift()
    root.searchVariants = rest
    fetchBrowse("search", Model.sdbSearchUrl(root.sdbKey, next))
  }

  function browseBack() {
    filterField.text = ""
    if (root.browseStage === "team") { root.browseStage = "country"; root.browseNote = "" }
  }

  function onBrowsed(raw) {
    root.browsing = false
    var text = String(raw || "").trim()
    if (Model.rateLimited(text)) {
      root.browseNote = "TheSportsDB is rate-limiting its shared key. Wait a minute and try again."
      return
    }
    var payload = null
    if (text !== "") { try { payload = JSON.parse(text) } catch (e) { payload = null } }
    if (!payload) { root.browseNote = "Could not load — check your connection"; return }

    if (root.browseKind === "country") {
      root.countryList = Model.sdbCountries(payload)
      root.browseNote = root.countryList.length === 0 ? "No countries returned" : ""
    } else if (root.browseKind === "search") {
      var hits = Model.sdbTeams(payload)
      if (hits.length === 0) { runTeamSearch(); return }
      root.searchVariants = []
      root.teamList = Model.mergeTeams(root.teamList, hits, root.chosenCountry)
      root.browseNote = root.teamList.length === 0
        ? "Found it, but not in " + root.chosenCountry + ". Go Back and pick the right country."
        : ""
    } else {
      root.teamList = Model.sdbTeams(payload)
      root.browseNote = root.teamList.length === 0
        ? "No clubs listed for " + root.chosenCountry + ". Try a different spelling."
        : ""
    }
  }

  function pickTeam(id, name) {
    root.browseNote = ""
    filterField.text = ""
    root.savedNote = "Now following " + name
    savedNoteTimer.restart()
    root.errorText = ""
    persistSettings({ teamId: id })
    root.showSettings = false
  }

  // The shared key returns only ten clubs per country, so typing a club that is
  // not among them would otherwise just empty the list. When the local filter
  // comes up short, the name search runs on its own — no button to discover.
  Timer {
    id: autoSearchTimer
    interval: 450
    onTriggered: {
      if (root.browseStage !== "team") return
      if (String(filterField.text).trim().length < 3) return
      if (root.visibleRows.length > 0 || root.browsing) return
      root.searchTeamsByName()
    }
  }

  Timer {
    id: savedNoteTimer
    interval: 2500
    onTriggered: root.savedNote = ""
  }

  Process {
    id: liveProc
    running: false
    command: ["bash", "-c", 'printf \'url = "%s"\\n\' "$NM_URL" | curl -fsS --max-time 20 -K -']
    environment: ({ "NM_URL": root.liveUrl })
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onLive(text)
    }
  }

  Process {
    id: browseProc
    running: false
    command: ["bash", "-c", 'printf \'url = "%s"\\n\' "$NM_URL" | curl -fsS --max-time 25 -K -']
    environment: ({ "NM_URL": root.browseUrl })
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onBrowsed(text)
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

  onOpenedChanged: if (opened && settingsOpen) startBrowse()

  // ------------------------------------------------------------------- the popup

  readonly property color fg: root.bar ? root.bar.barForeground : Color.foreground
  readonly property string fontFam: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property var sidesNow: Model.sides(root.displayFixture, root.teamId)

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

        // ---- the picker: country, then league, then club. Shown until the
        // widget is usable, then from the "Change team" button.
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.settingsOpen

          Text {
            text: root.browseStage === "country" ? "Pick a country" : root.chosenCountry
            color: root.fg
            font.family: root.fontFam
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
            width: body.width
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            Button {
              id: backBtn
              visible: root.browseStage !== "country"
              text: "‹ Back"
              bordered: true
              foreground: root.fg
              fontFamily: root.fontFam
              fontSize: Style.font.bodySmall
              onClicked: root.browseBack()
            }

            TextField {
              id: filterField
              width: parent.width - (backBtn.visible ? backBtn.width + Style.space(6) : 0)
                     - (findBtn.visible ? findBtn.width + Style.space(6) : 0)
              placeholderText: root.browseStage === "country" ? "filter countries" : "type any club in " + root.chosenCountry
              foreground: root.fg
              font.family: root.fontFam
              font.pixelSize: Style.font.bodySmall
              onAccepted: if (root.browseStage === "team") root.searchTeamsByName()
              onTextChanged: if (root.browseStage === "team") autoSearchTimer.restart()
            }

            Button {
              id: findBtn
              visible: root.browseStage === "team"
              text: root.browsing ? "…" : "Find"
              bordered: true
              foreground: root.fg
              fontFamily: root.fontFam
              fontSize: Style.font.bodySmall
              onClicked: root.searchTeamsByName()
            }
          }

          // Any country is reachable even when it is not in the list: what you
          // typed is looked up directly.
          Button {
            width: body.width
            visible: root.browseStage === "country"
                     && String(filterField.text).trim().length >= 3
                     && root.visibleRows.length === 0
            bordered: true
            text: "Look up country \"" + String(filterField.text).trim() + "\""
            foreground: root.fg
            fontFamily: root.fontFam
            fontSize: Style.font.bodySmall
            onClicked: root.chooseCountry(String(filterField.text).trim())
          }

          Text {
            width: body.width
            visible: root.browseStage === "team" && root.browseNote === ""
                     && root.visibleRows.length === 0
                     && String(filterField.text).trim().length > 0
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: String(filterField.text).trim().length < 3
                  ? "Keep typing — three letters searches beyond the listed clubs."
                  : "Searching…"
            color: Qt.darker(root.fg, 1.5)
            font.family: root.fontFam
            font.pixelSize: Style.font.caption
          }

          Text {
            width: body.width
            visible: root.browseNote !== ""
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.browseNote
            color: Qt.darker(root.fg, 1.5)
            font.family: root.fontFam
            font.pixelSize: Style.font.caption
          }

          // The list is scrollable because a country list is 50 long and a
          // league's clubs can be too, and the popup should not grow to the
          // height of whichever one is showing.
          Flickable {
            width: parent.width
            height: Math.min(Style.space(210), rowsCol.implicitHeight)
            contentHeight: rowsCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: rowsCol
              width: parent.width
              spacing: Style.space(1)

              Repeater {
                model: root.visibleRows

                Button {
                  required property var modelData
                  width: body.width
                  bordered: false
                  // The league disambiguates: a country list carries both
                  // "Al-Hilal" and "Al Hilal Women".
                  text: modelData.name
                        + (root.browseStage === "team" && modelData.code ? "   ·   " + modelData.code : "")
                  foreground: root.fg
                  fontFamily: root.fontFam
                  fontSize: Style.font.bodySmall
                  onClicked: {
                    if (root.browseStage === "country") root.chooseCountry(modelData.name)
                    else root.pickTeam(modelData.id, modelData.name)
                  }
                }
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
              var far = delta >= 7 * 24 * 3600 * 1000
              return Qt.formatDateTime(d, "dddd d MMMM, hh:mm AP")
                     + (far && delta > 0 ? "   ·   in " + Model.countdown(delta) : "")
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
              if (root.showSettings) root.startBrowse()
              else root.browseNote = ""
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
