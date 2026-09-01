// Run with: node test/model.test.js
const M = require("../Model.js")

let pass = 0, fail = 0
function eq(actual, expected, label) {
  const a = JSON.stringify(actual), e = JSON.stringify(expected)
  if (a === e) { pass++; return }
  fail++
  console.error(`  FAIL ${label}\n    expected ${e}\n    actual   ${a}`)
}

const HOUR = 3600 * 1000, DAY = 24 * HOUR
const NOW = Date.parse("2026-09-01T12:00:00Z")

function fixture(overrides = {}) {
  return Object.assign({
    fixture: { timestamp: (NOW + 3 * DAY) / 1000, status: { short: "NS", elapsed: null } },
    teams: { home: { id: 40, name: "Liverpool" }, away: { id: 42, name: "Arsenal" } },
    goals: { home: null, away: null },
    league: { name: "Premier League", round: "Regular Season - 4" }
  }, overrides)
}

console.log("apiError")
eq(M.apiError({ errors: [] }), "", "empty array means success")
eq(M.apiError({ errors: {} }), "", "empty object means success")
eq(M.apiError({ errors: { token: "Error/Missing application key..." } }), "Check your API key", "token error")
eq(M.apiError({ errors: { requests: "limit" } }), "Daily request limit reached", "quota error")
eq(M.apiError(null), "Bad response", "null payload")

console.log("matchState")
eq(M.matchState(fixture()), "scheduled", "NS")
eq(M.matchState(fixture({ fixture: { timestamp: 1, status: { short: "2H", elapsed: 67 } } })), "live", "2H")
eq(M.matchState(fixture({ fixture: { timestamp: 1, status: { short: "HT" } } })), "live", "HT counts as live")
eq(M.matchState(fixture({ fixture: { timestamp: 1, status: { short: "FT" } } })), "finished", "FT")
eq(M.matchState(fixture({ fixture: { timestamp: 1, status: { short: "PST" } } })), "off", "postponed")

console.log("shortCode")
eq(M.shortCode("Arsenal"), "ARS", "single word")
eq(M.shortCode("Liverpool"), "LIV", "single word")
eq(M.shortCode("Real Madrid"), "MAD", "longest word wins")
eq(M.shortCode("Manchester United"), "MAN", "longest word wins")
eq(M.shortCode("FC Barcelona"), "BAR", "noise token dropped")
eq(M.shortCode(""), "", "empty")

console.log("countdown")
eq(M.countdown(12 * 60000), "12m", "minutes")
eq(M.countdown(4 * HOUR), "4h", "hours")
eq(M.countdown(3 * DAY + 4 * HOUR), "3d 4h", "days and hours")
eq(M.countdown(2 * DAY), "2d", "whole days drop the hours")
eq(M.countdown(-5), "now", "past")

console.log("sides")
eq(M.sides(fixture(), 40).them.name, "Arsenal", "our team at home -> opponent is away")
eq(M.sides(fixture(), 40).atHome, true, "at home")
eq(M.sides(fixture(), 42).them.name, "Liverpool", "our team away -> opponent is home")
eq(M.sides(fixture(), 42).atHome, false, "away")
eq(M.sides(fixture(), 999).them.name, "Arsenal", "unknown id still renders a match")

console.log("pillLabel (adaptive)")
const opts = { teamId: 40, when: { weekday: "Sat", time: "18:30" } }
eq(M.pillLabel(fixture(), NOW, opts), "ARS  Sat 18:30", "far away -> code + date")
eq(M.pillLabel(fixture({ fixture: { timestamp: (NOW + 4 * HOUR) / 1000, status: { short: "NS" } } }), NOW, opts),
   "vs Arsenal  in 4h", "match day -> countdown, home")
eq(M.pillLabel(fixture({ fixture: { timestamp: (NOW + 12 * 60000) / 1000, status: { short: "NS" } } }), NOW, opts),
   "vs Arsenal  in 12m", "imminent")
eq(M.pillLabel(fixture({ fixture: { timestamp: (NOW + 4 * HOUR) / 1000, status: { short: "NS" } } }), NOW,
   { teamId: 42, when: opts.when }), "at Liverpool  in 4h", "away fixture says 'at'")
eq(M.pillLabel(fixture({
     fixture: { timestamp: (NOW - HOUR) / 1000, status: { short: "2H", elapsed: 67 } },
     goals: { home: 2, away: 1 }
   }), NOW, opts), "LIV 2 - 1 ARS  67'", "live score")
eq(M.pillLabel(fixture({
     fixture: { timestamp: (NOW - HOUR) / 1000, status: { short: "HT" } },
     goals: { home: 1, away: 0 }
   }), NOW, opts), "LIV 1 - 0 ARS  HT", "half time")
eq(M.pillLabel(fixture({
     fixture: { timestamp: (NOW - HOUR) / 1000, status: { short: "2H", elapsed: 67 } },
     goals: { home: 2, away: 1 }
   }), NOW, { teamId: 40, showLive: false, when: opts.when }),
   "vs Arsenal  kick-off", "live suppressed when showLive is off")
eq(M.pillLabel(null, NOW, opts), "No match", "no fixture")
eq(M.pillLabel(fixture({ goals: { home: null, away: null }, fixture: { timestamp: (NOW - HOUR) / 1000, status: { short: "1H", elapsed: 5 } } }), NOW, opts),
   "LIV 0 - 0 ARS  5'", "null goals render as 0")

console.log("refreshMinutes (quota pacing)")
eq(M.refreshMinutes(fixture(), NOW, 60, true), 360, "far away -> 6h")
eq(M.refreshMinutes(fixture({ fixture: { timestamp: (NOW + 4 * HOUR) / 1000, status: { short: "NS" } } }), NOW, 60, true), 60, "same day -> 1h")
eq(M.refreshMinutes(fixture({ fixture: { timestamp: (NOW + 30 * 60000) / 1000, status: { short: "NS" } } }), NOW, 60, true), 15, "within the hour -> 15m")
eq(M.refreshMinutes(fixture({ fixture: { timestamp: 1, status: { short: "2H", elapsed: 60 } } }), NOW, 60, true), 5, "live -> 5m")
eq(M.refreshMinutes(fixture({ fixture: { timestamp: 1, status: { short: "2H", elapsed: 60 } } }), NOW, 60, false), 60, "live with showLive off -> base")
eq(M.refreshMinutes(null, NOW, 60, true), 60, "no fixture -> base")
eq(M.refreshMinutes(fixture(), NOW, 5, true), 360, "a base below the floor is ignored")

// The pacing above must fit inside the free plan's 100 requests/day.
{
  let requests = 0, t = NOW, end = NOW + DAY
  const kickoff = NOW + 20 * HOUR
  while (t < end) {
    requests++
    const delta = kickoff - t
    let fx
    if (delta > 0) fx = fixture({ fixture: { timestamp: kickoff / 1000, status: { short: "NS" } } })
    else if (delta > -2 * HOUR) fx = fixture({ fixture: { timestamp: kickoff / 1000, status: { short: "2H", elapsed: 60 } } })
    else fx = fixture({ fixture: { timestamp: kickoff / 1000, status: { short: "FT" } } })
    t += M.refreshMinutes(fx, t, 60, true) * 60000
  }
  console.log(`  worst-case match day: ${requests} requests (free plan allows 100)`)
  if (requests > 100) { fail++; console.error("  FAIL exceeds the free plan budget") } else pass++
}

console.log("parseKeySpec")
eq(M.parseKeySpec("abc123"), { mode: "inline", value: "abc123" }, "pasted key")
eq(M.parseKeySpec("file:~/.config/nm/key"), { mode: "file", value: "~/.config/nm/key" }, "file ref")
eq(M.parseKeySpec("env:API_FOOTBALL_KEY"), { mode: "env", value: "API_FOOTBALL_KEY" }, "env ref")
eq(M.parseKeySpec("  "), { mode: "none", value: "" }, "blank")
eq(M.parseKeySpec(undefined), { mode: "none", value: "" }, "undefined")

console.log("plainText / validTeamId")
eq(M.plainText("<b>x</b>"), "bx/b", "markup stripped")
eq(M.validTeamId("40"), 40, "numeric string")
eq(M.validTeamId("nope"), 0, "garbage -> 0")
eq(M.validTeamId(-3), 0, "negative -> 0")

// ---- team search helpers
console.log("\nteam search")
eq(M.searchValid("li"), false, "under 3 chars rejected before spending a request")
eq(M.searchValid("liv"), true, "3 chars ok")
eq(M.searchValid("  a  "), false, "whitespace does not count")
eq(M.teamsUrl("real madrid"), "https://v3.football.api-sports.io/teams?search=real%20madrid", "query encoded")
eq(M.parseTeams({ response: [
     { team: { id: 40, name: "Liverpool", country: "England", code: "LIV" } },
     { team: { id: null, name: "broken" } },
     { notteam: 1 }
   ] }), [{ id: 40, name: "Liverpool", country: "England", code: "LIV" }], "malformed rows dropped")
eq(M.parseTeams({}), [], "no response array")
eq(M.keyIsSecret("abc123"), true, "pasted key is masked")
eq(M.keyIsSecret("file:~/x"), false, "file ref is not a secret")
eq(M.keyIsSecret("env:FOO"), false, "env ref is not a secret")

// ---- query modes and free-plan fallback
console.log("\nquery modes")
eq(M.nextQueryMode("next"), "range", "next falls back to range")
eq(M.nextQueryMode("range"), "season", "range falls back to season")
eq(M.nextQueryMode("season"), "", "season is the last resort")
eq(M.seasonFor(Date.parse("2026-09-01T00:00:00Z")), 2026, "September is the new season")
eq(M.seasonFor(Date.parse("2026-03-01T00:00:00Z")), 2025, "March still belongs to last year's season")
eq(M.isoDate(Date.parse("2026-09-01T22:00:00Z")), "2026-09-01", "iso date in UTC")
eq(M.fixtureUrl(40, "next", NOW), "https://v3.football.api-sports.io/fixtures?team=40&next=1", "next url")
eq(M.fixtureUrl(40, "season", NOW), "https://v3.football.api-sports.io/fixtures?team=40&season=2026", "season url")

console.log("plan refusal detection")
eq(M.isPlanRefusal({ errors: { plan: "This parameter is not available for your plan" } }), true, "plan wording")
eq(M.isPlanRefusal({ errors: { access: "upgrade your subscription" } }), true, "upgrade wording")
eq(M.isPlanRefusal({ errors: { token: "Missing application key" } }), false, "a key problem is not a plan problem")
eq(M.isPlanRefusal({ errors: [] }), false, "success is not a refusal")

console.log("pickNextFixture")
{
  const far = fixture({ fixture: { timestamp: (NOW + 10 * DAY) / 1000, status: { short: "NS" } } })
  const soon = fixture({ fixture: { timestamp: (NOW + 2 * DAY) / 1000, status: { short: "NS" } } })
  const done = fixture({ fixture: { timestamp: (NOW - 5 * DAY) / 1000, status: { short: "FT" } } })
  const live = fixture({ fixture: { timestamp: (NOW - HOUR) / 1000, status: { short: "2H", elapsed: 60 } } })
  eq(M.kickoffMs(M.pickNextFixture({ response: [far, soon, done] }, NOW)), M.kickoffMs(soon), "earliest upcoming wins")
  eq(M.pickNextFixture({ response: [done] }, NOW), null, "only finished -> nothing")
  eq(M.kickoffMs(M.pickNextFixture({ response: [far, live] }, NOW)), M.kickoffMs(live), "a running match beats a future one")
  eq(M.pickNextFixture({ response: [] }, NOW), null, "empty season")
  eq(M.kickoffMs(M.pickNextFixture({ response: [soon] }, NOW)), M.kickoffMs(soon), "single result from next=1")
}

// ---- real refusals observed from a Free account
console.log("\nplan refusal classification (verbatim API messages)")
const NEXT_ERR   = { errors: { plan: "Free plans do not have access to the Next parameter." } }
const LAST_ERR   = { errors: { plan: "Free plans do not have access to the Last parameter." } }
const SEASON_ERR = { errors: { plan: "Free plans do not have access to this season, try from 2022 to 2024." } }
const NOSEASON   = { errors: { season: "The Season field is required." } }
eq(M.planRefusal(NEXT_ERR), "parameter", "next parameter -> try another shape")
eq(M.planRefusal(LAST_ERR), "parameter", "last parameter -> try another shape")
eq(M.planRefusal(SEASON_ERR), "season", "season lockout -> terminal, stop cycling")
eq(M.planRefusal(NOSEASON), "", "a missing field is our bug, not a plan limit")
eq(M.planRefusal({ errors: { token: "Missing application key" } }), "", "key problem is not a plan problem")
eq(M.seasonHint(SEASON_ERR), "2022-2024", "the years the key can actually see")
eq(M.seasonHint(NEXT_ERR), "", "no hint when none offered")

// ---- TheSportsDB adapter, against a real captured payload
console.log("\nthesportsdb adapter")
const SDB_EVENT = {
  idEvent: "2573336", strEvent: "Al-Hilal vs Al-Ahli",
  strLeague: "Saudi-Arabian Pro League", idLeague: "4668", intRound: "3",
  strHomeTeam: "Al-Hilal", strAwayTeam: "Al-Ahli",
  idHomeTeam: "136013", idAwayTeam: "137721",
  intHomeScore: null, intAwayScore: null,
  strStatus: "NS", strProgress: null, strPostponed: "no",
  dateEvent: "2026-09-01", strTime: "18:00:00",
  strTimeLocal: "21:00:00", strTimestamp: "2026-09-01T18:00:00",
  strVenue: "Kingdom Arena"
}

// The zone bug that would silently move every kick-off: strTimestamp carries no
// marker but is UTC (strTimeLocal is +3 for this fixture).
eq(M.sdbKickoffMs(SDB_EVENT), Date.parse("2026-09-01T18:00:00Z"), "timestamp read as UTC, not local")
eq(M.sdbKickoffMs({ dateEvent: "2026-09-01", strTime: "18:00:00" }), Date.parse("2026-09-01T18:00:00Z"), "falls back to date + time")
eq(M.sdbKickoffMs({}), NaN, "no date -> NaN")
eq(M.sdbKickoffMs({ strTimestamp: "2026-09-01T18:00:00Z" }), Date.parse("2026-09-01T18:00:00Z"), "an explicit Z is not doubled")

eq(M.sdbStatus(SDB_EVENT), "NS", "not started")
eq(M.sdbStatus({ strStatus: "Match Finished" }), "FT", "long form finished")
eq(M.sdbStatus({ strStatus: "Half Time" }), "HT", "long form half time")
eq(M.sdbStatus({ strStatus: "" }), "NS", "blank means not started")
eq(M.sdbStatus({ strStatus: "-" }), "NS", "placeholder means not started")
eq(M.sdbStatus({ strPostponed: "yes", strStatus: "NS" }), "PST", "postponed wins")

{
  const fx = M.sdbToFixture(SDB_EVENT)
  eq(fx.teams.home.name, "Al-Hilal", "home team")
  eq(fx.teams.home.id, 136013, "ids become numbers so they compare with the setting")
  eq(fx.goals.home, null, "no score yet")
  eq(fx.league.round, "Round 3", "round labelled")
  eq(M.matchState(fx), "scheduled", "state via the shared vocabulary")
  eq(M.pillLabel(fx, Date.parse("2026-09-01T12:00:00Z"),
     { teamId: 136013, when: { weekday: "Tue", time: "21:00" } }),
     "vs Al-Ahli  in 6h", "renders through the same pill logic as api-football")
}

// events: null is what TheSportsDB sends for "nothing scheduled"
eq(M.sdbFixtures({ events: null }), [], "null events -> empty, not a crash")
eq(M.sdbFixtures(null), [], "no payload -> empty")
eq(M.sdbFixtures({ events: [SDB_EVENT] }).response.length, 1, "wrapped in the api-football envelope")
eq(M.sdbTeams({ teams: [{ idTeam: "136013", strTeam: "Al-Hilal", strCountry: "Saudi Arabia", strLeague: "Pro League" }] }),
   [{ id: 136013, name: "Al-Hilal", country: "Saudi Arabia", code: "Pro League" }], "team search rows")
eq(M.sdbTeams({ teams: null }), [], "no teams")
eq(M.sdbNextUrl("", 136013), "https://www.thesportsdb.com/api/v1/json/3/eventsnext.php?id=136013", "blank key uses the free test key")
eq(M.sdbNextUrl("mykey", 136013), "https://www.thesportsdb.com/api/v1/json/mykey/eventsnext.php?id=136013", "own key honoured")

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
