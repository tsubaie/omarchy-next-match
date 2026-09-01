# Next Match for Omarchy

**Your team's next fixture in the bar, counting down to kick-off.**

A bar widget for the [Omarchy](https://omarchy.org) shell. Paste an
[api-football](https://dashboard.api-football.com) key and your team's id, and
the pill tells you who you play next and how long you have to wait.

## What it shows

The label adapts to how close the match is, because "Saturday" is the useful
answer three days out and "in 12m" is the useful answer on the day:

| When | Pill |
|------|------|
| More than a day away | `⚽ ARS  Sat 18:30` |
| Match day | `⚽ vs Arsenal  in 4h` |
| Nearly kick-off | `⚽ vs Arsenal  in 12m` |
| While it is on | `⚽ LIV 2 - 1 ARS  67'` |

`vs` means home, `at` means away. Left click opens a panel with the
competition, the full kick-off time, the venue and the countdown. Middle click
forces a refresh.

## Install

```bash
omarchy plugin add https://github.com/tsubaie/omarchy-next-match.git --enable
```

Then set two things in the widget's settings — Omarchy generates the form from
the plugin manifest, so they are in the bar settings under **Next Match**:

- **API key** — from [dashboard.api-football.com](https://dashboard.api-football.com/profile?access)
- **Team ID** — the numeric id of your team

### Finding your team id

```bash
~/.config/omarchy/plugins/tsubaie.next-match/scripts/find-team liverpool
```

```
ID        TEAM                              CODE  COUNTRY
40        Liverpool                         LIV   England
```

It reuses the key you already configured, so you only paste it once.

## Keeping the key out of your dotfiles

Widget settings live in `~/.config/omarchy/shell.json`. If you sync that file
to a **public** repository, a pasted key goes with it. Two alternatives are
accepted in the same field:

```
file:~/.config/omarchy/next-match.key    read the key from a file
env:API_FOOTBALL_KEY                     read it from the environment
```

```bash
install -m 600 /dev/null ~/.config/omarchy/next-match.key
printf %s 'your-key-here' > ~/.config/omarchy/next-match.key
```

For `env:`, the variable has to be exported before the shell starts — put it in
`~/.config/uwsm/env` rather than `~/.bashrc`, which the Omarchy shell does not
read.

However the key is supplied, it is passed to `curl` through a config file on
stdin and reaches the request from the process environment. It is never an
argument to anything, so it does not show up in `ps` for other users on the
machine.

## Staying inside the free plan

The free api-football plan allows **100 requests a day**, reset at 00:00 UTC.
A fixed poll would spend that before lunch — every 5 minutes is 288 requests —
so the widget paces itself by how soon the answer could actually change:

| Situation | Interval |
|-----------|----------|
| Next match more than a day away | 6 hours |
| Same day | 1 hour |
| Within an hour of kick-off | 15 minutes |
| Match in progress (if live scores are on) | 5 minutes |

A worst-case match day — a full day of polling, an hour of tightening, and a
whole match streamed live — costs **52 requests**. There is a test that asserts
this stays under 100.

The last response is cached to `~/.cache/omarchy-next-match/fixture.json`, so
restarting the shell shows the fixture immediately instead of spending a
request, and a refresh that arrives within a minute of the last one is ignored
to survive reload storms.

## Settings

| Key | Default | Meaning |
|-----|---------|---------|
| `apiKey` | `""` | The key, or `file:` / `env:` reference |
| `teamId` | `0` | api-football's numeric team id |
| `showLive` | `true` | Turn the pill into a live scoreline during the match |
| `refreshMinutes` | `60` | Floor for the poll interval when nothing is close |
| `icon` | `⚽` | Any emoji or Nerd Font glyph |
| `hideWhenIdle` | `false` | Take no space at all when nothing is scheduled |

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
