// Pure logic for the Next Match widget: no QML types, no I/O, no Date.now().
// Every function that depends on "now" takes it as a parameter, so the same
// input always renders the same output and the whole file is testable under
// Node (see test/model.test.js).

// ---------------------------------------------------------------- api-football

// The API answers 200 with an `errors` payload rather than an HTTP error code,
// so a "successful" response still has to be interrogated. `errors` is an
// object for auth/parameter problems and an empty ARRAY when all is well,
// which is why this checks for keys rather than truthiness.
function apiError(payload) {
  if (!payload || typeof payload !== "object") return "Bad response"
  var e = payload.errors
  if (!e) return ""
  if (Array.isArray(e)) return e.length > 0 ? String(e[0]) : ""
  var keys = Object.keys(e)
  if (keys.length === 0) return ""
  // token errors are the common case and deserve a short, actionable line
  // rather than the API's paragraph pointing at its own documentation.
  if (keys.indexOf("token") !== -1) return "Check your API key"
  if (keys.indexOf("requests") !== -1) return "Daily request limit reached"
  return String(e[keys[0]])
}

// The API's own words, kept verbatim for the panel. A short label belongs in
// the bar; the reason the request was refused belongs where it can be read and
// acted on, rather than being flattened into one of our own sentences.
function rawApiError(payload) {
  if (!payload || typeof payload !== "object") return ""
  var e = payload.errors
  if (!e || Array.isArray(e)) return ""
  var parts = []
  for (var k in e) parts.push(k + ": " + String(e[k]))
  return parts.join("  ")
}

function firstFixture(payload) {
  if (!payload || !Array.isArray(payload.response) || payload.response.length === 0) return null
  return payload.response[0]
}

// -------------------------------------------------------------- thesportsdb

// A second provider, because api-football's free plan cannot read the current
// season and so cannot answer this widget's only question. TheSportsDB answers
// it for free, including leagues api-football's free tier locks away.
//
// Events are adapted into the api-football shape rather than the display code
// being taught two vocabularies: everything downstream stays provider-blind.

var SDB_BASE = "https://www.thesportsdb.com/api/v1/json/"

function sdbUrl(key, path) {
  return SDB_BASE + (String(key || "").trim() || "3") + "/" + path
}

function sdbNextUrl(key, teamId) { return sdbUrl(key, "eventsnext.php?id=" + teamId) }
function sdbSearchUrl(key, query) {
  return sdbUrl(key, "searchteams.php?t=" + encodeURIComponent(String(query || "").trim()))
}

// strTimestamp has no zone marker but is UTC — strTime is 18:00:00 where
// strTimeLocal is 21:00:00 for a Saudi kick-off. Parsing it as local time
// would move every fixture by the viewer's offset.
function sdbKickoffMs(ev) {
  if (!ev) return NaN
  var stamp = String(ev.strTimestamp || "").trim()
  if (stamp) {
    var iso = /(Z|[+-]\d{2}:?\d{2})$/.test(stamp) ? stamp : stamp + "Z"
    var t = Date.parse(iso)
    if (!isNaN(t)) return t
  }
  var d = String(ev.dateEvent || "").trim()
  var tm = String(ev.strTime || "00:00:00").trim()
  if (!d) return NaN
  var t2 = Date.parse(d + "T" + tm + "Z")
  return isNaN(t2) ? NaN : t2
}

function sdbStatus(ev) {
  if (!ev) return "NS"
  if (String(ev.strPostponed || "").toLowerCase() === "yes") return "PST"
  var raw = String(ev.strStatus || "").trim()
  if (!raw || raw === "-") return "NS"
  var up = raw.toUpperCase()
  // TheSportsDB mostly speaks the same short codes; spell out the long forms.
  if (/MATCH FINISHED|FINISHED|FULL ?TIME/.test(up)) return "FT"
  if (/HALF ?TIME/.test(up)) return "HT"
  if (/NOT ?STARTED/.test(up)) return "NS"
  return up
}

function sdbInt(value) {
  var n = parseInt(String(value === null || value === undefined ? "" : value), 10)
  return isFinite(n) ? n : null
}

// TheSportsDB event -> the fixture shape the rest of this file already speaks.
function sdbToFixture(ev) {
  if (!ev) return null
  var ko = sdbKickoffMs(ev)
  if (!isFinite(ko)) return null
  return {
    fixture: {
      timestamp: Math.round(ko / 1000),
      status: { short: sdbStatus(ev), elapsed: sdbInt(ev.strProgress) },
      venue: { name: String(ev.strVenue || ""), city: "" }
    },
    teams: {
      home: { id: sdbInt(ev.idHomeTeam), name: String(ev.strHomeTeam || "") },
      away: { id: sdbInt(ev.idAwayTeam), name: String(ev.strAwayTeam || "") }
    },
    goals: { home: sdbInt(ev.intHomeScore), away: sdbInt(ev.intAwayScore) },
    league: {
      name: String(ev.strLeague || ""),
      round: ev.intRound ? "Round " + ev.intRound : ""
    }
  }
}

// TheSportsDB answers with `events: null` rather than an empty list when a team
// has nothing scheduled, which JSON.parse turns into null, not [].
function sdbFixtures(payload) {
  if (!payload) return []
  var events = payload.events || payload.results
  if (!Array.isArray(events)) return []
  var out = []
  for (var i = 0; i < events.length; ++i) {
    var fx = sdbToFixture(events[i])
    if (fx) out.push(fx)
  }
  return { response: out }
}

function sdbTeams(payload) {
  var teams = payload && Array.isArray(payload.teams) ? payload.teams : []
  var out = []
  for (var i = 0; i < teams.length; ++i) {
    var t = teams[i]
    if (!t || !t.idTeam) continue
    out.push({
      id: sdbInt(t.idTeam),
      name: String(t.strTeam || ""),
      country: String(t.strCountry || ""),
      code: String(t.strLeague || "")
    })
  }
  return out
}

// ------------------------------------------------------------------ match state

var LIVE_STATUS = ["1H", "2H", "HT", "ET", "BT", "P", "LIVE", "INT", "SUSP"]
var DONE_STATUS = ["FT", "AET", "PEN"]
var OFF_STATUS = ["PST", "CANC", "ABD", "AWD", "WO", "SUSP_OFF"]

function statusShort(fx) {
  return fx && fx.fixture && fx.fixture.status ? String(fx.fixture.status.short || "") : ""
}

function matchState(fx) {
  var s = statusShort(fx)
  if (LIVE_STATUS.indexOf(s) !== -1) return "live"
  if (DONE_STATUS.indexOf(s) !== -1) return "finished"
  if (OFF_STATUS.indexOf(s) !== -1) return "off"
  return "scheduled"
}

function kickoffMs(fx) {
  if (!fx || !fx.fixture) return NaN
  // Prefer the unix timestamp: it is unambiguous, where the ISO string carries
  // an offset that Date parsing has historically disagreed about.
  if (typeof fx.fixture.timestamp === "number") return fx.fixture.timestamp * 1000
  var t = Date.parse(String(fx.fixture.date || ""))
  return isNaN(t) ? NaN : t
}

// ------------------------------------------------------------------- team names

var NOISE = ["fc", "afc", "cf", "ac", "sc", "sv", "if", "bk", "cd", "ud", "rc", "as", "ss", "us"]

// A 3-letter code for the bar pill. The fixtures endpoint carries only
// id/name/logo per team, so this derives one: the longest significant word
// wins, which turns "Real Madrid" into MAD rather than REA and keeps
// "Manchester United" as MAN.
function shortCode(name) {
  var raw = String(name || "").trim()
  if (!raw) return ""
  var words = raw.split(/[\s.\-]+/).filter(function(w) {
    return w.length > 0 && NOISE.indexOf(w.toLowerCase()) === -1
  })
  if (words.length === 0) words = [raw]
  var best = words[0]
  for (var i = 1; i < words.length; ++i)
    if (words[i].length > best.length) best = words[i]
  return best.slice(0, 3).toUpperCase()
}

// Which side is the configured team, and who are they facing.
function sides(fx, teamId) {
  if (!fx || !fx.teams) return null
  var home = fx.teams.home || {}
  var away = fx.teams.away || {}
  var id = parseInt(teamId, 10)
  var isHome = home.id === id
  var isAway = away.id === id
  // An unrecognised id still renders: treat the home side as "ours" rather
  // than blanking the widget, so a mistyped id shows a match to correct
  // against instead of an empty pill.
  if (!isHome && !isAway) isHome = true
  return {
    us: isHome ? home : away,
    them: isHome ? away : home,
    home: home,
    away: away,
    atHome: isHome
  }
}

// -------------------------------------------------------------------- countdown

function countdown(ms) {
  if (!isFinite(ms) || ms <= 0) return "now"
  var mins = Math.floor(ms / 60000)
  if (mins < 1) return "now"
  if (mins < 60) return mins + "m"
  var hours = Math.floor(mins / 60)
  if (hours < 24) return hours + "h"
  var days = Math.floor(hours / 24)
  var rem = hours % 24
  return rem > 0 ? days + "d " + rem + "h" : days + "d"
}

// Weekday + local time, e.g. "Sat 18:30". Built from the parts the caller
// resolves, so the timezone decision stays outside this file.
function whenLabel(parts) {
  if (!parts) return ""
  return parts.weekday + " " + parts.time
}

// ------------------------------------------------------------------- pill label

// Adaptive: a date while the match is far off, a countdown once it is close
// enough that "how long" is the real question, and the score while it is on.
function pillLabel(fx, nowMs, opts) {
  opts = opts || {}
  if (!fx) return opts.emptyText || "No match"

  var state = matchState(fx)
  var s = sides(fx, opts.teamId)
  if (!s) return opts.emptyText || "No match"

  if (state === "live" && opts.showLive !== false) {
    var goals = fx.goals || {}
    var hg = goals.home === null || goals.home === undefined ? 0 : goals.home
    var ag = goals.away === null || goals.away === undefined ? 0 : goals.away
    var elapsed = fx.fixture && fx.fixture.status ? fx.fixture.status.elapsed : null
    var clock = statusShort(fx) === "HT" ? "HT" : (elapsed ? elapsed + "'" : "")
    var line = shortCode(s.home.name) + " " + hg + " - " + ag + " " + shortCode(s.away.name)
    return clock ? line + "  " + clock : line
  }

  if (state === "off") return shortCode(s.them.name) + "  " + (statusShort(fx) === "PST" ? "postponed" : "off")

  var ko = kickoffMs(fx)
  var delta = ko - nowMs

  // Once it has started but the API has not flipped the status yet, the
  // countdown would read "now" forever; say kick-off instead.
  if (delta <= 0) return (opts.atPrefix !== false ? (s.atHome ? "vs " : "at ") : "") + s.them.name + "  kick-off"

  if (delta > 24 * 3600 * 1000)
    return shortCode(s.them.name) + "  " + whenLabel(opts.when)

  return (s.atHome ? "vs " : "at ") + s.them.name + "  in " + countdown(delta)
}

// ---------------------------------------------------------------- refresh pacing

// The free plan allows 100 requests a day, reset at 00:00 UTC, so polling is
// paced by how soon the answer can change rather than by a fixed interval.
// Worst case (a match day with live polling on) lands near 55 requests.
function refreshMinutes(fx, nowMs, baseMinutes, showLive) {
  var base = parseInt(baseMinutes, 10)
  if (!isFinite(base) || base < 15) base = 60

  if (!fx) return base
  var state = matchState(fx)
  if (state === "live") return showLive === false ? base : 5
  if (state === "finished") return 15   // the next fixture should appear shortly
  if (state === "off") return base

  var delta = kickoffMs(fx) - nowMs
  if (!isFinite(delta)) return base
  if (delta <= 0) return 5              // started, waiting for the status flip
  if (delta < 3600 * 1000) return 15
  if (delta < 24 * 3600 * 1000) return 60
  return Math.max(base, 360)
}

// -------------------------------------------------------------------- key specs

// The key may be pasted directly, or kept out of shell.json with `file:` or
// `env:`. Anyone syncing their dotfiles to a public remote wants the latter.
function parseKeySpec(spec) {
  var raw = String(spec === undefined || spec === null ? "" : spec).trim()
  if (!raw) return { mode: "none", value: "" }
  if (raw.indexOf("file:") === 0) return { mode: "file", value: raw.slice(5).trim() }
  if (raw.indexOf("env:") === 0) return { mode: "env", value: raw.slice(4).trim() }
  return { mode: "inline", value: raw }
}

// Shell snippet that resolves a key spec to stdout without ever putting the
// key itself in argv, where `ps` would show it to every local user. Runs under
// bash: `${!var}` is bash's indirect expansion, and `${var/#~/$HOME}` is how a
// leading tilde in a configured path gets expanded, since the shell only
// expands `~` in literals, never inside a variable.
function keyResolverScript(spec) {
  var parsed = parseKeySpec(spec)
  if (parsed.mode === "file") return 'cat -- "${NM_KEY_REF/#\\~/$HOME}" 2>/dev/null'
  if (parsed.mode === "env") return 'printf %s "${!NM_KEY_REF-}"'
  return 'printf %s "$NM_KEY"'
}

// ------------------------------------------------------------- fixture queries

// The free plan does not accept `next`, so the widget has more than one way to
// ask the same question and remembers which one the account is allowed to use.
//   next   — one request, exactly the next fixture. Paid plans.
//   range  — this season plus a date window, filtered here.
//   season — the whole season, filtered here. The last resort: biggest payload,
//            but it is the query most plans allow.
var QUERY_MODES = ["next", "range", "season"]

function nextQueryMode(mode) {
  var i = QUERY_MODES.indexOf(String(mode || "next"))
  return i < 0 || i + 1 >= QUERY_MODES.length ? "" : QUERY_MODES[i + 1]
}

function isoDate(ms) {
  var d = new Date(ms)
  function pad(n) { return (n < 10 ? "0" : "") + n }
  return d.getUTCFullYear() + "-" + pad(d.getUTCMonth() + 1) + "-" + pad(d.getUTCDate())
}

// api-football labels a season by the calendar year it starts in, and European
// seasons start in August. Before then, the current season is last year's.
function seasonFor(ms) {
  var d = new Date(ms)
  return d.getUTCMonth() >= 6 ? d.getUTCFullYear() : d.getUTCFullYear() - 1
}

function fixtureUrl(teamId, mode, nowMs, windowDays) {
  var base = "https://v3.football.api-sports.io/fixtures?team=" + teamId
  var days = windowDays === undefined ? 120 : windowDays
  if (mode === "range")
    return base + "&season=" + seasonFor(nowMs) +
      "&from=" + isoDate(nowMs) + "&to=" + isoDate(nowMs + days * 86400000)
  if (mode === "season") return base + "&season=" + seasonFor(nowMs)
  return base + "&next=1"
}

// Why the API refused, which decides whether trying another query shape can
// possibly help:
//   "parameter" — this query shape is not allowed, but another might be.
//   "season"    — the account cannot see the current season at all. No query
//                 shape has an upcoming fixture to return, so stop: cycling
//                 modes would only spend the daily allowance to be refused
//                 three times instead of once.
//   "plan"      — some other plan restriction.
function planRefusal(payload) {
  var raw = rawApiError(payload)
  if (!raw) return ""
  if (/access to this season/i.test(raw)) return "season"
  if (/access to the \s*\w+\s*parameter/i.test(raw)) return "parameter"
  if (/plan|subscription|upgrade|not allowed/i.test(raw)) return "plan"
  return ""
}

function isPlanRefusal(payload) {
  return planRefusal(payload) !== ""
}

// "…try from 2022 to 2024." -> "2022-2024", for a message that says what the
// account can actually see instead of only what it cannot.
function seasonHint(payload) {
  var m = /try from (\d{4}) to (\d{4})/i.exec(rawApiError(payload))
  return m ? m[1] + "-" + m[2] : ""
}

// From any of the query shapes, the fixture that is on now or soonest next.
// A match already running still has a kick-off in the past, so the window
// reaches back far enough to keep one rather than skip to the following game.
function pickNextFixture(payload, nowMs) {
  if (!payload || !Array.isArray(payload.response)) return null
  var candidates = []
  for (var i = 0; i < payload.response.length; ++i) {
    var fx = payload.response[i]
    var ko = kickoffMs(fx)
    if (!isFinite(ko)) continue
    var state = matchState(fx)
    if (state === "live") return fx
    if (state === "finished" || state === "off") continue
    if (ko >= nowMs - 3 * 3600 * 1000) candidates.push({ fx: fx, ko: ko })
  }
  if (candidates.length === 0) return null
  candidates.sort(function(a, b) { return a.ko - b.ko })
  return candidates[0].fx
}

// ---------------------------------------------------------------- team search

// api-football rejects a search shorter than 3 characters, so the UI can say
// so instead of spending a request to be told.
function searchValid(query) {
  return String(query || "").trim().length >= 3
}

function teamsUrl(query) {
  return "https://v3.football.api-sports.io/teams?search=" +
    encodeURIComponent(String(query || "").trim())
}

function parseTeams(payload) {
  if (!payload || !Array.isArray(payload.response)) return []
  var out = []
  for (var i = 0; i < payload.response.length; ++i) {
    var t = payload.response[i] && payload.response[i].team
    if (!t || !t.id) continue
    out.push({
      id: t.id,
      name: String(t.name || ""),
      country: String(t.country || ""),
      code: String(t.code || "")
    })
  }
  return out
}

// What to show in the key field. A file:/env: reference is a path, not a
// secret, so it stays readable; a pasted key is masked.
function keyIsSecret(spec) {
  return parseKeySpec(spec).mode === "inline"
}

// --------------------------------------------------------------------- sanitize

// Bar labels render through a Text that would otherwise rich-text-parse a
// crafted setting, so anything user-supplied is flattened first.
function plainText(value) {
  return String(value === undefined || value === null ? "" : value).replace(/[<>&]/g, "")
}

function validTeamId(value) {
  var n = parseInt(value, 10)
  return isFinite(n) && n > 0 ? n : 0
}

if (typeof module !== "undefined") {
  module.exports = {
    sdbUrl: sdbUrl,
    sdbNextUrl: sdbNextUrl,
    sdbSearchUrl: sdbSearchUrl,
    sdbKickoffMs: sdbKickoffMs,
    sdbStatus: sdbStatus,
    sdbToFixture: sdbToFixture,
    sdbFixtures: sdbFixtures,
    sdbTeams: sdbTeams,
    apiError: apiError,
    rawApiError: rawApiError,
    firstFixture: firstFixture,
    statusShort: statusShort,
    matchState: matchState,
    kickoffMs: kickoffMs,
    shortCode: shortCode,
    sides: sides,
    countdown: countdown,
    whenLabel: whenLabel,
    pillLabel: pillLabel,
    refreshMinutes: refreshMinutes,
    parseKeySpec: parseKeySpec,
    keyResolverScript: keyResolverScript,
    nextQueryMode: nextQueryMode,
    isoDate: isoDate,
    seasonFor: seasonFor,
    fixtureUrl: fixtureUrl,
    isPlanRefusal: isPlanRefusal,
    planRefusal: planRefusal,
    seasonHint: seasonHint,
    pickNextFixture: pickNextFixture,
    searchValid: searchValid,
    teamsUrl: teamsUrl,
    parseTeams: parseTeams,
    keyIsSecret: keyIsSecret,
    plainText: plainText,
    validTeamId: validTeamId
  }
}
