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

Then set two values. **Omarchy 4 has no settings form for third-party bar
widgets yet** — the `schema` in `manifest.json` describes the fields for
whenever one arrives, but nothing renders it today, so settings are set from
the command line with `omarchy bar set`. That writes through the running shell,
so the change applies immediately and a symlinked `shell.json` stays a symlink.

**Team id** — see [Finding your team id](#finding-your-team-id) below:

```bash
omarchy bar set tsubaie.next-match teamId 40 --json
```

**API key** — do not pass the key as an argument. It would be saved in your
shell history and be briefly visible in `ps` to anyone else on the machine.
Read it without echoing, put it in a file only you can read, and point the
widget at the file:

```bash
read -rsp 'api-football key: ' k && echo
install -m 600 /dev/null ~/.config/omarchy/next-match.key
printf %s "$k" > ~/.config/omarchy/next-match.key && unset k
omarchy bar set tsubaie.next-match apiKey 'file:~/.config/omarchy/next-match.key'
```

If you would rather keep it inline in `shell.json` and do not mind it in your
history, `omarchy bar set tsubaie.next-match apiKey 'your-key'` works too.

### Finding your team id

```bash
~/.config/omarchy/plugins/tsubaie.next-match/scripts/find-team liverpool
```

(If you have not set the key yet, it prompts for one without echoing it.)

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

## Free plan: the `next` parameter

api-football's free plan **rejects the `next` parameter**, which is the obvious
way to ask for one upcoming fixture. The widget does not require you to know or
care: it asks the best way first, and when the API refuses the query — as
opposed to refusing your key — it drops to the next shape and remembers what
worked.

| Mode | Query | Notes |
|------|-------|-------|
| `next` | `?team=X&next=1` | One request, exact answer. Paid plans. |
| `range` | `?team=X&season=…&from=…&to=…` | This season within a 120-day window, filtered locally. |
| `season` | `?team=X&season=…` | Whole season, filtered locally. Biggest payload, widest support. |

The working mode is saved as `queryMode`, so the fallback costs a couple of
extra requests once, not on every poll. To see exactly what your account
allows:

```bash
~/.config/omarchy/plugins/tsubaie.next-match/scripts/plan-probe
```

It prints your plan, your request count, which of the queries above succeed,
and which seasons your key can see.

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

All of these are set with `omarchy bar set tsubaie.next-match <key> <value>`
(add `--json` for numbers and booleans, so they are written as JSON types
rather than strings).

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
