// Run with: node test/model.test.js
// No network, no QML: every function that depends on "now" takes it as an
// argument, so these are deterministic.
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

// A real TheSportsDB payload, captured from the live API.
const EVENT = {
  idEvent: "2573336", strEvent: "Al-Hilal vs Al-Ahli",
  strLeague: "Saudi-Arabian Pro League", idLeague: "4668", intRound: "3",
  strHomeTeam: "Al-Hilal", strAwayTeam: "Al-Ahli",
  idHomeTeam: "136013", idAwayTeam: "137721",
  intHomeScore: null, intAwayScore: null,
  strStatus: "NS", strProgress: null, strPostponed: "no",
  dateEvent: "2026-09-01", strTime: "18:00:00",
  strTimeLocal: "21:00:00", strTimestamp: "2026-09-01T18:00:00",
  strVenue: "Kingdom Arena",
  strHomeTeamBadge: "https://r2.thesportsdb.com/images/media/team/badge/home.png",
  strAwayTeamBadge: "https://r2.thesportsdb.com/images/media/team/badge/away.png",
  strLeagueBadge: "https://r2.thesportsdb.com/images/media/league/badge/lg.png"
}
const ev = (o = {}) => Object.assign({}, EVENT, o)
const fx = (o = {}) => M.sdbToFixture(ev(o))

console.log("time zones")
// strTimestamp carries no zone marker but is UTC: strTimeLocal is +3 for this
// kick-off. Reading it as local time would move every fixture by the viewer's
// offset, which is the kind of bug that looks plausible on screen.
eq(M.sdbKickoffMs(EVENT), Date.parse("2026-09-01T18:00:00Z"), "timestamp is UTC, not local")
eq(M.sdbKickoffMs({ strTimestamp: "2026-09-01T18:00:00Z" }), Date.parse("2026-09-01T18:00:00Z"), "an explicit Z is not doubled")
eq(M.sdbKickoffMs({ dateEvent: "2026-09-01", strTime: "18:00:00" }), Date.parse("2026-09-01T18:00:00Z"), "falls back to date + time")
eq(M.sdbKickoffMs({}), NaN, "no date at all")

console.log("status")
eq(M.sdbStatus(EVENT), "NS", "not started")
eq(M.sdbStatus({ strStatus: "Match Finished" }), "FT", "long form finished")
eq(M.sdbStatus({ strStatus: "Half Time" }), "HT", "long form half time")
eq(M.sdbStatus({ strStatus: "" }), "NS", "blank")
eq(M.sdbStatus({ strStatus: "-" }), "NS", "placeholder")
eq(M.sdbStatus({ strPostponed: "yes", strStatus: "NS" }), "PST", "postponed wins")
eq(M.matchState(fx()), "scheduled", "state via the shared vocabulary")
eq(M.matchState(fx({ strStatus: "2H" })), "live", "second half is live")
eq(M.matchState(fx({ strStatus: "FT" })), "finished", "full time")

console.log("adapting")
{
  const f = fx()
  eq(f.teams.home.name, "Al-Hilal", "home team")
  eq(f.teams.home.id, 136013, "ids are numbers, so they compare with the setting")
  eq(f.goals.home, null, "no score yet")
  eq(f.league.round, "Round 3", "round labelled")
  eq(f.fixture.venue.name, "Kingdom Arena", "venue")
  eq(M.opponentBadge(f, 136013), EVENT.strAwayTeamBadge, "at home -> the away badge is the opponent")
  eq(M.opponentBadge(f, 137721), EVENT.strHomeTeamBadge, "away -> the home badge is the opponent")
  eq(M.opponentBadge(null, 136013), "", "no fixture, no badge")
}
eq(M.sdbFixtures({ events: null }), [], "events: null is how TheSportsDB says 'nothing scheduled'")
eq(M.sdbFixtures(null), [], "no payload")
eq(M.sdbFixtures({ events: [EVENT] }).response.length, 1, "wrapped in the internal envelope")

console.log("team names")
eq(M.shortCode("Arsenal"), "ARS", "single word")
eq(M.shortCode("Real Madrid"), "MAD", "longest word wins")
eq(M.shortCode("FC Barcelona"), "BAR", "noise token dropped")
eq(M.shortCode(""), "", "empty")
eq(M.sides(fx(), 136013).them.name, "Al-Ahli", "opponent when at home")
eq(M.sides(fx(), 136013).atHome, true, "at home")
eq(M.sides(fx(), 137721).them.name, "Al-Hilal", "opponent when away")
eq(M.sides(fx(), 999).them.name, "Al-Ahli", "an unknown id still renders a match")

console.log("countdown")
eq(M.countdown(12 * 60000), "12m", "minutes")
eq(M.countdown(4 * HOUR), "4h", "hours")
eq(M.countdown(3 * DAY + 4 * HOUR), "3d 4h", "days and hours")
eq(M.countdown(2 * DAY), "2d", "whole days drop the hours")
eq(M.countdown(-5), "now", "past")

console.log("pill (adaptive)")
const when = { weekday: "Tue", time: "21:00" }
eq(M.pillLabel(fx({ strTimestamp: "2026-09-05T18:00:00" }), NOW, { teamId: 136013, when }),
   "AHL  Tue 21:00", "far away -> code + date")
eq(M.pillLabel(fx(), NOW, { teamId: 136013, when }), "vs Al-Ahli  in 6h", "match day -> countdown, home")
eq(M.pillLabel(fx({ strTimestamp: "2026-09-01T12:12:00" }), NOW, { teamId: 136013, when }),
   "vs Al-Ahli  in 12m", "imminent")
eq(M.pillLabel(fx(), NOW, { teamId: 137721, when }), "at Al-Hilal  in 6h", "away fixture says 'at'")
eq(M.pillLabel(fx({ strStatus: "2H", strProgress: "67", intHomeScore: "2", intAwayScore: "1",
                    strTimestamp: "2026-09-01T11:00:00" }), NOW, { teamId: 136013, when }),
   "HIL 2 - 1 AHL  67'", "live score")
eq(M.pillLabel(fx({ strStatus: "HT", intHomeScore: "1", intAwayScore: "0",
                    strTimestamp: "2026-09-01T11:00:00" }), NOW, { teamId: 136013, when }),
   "HIL 1 - 0 AHL  HT", "half time")
eq(M.pillLabel(null, NOW, { teamId: 136013, when }), "No match", "no fixture")

console.log("selection")
{
  const soon = fx({ strTimestamp: "2026-09-03T18:00:00" })
  const far  = fx({ strTimestamp: "2026-09-11T18:00:00" })
  const done = fx({ strTimestamp: "2026-08-20T18:00:00", strStatus: "FT" })
  const live = fx({ strTimestamp: "2026-09-01T11:00:00", strStatus: "2H" })
  eq(M.kickoffMs(M.pickNextFixture({ response: [far, soon, done] }, NOW)), M.kickoffMs(soon), "earliest upcoming wins")
  eq(M.kickoffMs(M.pickNextFixture({ response: [far, live] }, NOW)), M.kickoffMs(live), "a running match beats a future one")
  eq(M.pickNextFixture({ response: [done] }, NOW), null, "only finished -> nothing")
  eq(M.pickNextFixture({ response: [] }, NOW), null, "empty")
}

console.log("refresh pacing")
eq(M.refreshMinutes(fx({ strTimestamp: "2026-09-11T18:00:00" }), NOW, 60, true), 360, "far away -> 6h")
eq(M.refreshMinutes(fx(), NOW, 60, true), 60, "same day -> 1h")
eq(M.refreshMinutes(fx({ strTimestamp: "2026-09-01T12:30:00" }), NOW, 60, true), 15, "within the hour -> 15m")
eq(M.refreshMinutes(fx({ strStatus: "2H", strTimestamp: "2026-09-01T11:00:00" }), NOW, 60, true), 5, "live -> 5m")
eq(M.refreshMinutes(fx({ strStatus: "2H", strTimestamp: "2026-09-01T11:00:00" }), NOW, 60, false), 60, "live scores off -> base")
eq(M.refreshMinutes(null, NOW, 60, true), 60, "no fixture -> base")

console.log("search")
eq(M.searchValid("li"), false, "under 3 characters")
eq(M.searchValid("liv"), true, "3 is enough")
// "Al-Hilal" returns nothing from TheSportsDB while "Al Hilal" does, because
// the search matches the alternate-names field rather than the club name.
eq(M.sdbSearchVariants("Al-Hilal"), ["Al-Hilal", "Al Hilal"], "punctuation variant is tried too")
eq(M.sdbSearchVariants("Arsenal"), ["Arsenal"], "no pointless duplicate")
eq(M.sdbSearchVariants("  "), [], "blank")
eq(M.sdbNextUrl("", 136013), "https://www.thesportsdb.com/api/v1/json/3/eventsnext.php?id=136013", "shared free key by default")
eq(M.sdbNextUrl("mykey", 136013), "https://www.thesportsdb.com/api/v1/json/mykey/eventsnext.php?id=136013", "own key honoured")
eq(M.sdbLeagueTeamsUrl("", "Saudi-Arabian Pro League"),
   "https://www.thesportsdb.com/api/v1/json/3/search_all_teams.php?l=Saudi-Arabian%20Pro%20League", "league browse url")
eq(M.sdbTeams({ teams: [{ idTeam: "136013", strTeam: "Al-Hilal", strCountry: "Saudi Arabia",
                          strLeague: "Pro League", strBadge: "https://x/b.png" }] }),
   [{ id: 136013, name: "Al-Hilal", country: "Saudi Arabia", code: "Pro League", badge: "https://x/b.png" }],
   "search rows carry a badge")
eq(M.sdbTeams({ teams: null }), [], "no teams")

console.log("sanitize")
eq(M.plainText("<b>x</b>"), "bx/b", "markup stripped")
eq(M.validTeamId("136013"), 136013, "numeric string")
eq(M.validTeamId("nope"), 0, "garbage")
eq(M.validTeamId(-3), 0, "negative")

console.log(`\n${pass} passed, ${fail} failed`)
process.exit(fail === 0 ? 0 : 1)
