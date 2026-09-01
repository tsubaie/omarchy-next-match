import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Owns the fixture data: settings, fetching, caching and pacing. BarWidget.qml
// reads `pillLabel`, the two club names and the two crest paths off this and
// draws the button.
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
  // version of it. Display reads `displayFixture`; pacing reads `fixture`,
  // which is the schedule.
  property var fixture: null
  property var liveFixture: null
  readonly property var displayFixture: root.liveFixture ? root.liveFixture : root.fixture
  property string errorText: ""
  property double lastFetchMs: 0
  property bool fetching: false
  // The process is intentionally single-flight. Remember which settings
  // launched it, and queue a replacement when they change mid-request so an
  // old team's response can never be applied to the new team.
  property int fetchTeamId: 0
  property string fetchKey: ""
  property bool pendingRefresh: false
  property string lastUrl: ""
  property double lastUrlAt: 0

  // Advanced by a timer rather than read at each use site, so every binding
  // showing a countdown re-evaluates together.
  property double nowMs: Date.now()

  readonly property bool idle: configured && errorText === "" && fixture === null
  readonly property bool needsAttention: !configured || errorText !== ""

  // Fixtures are team-specific. A shared filename can briefly show the
  // previously selected club after a restart or an offline team change.
  readonly property string cachePath: Quickshell.env("HOME") +
    "/.cache/omarchy-next-match/fixture-" + root.teamId + ".json"
  property string fetchUrl: ""

  // The bar draws both clubs, so it needs the parts rather than one string:
  // a crest cannot be interleaved into a Text.
  readonly property string homeName: root.sidesNow ? Model.plainText(root.sidesNow.home.name) : ""
  readonly property string awayName: root.sidesNow ? Model.plainText(root.sidesNow.away.name) : ""

  // ------------------------------------------------------------------- crests

  // Crests are PNGs on a CDN this plugin does not control, and an Image given a
  // remote source downloads whatever is served: sourceSize caps the decode, not
  // the transfer. So they are pulled by curl under a byte ceiling and drawn
  // from disk instead. Keyed by team id, which is stable, so each is fetched
  // once and survives a restart.
  readonly property string badgeDir: Quickshell.env("HOME") + "/.cache/omarchy-next-match/badges"
  property int badgeRevision: 0
  property string badgeSpec: ""

  function badgeFileUrl(team) {
    if (!root.showBadge) return ""
    var n = parseInt(team && team.id, 10)
    if (!isFinite(n) || n <= 0) return ""
    // The revision rides along as a fragment: file:// ignores it, while QML
    // sees a new source and re-reads the file once a fetch has landed.
    return "file://" + root.badgeDir + "/team-" + n + ".png#" + root.badgeRevision
  }

  readonly property string homeBadgeUrl: root.sidesNow ? root.badgeFileUrl(root.sidesNow.home) : ""
  readonly property string awayBadgeUrl: root.sidesNow ? root.badgeFileUrl(root.sidesNow.away) : ""

  // One "<id> <url>" line per crest. Rebuilt whenever the fixture changes; a
  // spec identical to the last one launches nothing.
  function syncBadges() {
    var fx = root.displayFixture
    if (!root.showBadge || !fx || !fx.teams || !fx.badges || badgeProc.running) return
    var lines = []
    function want(team, url) {
      var n = parseInt(team && team.id, 10)
      var u = Model.sdbImageUrl(url)
      if (isFinite(n) && n > 0 && u !== "") lines.push(n + " " + u)
    }
    want(fx.teams.home, fx.badges.home)
    want(fx.teams.away, fx.badges.away)
    var spec = lines.join("\n")
    if (spec === "" || spec === root.badgeSpec) return
    root.badgeSpec = spec
    badgeProc.running = true
  }

  onDisplayFixtureChanged: syncBadges()

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
    return s ? Model.plainText(s.home.name) + " v " + Model.plainText(s.away.name) : "Next Match"
  }

  // ------------------------------------------------------------------ fetching

  function refresh(force) {
    if (!configured) return
    if (fetchProc.running) {
      if (root.fetchTeamId !== root.teamId || root.fetchKey !== root.sdbKey)
        root.pendingRefresh = true
      return
    }
    // A reload storm (theme switch, plugin rescan) must not re-fetch on every
    // pass: ignore anything inside a minute unless a human asked.
    if (!force && root.lastFetchMs > 0 && Date.now() - root.lastFetchMs < 60000) return
    var url = Model.sdbNextUrl(root.sdbKey, root.teamId)
    if (url === root.lastUrl && Date.now() - root.lastUrlAt < 5000) return
    root.lastUrl = url
    root.lastUrlAt = Date.now()
    root.fetchUrl = url
    root.fetchTeamId = root.teamId
    root.fetchKey = root.sdbKey
    root.fetching = true
    fetchProc.running = true
  }

  function applyPayload(payload, fromCache) {
    var next = Model.pickNextFixture(Model.sdbFixtures(payload), Date.now())
    if (next !== null && !Model.fixtureHasTeam(next, root.teamId)) return false
    root.errorText = ""
    root.fixture = next
    if (!fromCache) root.lastFetchMs = Date.now()
    scheduleNext()
    return true
  }

  function onFetched(raw) {
    root.fetching = false
    // Settings may have changed while curl was in flight. Its output and cache
    // belong to the captured request, not to whatever is selected now.
    if (root.fetchTeamId !== root.teamId || root.fetchKey !== root.sdbKey) {
      root.pendingRefresh = true
      return
    }
    var text = String(raw || "").trim()
    if (text === "") {
      // curl failed (offline, DNS, timeout). Keep the last good fixture rather
      // than blanking the bar, and try again on the normal schedule.
      root.errorText = root.fixture ? "" : "Offline"
      scheduleNext()
      return
    }
    // One byte over the cap means the body was truncated on the way in. Do not
    // hand a half-JSON document to the parser.
    if (Model.oversized(text)) {
      if (!root.fixture) root.errorText = "Bad response"
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
      if (!applyPayload(JSON.parse(text), false)) {
        root.errorText = "Bad response"
        scheduleNext()
      }
    } catch (e) {
      root.errorText = "Bad response"
      scheduleNext()
    }
  }

  function loadCache(text) {
    if (root.fixture !== null) return
    var raw = String(text || "").trim()
    if (raw === "" || Model.oversized(raw, Model.limits().cacheChars)) return
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
    if (text === "" || Model.oversized(text)) return
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
  onSdbKeyChanged: if (configured) refresh(true)

  Component.onCompleted: {
    cacheProc.running = true
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

  // Read through head rather than a FileView, so the read is bounded at the
  // source: a cache file that grew — or that something else replaced — is
  // truncated on the way in instead of being pulled into memory whole and
  // measured afterwards. A missing file is the normal first run, not an error.
  Process {
    id: cacheProc
    running: false
    command: ["bash", "-c", 'head -c $((NM_MAX + 1)) "$NM_CACHE" 2>/dev/null || true']
    environment: ({
      "NM_CACHE": root.cachePath,
      "NM_MAX": String(Model.limits().cacheChars)
    })
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadCache(text)
    }
  }

  // The URL travels in the environment and reaches curl through a config file
  // on stdin, so a personal key put in the path stays out of argv.
  Process {
    id: fetchProc
    running: false
    command: ["bash", "-c", root.fetchScript]
    environment: ({
      "NM_URL": root.fetchUrl,
      "NM_CACHE": root.cachePath,
      "NM_MAX": String(Model.limits().responseChars)
    })
    onRunningChanged: {
      if (!running && root.pendingRefresh) {
        root.pendingRefresh = false
        Qt.callLater(function() { root.refresh(true) })
      }
    }
    // onStreamFinished fires even when curl dies early, with empty text, so
    // there is no need for an onExited handler to clear `fetching` as well.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onFetched(text)
    }
  }

  // curl caps what it will accept and head caps what survives a server that
  // declares no length at all; one byte over the limit is read deliberately, so
  // the QML side can tell a truncated body from one that merely fits.
  readonly property string fetchScript:
    'out=$(printf \'url = "%s"\\n\' "$NM_URL" | curl -fsS --max-time 20 --max-filesize "$NM_MAX" -K - | head -c $((NM_MAX + 1)))\n' +
    // Preserve the last good cache on HTML/rate-limit/malformed/oversized
    // responses. events:null is a valid "nothing scheduled" response.
    'if [ -n "$out" ] && [ ${#out} -le "$NM_MAX" ] && printf %s "$out" | jq -e \'type == "object" and ((has("events") and ((.events == null) or (.events | type == "array"))) or (has("results") and (.results | type == "array")))\' >/dev/null 2>&1; then mkdir -p "$(dirname "$NM_CACHE")" && printf %s "$out" > "$NM_CACHE".tmp && mv -f "$NM_CACHE".tmp "$NM_CACHE"; fi\n' +
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
  property string pendingBrowseKind: ""
  property string pendingBrowseUrl: ""

  // Capped: a Repeater builds one Button per row, so the row count is a
  // rendering cost, not just a list length.
  readonly property var visibleRows: {
    var q = String(filterField.text).trim()
    var src = root.browseStage === "country" ? root.countryList : root.sortedTeams
    if (q === "") return Model.boundList(src)
    var out = []
    var cap = Model.limits().rows
    for (var i = 0; i < src.length && out.length < cap; ++i)
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
    if (browseProc.running) {
      // Navigation is allowed while the built-in country list is visible.
      // Keep the latest intent and launch it as soon as the current request
      // exits instead of silently dropping the click.
      root.pendingBrowseKind = kind
      root.pendingBrowseUrl = url
      root.browsing = true
      return
    }
    root.browseKind = kind
    root.browseUrl = url
    root.browseNote = "Loading…"
    root.browsing = true
    browseProc.running = true
  }

  // A country's club list is assembled from its leagues rather than from the
  // one country-wide call, because that call returns ten clubs alphabetically —
  // for Saudi Arabia it stops at Al-Bukiryah, so it has "Al Hilal Women" in it
  // but not Al-Hilal. Per league it is ten each, which between them covers the
  // clubs anyone is actually looking for.
  function chooseCountry(name) {
    // The single place a country name enters widget state, from the API list or
    // from the field. Flattened and clamped here so every label, placeholder
    // and note built from it downstream is already inside the boundary.
    root.chosenCountry = Model.plainText(name)
    root.browseStage = "team"
    root.teamList = []
    root.loadQueue = []
    root.searchState = "idle"
    root.searchForeignOnly = false
    filterField.text = ""
    fetchBrowse("leagues", Model.sdbLeaguesUrl(root.sdbKey, name))
  }

  readonly property var sortedTeams: {
    var copy = (root.teamList || []).slice()
    copy.sort(function(a, b) {
      var x = Model.normalizeName(a.name), y = Model.normalizeName(b.name)
      return x < y ? -1 : (x > y ? 1 : 0)
    })
    return copy
  }

  function drainQueue() {
    if (root.loadQueue.length === 0) {
      root.browsing = false
      root.browseNote = root.teamList.length === 0
        ? "No clubs listed for " + root.chosenCountry + "."
        : ""
      return
    }
    var rest = root.loadQueue.slice()
    var next = rest.shift()
    root.loadQueue = rest
    fetchBrowse("team", next)
  }

  // The shared key returns only ten clubs per country, alphabetically — the
  // Saudi list stops before Al-Hilal and the English one before Liverpool — so
  // the list alone cannot reach most clubs. Searching by name does, and its
  // hits are merged into the list, dropping anything from another country.
  function searchTeamsByName() {
    var q = String(filterField.text).trim()
    if (q.length < 3 || browseProc.running) return
    root.searchVariants = Model.sdbSearchVariants(q)
    root.searchState = "running"
    root.browseNote = ""
    root.browsing = true
    runTeamSearch()
  }

  property var searchVariants: []
  // Remaining club-list requests for the country being opened.
  property var loadQueue: []
  // "idle" until a search runs, then "running", then "done" — so an empty list
  // can say whether it is still working or has finished and found nothing.
  // Without this the placeholder said "Searching…" forever.
  property string searchState: "idle"
  // Set when a search found clubs but all of them are in other countries, so
  // the empty list can explain itself instead of just being empty.
  property bool searchForeignOnly: false

  function runTeamSearch() {
    if (root.searchVariants.length === 0) {
      root.browsing = false
      root.searchState = "done"
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
    if (Model.oversized(text)) {
      root.loadQueue = []
      root.browseNote = root.teamList.length > 0 ? "" : "That response was too large to read."
      return
    }
    if (Model.rateLimited(text)) {
      root.loadQueue = []
      root.browseNote = "TheSportsDB is rate-limiting its shared key. Wait a minute and try again."
      return
    }
    var payload = null
    if (text !== "") { try { payload = JSON.parse(text) } catch (e) { payload = null } }
    if (!payload) {
      // One competition failing is not a reason to abandon the others.
      if (root.browseKind === "team" && root.loadQueue.length > 0) { drainQueue(); return }
      root.browseNote = root.teamList.length > 0 ? "" : "Could not load — check your connection"
      return
    }

    if (root.browseKind === "country") {
      root.countryList = Model.sdbCountries(payload)
      root.browseNote = root.countryList.length === 0 ? "No countries returned" : ""
    } else if (root.browseKind === "leagues") {
      var leagues = Model.sdbLeagues(payload)
      var queue = []
      // A handful of competitions is plenty: the cups repeat the same clubs.
      for (var li = 0; li < leagues.length && li < 8; ++li)
        queue.push(Model.sdbLeagueTeamsUrl(root.sdbKey, leagues[li].name))
      queue.push(Model.sdbCountryTeamsUrl(root.sdbKey, root.chosenCountry))
      root.loadQueue = queue
      root.browseNote = "Loading clubs…"
      drainQueue()
    } else if (root.browseKind === "search") {
      var hits = Model.sdbTeams(payload)
      if (hits.length === 0) { runTeamSearch(); return }
      root.searchVariants = []
      root.searchState = "done"
      root.searchForeignOnly = Model.foreignOnly(hits, root.chosenCountry)
      root.teamList = Model.mergeTeams(root.teamList, hits, root.chosenCountry)
      root.browseNote = ""
    } else {
      root.teamList = Model.mergeTeams(root.teamList, Model.sdbTeams(payload), root.chosenCountry)
      drainQueue()
    }
  }

  // Apply locally first so the bar updates on the click itself, then persist
  // the merged entry through the shell. Keeping the host widget in sync also
  // prevents it from injecting an older settings object back into this panel.
  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings)
      if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget)
      root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function pickTeam(id, name) {
    root.browseNote = ""
    filterField.text = ""
    root.savedNote = "Now following " + Model.plainText(name)
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

  // Each crest is fetched at most once. curl refuses anything over the ceiling,
  // and the size is checked again before the file is moved into place, because
  // --max-filesize only acts on a length the server actually declares.
  Process {
    id: badgeProc
    running: false
    command: ["bash", "-c", root.badgeScript]
    environment: ({
      "NM_SPEC": root.badgeSpec,
      "NM_DIR": root.badgeDir,
      "NM_MAX": String(Model.limits().imageBytes)
    })
    onExited: root.badgeRevision++
  }

  readonly property string badgeScript:
    'mkdir -p "$NM_DIR" || exit 0\n' +
    // %s\n, not %s: read gives up on a final line with no newline after it,
    // which would silently skip the away crest.
    'printf \'%s\\n\' "$NM_SPEC" | while read -r id url; do\n' +
    '  [ -n "$id" ] && [ -n "$url" ] || continue\n' +
    '  out="$NM_DIR/team-$id.png"\n' +
    '  [ -s "$out" ] && continue\n' +
    '  curl -fsS --max-time 15 --max-filesize "$NM_MAX" -o "$out.part" "$url" || { rm -f "$out.part"; continue; }\n' +
    '  if [ "$(wc -c < "$out.part")" -le "$NM_MAX" ]; then mv -f "$out.part" "$out"; else rm -f "$out.part"; fi\n' +
    'done\n'

  Process {
    id: liveProc
    running: false
    command: ["bash", "-c",
      'printf \'url = "%s"\\n\' "$NM_URL" | curl -fsS --max-time 20 --max-filesize "$NM_MAX" -K - | head -c $((NM_MAX + 1))']
    environment: ({ "NM_URL": root.liveUrl, "NM_MAX": String(Model.limits().responseChars) })
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onLive(text)
    }
  }

  Process {
    id: browseProc
    running: false
    command: ["bash", "-c",
      'printf \'url = "%s"\\n\' "$NM_URL" | curl -fsS --max-time 25 --max-filesize "$NM_MAX" -K - | head -c $((NM_MAX + 1))']
    environment: ({ "NM_URL": root.browseUrl, "NM_MAX": String(Model.limits().responseChars) })
    onRunningChanged: {
      if (!running && root.pendingBrowseUrl !== "") {
        var kind = root.pendingBrowseKind
        var url = root.pendingBrowseUrl
        root.pendingBrowseKind = ""
        root.pendingBrowseUrl = ""
        Qt.callLater(function() { root.fetchBrowse(kind, url) })
      }
    }
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
            text: root.browseStage === "country" ? "Pick a country" : Model.plainText(root.chosenCountry)
            textFormat: Text.PlainText
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
              placeholderText: root.browseStage === "country"
                               ? "filter countries"
                               : "type any club in " + Model.plainText(root.chosenCountry)
              foreground: root.fg
              font.family: root.fontFam
              font.pixelSize: Style.font.bodySmall
              onAccepted: if (root.browseStage === "team") root.searchTeamsByName()
              onTextChanged: {
                if (root.browseStage !== "team") return
                root.searchState = "idle"
                root.searchForeignOnly = false
                autoSearchTimer.restart()
              }
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
            text: "Look up country \"" + Model.plainText(String(filterField.text).trim(), 48) + "\""
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
                  : (root.searchState !== "done"
                     ? "Searching…"
                     : (root.searchForeignOnly
                        ? "Nothing in " + root.chosenCountry + " matched that. The search wants most of the name — try \"nassr\" rather than \"nass\"."
                        : "No club in " + root.chosenCountry + " found for \"" + String(filterField.text).trim() + "\"."))
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
                  text: Model.plainText(modelData.name)
                        + (root.browseStage === "team" && modelData.code
                           ? "   ·   " + Model.plainText(modelData.code) : "")
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
            textFormat: Text.PlainText
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
              source: root.homeBadgeUrl
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
              source: root.awayBadgeUrl
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
