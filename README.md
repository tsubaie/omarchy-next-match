# Next Match for Omarchy

**Your team's next fixture in the bar, with both crests, counting down to
kick-off.**

A bar widget for the [Omarchy](https://omarchy.org) shell. Pick your club and
it just runs — **no API key, no account, nothing to paste.** Data comes from
[TheSportsDB](https://www.thesportsdb.com), which is free and covers leagues
the big providers put behind paid plans, the Saudi Pro League among them.

## What it shows

In the bar, both clubs with their crests and how long you have to wait:

```
  [crest] Al-Hilal v Al-Ahli [crest]   in 2h
```

The trailing part is a countdown in the largest unit that still says something
useful:

| Until kick-off | Trailing |
|----------------|----------|
| Months away | `in 3 months` |
| Weeks | `in 3 weeks` |
| Days | `in 5 days` |
| Inside a day | `in 2:53` — a clock, because "2h" throws away fifty minutes |
| Under an hour | `in 45 min` |
| Being played | the score replaces the `v`, with the minute: `Al-Hilal 2 - 1 Al-Ahli 67'` |

Click it for the fixture in full — competition and round, both crests and
names, kick-off in your local time, venue, home or away — and under it the
next three fixtures after that one. Middle click forces a refresh.

### Which competitions

All of them. Fixtures are looked up **by team, not by league**, so a cup tie, a
continental night or a domestic league game are all just "the next match" —
whichever comes first is what the bar shows. Home and away alike.

### While the match is on

`eventsnext` lists only fixtures that have **not** started, so a match drops out
of it the moment it kicks off. Live scores come from a separate feed covering
every soccer match being played, which the widget starts polling ten minutes
before kick-off and stops once the match has left it. Nothing to configure;
turn it off with `showLive` if you would rather not know before you watch it
back.

**The next three only appear with a personal key.** TheSportsDB's shared test
key returns exactly one upcoming fixture per team, so on the default setup that
list is empty and says so. A personal key returns ten, which fills it. The
fixture itself, the crests, the countdown and live scores all work on the shared
key.

## Install

```bash
omarchy plugin add https://github.com/tsubaie/omarchy-next-match.git --enable
```

Click the pill and walk **country → league → club**, with a filter box at each
step. That is the whole setup.

The country list is a built-in one merged with whatever the API returns:
TheSportsDB's own `all_countries.php` stops at the first 50 by ISO code — it
ends at Costa Rica, so Saudi Arabia is never in it. Any country not listed is
still reachable: type it and the filter offers to look it up directly.

Browsing rather than typing is deliberate: TheSportsDB's club search matches an
alternate-names field, so `Al-Hilal` returns nothing where `Al Hilal SFC` finds
it. Picking from a list cannot miss, and it is also how you find a club whose
exact name you do not know.

Omarchy 4 renders no settings form for a third-party bar widget, so the plugin
carries its own; it opens by itself until a team is picked, and from a "Change
team" button afterwards.

### If it says it is rate limited

The shared key sits behind Cloudflare, which starts refusing with a bare
`error code: 1015` under load. The widget names that rather than calling it a
connection problem, keeps the fixture it already has, and tries again on the
next tick. Your own key avoids it: `omarchy bar set tsubaie.next-match apiKey <key>`.

## Polling

TheSportsDB asks for courtesy rather than enforcing a hard daily cap, and a
fixture days away does not change minute to minute, so the widget paces itself
by how soon the answer could actually change:

| Situation | Interval |
|-----------|----------|
| Next match more than a day away | 6 hours |
| Same day | 1 hour |
| Within an hour of kick-off | 15 minutes |
| From 10 minutes before kick-off until the match ends | 3 minutes, against the live feed |

A worst-case match day — a full day of polling, an hour of tightening, and a
whole match streamed live — is about **50 requests**.

The last response is cached to `~/.cache/omarchy-next-match/fixture.json`, so
restarting the shell shows the fixture immediately instead of spending a
request, and a refresh that arrives within a minute of the last one is ignored
to survive reload storms.

## Settings

All optional, and all settable from the command line too — which writes through
the running shell, so a symlinked `shell.json` stays a symlink:

```bash
omarchy bar set tsubaie.next-match showBadge false --json
```

| Key | Default | Meaning |
|-----|---------|---------|
| `teamId` | `0` | TheSportsDB team id. Set by the search, not by hand. |
| `showBadge` | `true` | Crests in the bar. Off falls back to the icon. |
| `showLive` | `true` | Turn the pill into a live scoreline during the match |
| `refreshMinutes` | `60` | Floor for the poll interval when nothing is close |
| `icon` | `⚽` | Shown when there is no fixture to draw |
| `hideWhenIdle` | `false` | Take no space at all when nothing is scheduled |

There is no key field, because the widget works without one. If you want your
own TheSportsDB key — it lifts the shared key's one-fixture limit to ten, which
is what fills the "Then" list, and avoids its rate limiting — set it with
`omarchy bar set tsubaie.next-match apiKey <key>`.

## Development

```bash
node test/model.test.js          # pure logic, no network, no QML
omarchy plugin validate .        # manifest against the shell's own schema
```

`Model.js` holds every decision worth testing — label shape, match state,
countdowns, poll pacing, key parsing — and takes "now" as a parameter, so the
tests are deterministic. `Panel.qml` owns fetching and state; `BarWidget.qml`
owns only the button.

## Licence

MIT
