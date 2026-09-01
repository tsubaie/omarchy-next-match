// Pure logic for the Next Match widget: no QML types, no I/O, no Date.now().
// Every function that depends on "now" takes it as a parameter, so the same
// input always renders the same output and the whole file is testable under
// Node (see test/model.test.js).

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

// TheSportsDB's club search is unreliable on punctuation: "Al-Hilal" finds
// nothing where "Al Hilal SFC" finds it, because it matches the alternate-names
// field rather than the club name. Browsing a league is exact, so a search that
// comes back empty tries the query again as a league name.
function sdbLeagueTeamsUrl(key, league) {
  return sdbUrl(key, "search_all_teams.php?l=" + encodeURIComponent(String(league || "").trim()))
}

// The query, then the query with punctuation loosened. Tried in order.
function sdbSearchVariants(query) {
  var q = String(query || "").trim()
  if (!q) return []
  var out = [q]
  var spaced = q.replace(/[-_]+/g, " ").replace(/\s+/g, " ").trim()
  if (spaced && out.indexOf(spaced) === -1) out.push(spaced)
  return out
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
      round: ev.intRound ? "Round " + ev.intRound : "",
      logo: String(ev.strLeagueBadge || "")
    },
    badges: {
      home: String(ev.strHomeTeamBadge || ""),
      away: String(ev.strAwayTeamBadge || "")
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
      code: String(t.strLeague || ""),
      badge: String(t.strBadge || "")
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

// The opponent's badge. You already know which club is yours, so theirs is the
// one worth the pixels in the bar.
function opponentBadge(fx, teamId) {
  if (!fx || !fx.badges) return ""
  var s = sides(fx, teamId)
  if (!s) return ""
  return s.atHome ? String(fx.badges.away || "") : String(fx.badges.home || "")
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

// ------------------------------------------------------------------ selection

// The fixture that is on now, or the soonest one next. A match already running
// still has a kick-off in the past, so the window reaches back far enough to
// keep it rather than skipping ahead to the following game.
function pickNextFixture(payload, nowMs) {
  var list = upcomingFixtures(payload, nowMs, 1)
  return list.length > 0 ? list[0] : null
}


// Everything still to come, soonest first, with a match in progress at the
// front. Same rules as pickNextFixture, which is now just the first of these.
function upcomingFixtures(payload, nowMs, limit) {
  if (!payload || !Array.isArray(payload.response)) return []
  var live = []
  var later = []
  for (var i = 0; i < payload.response.length; ++i) {
    var fx = payload.response[i]
    var ko = kickoffMs(fx)
    if (!isFinite(ko)) continue
    var state = matchState(fx)
    if (state === "live") { live.push({ fx: fx, ko: ko }); continue }
    if (state === "finished" || state === "off") continue
    if (ko >= nowMs - 3 * 3600 * 1000) later.push({ fx: fx, ko: ko })
  }
  live.sort(function(a, b) { return a.ko - b.ko })
  later.sort(function(a, b) { return a.ko - b.ko })
  var all = live.concat(later)
  var out = []
  var max = limit === undefined ? all.length : limit
  for (var j = 0; j < all.length && out.length < max; ++j) out.push(all[j].fx)
  return out
}

// A short "Sat 18:30" / "12 Oct" for a row in the list, built from parts the
// caller resolves so the timezone decision stays outside this file.
function rowWhen(parts) {
  if (!parts) return ""
  return parts.weekday + " " + parts.day + "  " + parts.time
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

// ---------------------------------------------------------------- team search

// Too short a query matches half the world, so the UI says so rather than
// spending a request to be told.
function searchValid(query) {
  return String(query || "").trim().length >= 3
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
    sdbLeagueTeamsUrl: sdbLeagueTeamsUrl,
    sdbSearchVariants: sdbSearchVariants,
    sdbKickoffMs: sdbKickoffMs,
    sdbStatus: sdbStatus,
    sdbToFixture: sdbToFixture,
    sdbFixtures: sdbFixtures,
    sdbTeams: sdbTeams,
    statusShort: statusShort,
    matchState: matchState,
    kickoffMs: kickoffMs,
    shortCode: shortCode,
    sides: sides,
    opponentBadge: opponentBadge,
    countdown: countdown,
    whenLabel: whenLabel,
    pillLabel: pillLabel,
    refreshMinutes: refreshMinutes,
    pickNextFixture: pickNextFixture,
    upcomingFixtures: upcomingFixtures,
    rowWhen: rowWhen,
    searchValid: searchValid,
    plainText: plainText,
    validTeamId: validTeamId
  }
}
