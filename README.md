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

The trailing part adapts to how close the match is, because "Saturday" is the
useful answer three days out and "in 12m" is the useful answer on the day:

| When | Trailing |
|------|----------|
| More than a day away | `Sat 18:30` |
| Match day | `in 4h` |
| Nearly kick-off | `in 12m` |
| While it is on | the scoreline replaces the `v`, with `67'` |

Click it for the fixture in full — competition and round, both crests and
names, kick-off in your local time, venue, home or away — and under it the
next three fixtures after that one. Middle click forces a refresh.

Early in a season only a round or two is published, so the list fills in as
fixtures are announced rather than always holding three.

## Install

```bash
omarchy plugin add https://github.com/tsubaie/omarchy-next-match.git --enable
```

Click the pill, search your club by name, click it. That is the whole setup.

Omarchy 4 renders no settings form for a third-party bar widget, so the plugin
carries its own; it opens by itself until a team is picked, and from a "Change
team" button afterwards.

### If the search cannot find your club

TheSportsDB matches against an alternate-names field, so punctuation throws it:
`Al-Hilal` returns nothing where `Al Hilal SFC` finds it. The widget already
retries with punctuation loosened, and then treats what you typed as a **league
name** and lists that league's clubs — so typing `Saudi-Arabian Pro League`
gets you there when the club name will not.

## Polling

TheSportsDB asks for courtesy rather than enforcing a hard daily cap, and a
fixture days away does not change minute to minute, so the widget paces itself
by how soon the answer could actually change:

| Situation | Interval |
|-----------|----------|
| Next match more than a day away | 6 hours |
| Same day | 1 hour |
| Within an hour of kick-off | 15 minutes |
| Match in progress (if live scores are on) | 5 minutes |

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

There is no key field. If you want your own TheSportsDB key rather than the
shared one, `omarchy bar set tsubaie.next-match apiKey <key>` is honoured.

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
