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

function firstFixture(payload) {
  if (!payload || !Array.isArray(payload.response) || payload.response.length === 0) return null
  return payload.response[0]
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
    apiError: apiError,
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
    searchValid: searchValid,
    teamsUrl: teamsUrl,
    parseTeams: parseTeams,
    keyIsSecret: keyIsSecret,
    plainText: plainText,
    validTeamId: validTeamId
  }
}
