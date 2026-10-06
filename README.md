# omarchy-plugin-nowbar

A Samsung-style **Now Bar** for the [Omarchy](https://omarchy.org/) shell.
A single pill in the bar shows what's going on right now: music, a timer, a
screen recording, the camera being used... Scroll over it to switch between
activities and click it to see the details and controls.

## What it does

- **One pill for all live activities.** It shows the most important one, with
  a thin progress line and a `2/4` position marker. The pill has a fixed size;
  longer text scrolls around (or is cut with "…", if you prefer).
- **Scroll** over the pill to go to the next or previous activity.
- **Popup carousel** with ‹ › arrows, dots and ←/→ keys. Each card has the
  details and that activity's buttons.
- **New activities take the pill** when they matter more than the current one
  (camera on, recording started...). Switching by hand pauses this for a few
  seconds.
- **Quick start:** timers (1, 5, 10 and 25 minutes by default, configurable),
  stopwatch, Pomodoro and a 30 minute sleep timer, one click away in the popup.
- **Now Brief** when nothing is going on: weather, the next reminder and
  whether an Omarchy update is available.
- **Live updates from scripts:** your own scripts can show their progress
  in the pill (builds, downloads, deploys...). `nowbar-run` does it for any
  command. See [Scripts](#scripts).

### Activities

| Samsung Now Bar         | Here                                                        | Source                                       |
| ----------------------- | ----------------------------------------------------------- | -------------------------------------------- |
| Media player            | One card per player: cover, title · artist, seekable progress bar, volume, play/pause, previous, next; highlight color taken from the cover | MPRIS |
| Timer / Stopwatch       | Built in: pause, +1 min, laps; a timer can also run until a time (`14:30`); survives a shell restart | This plugin (notifies when the timer ends) |
| Focus modes             | Pomodoro: focus / break cycles, a long break every 4         | This plugin (notifies at each change)        |
| Media sleep timer       | Pauses every player when it ends                            | This plugin                                  |
| Alarms / reminders      | Countdown to the next `omarchy-reminder`, clear             | `omarchy-reminder show --json`               |
| Voice / screen recorder | Screen recording with elapsed time, stop                    | `gpu-screen-recorder`                        |
| Interpreter / voice     | Dictation: listening / transcribing                         | `omarchy-voxtype-status`                     |
| Privacy indicator       | Camera and/or microphone in use, which apps, mute the mic   | PipeWire + who has `/dev/video*` open        |
| Modes & Routines / DND  | Do Not Disturb, stay awake, night light, VPN (while on), turn off | The shell's own IPC, `nmcli`, `tailscale` |
| Charging / battery      | `Charging · 63%` with time until full; low battery (≤ 15%) in red with time left | UPower                      |
| Connected devices       | A Bluetooth device that just connected, with its battery, for 10 s | Quickshell Bluetooth                  |
| Screenshot toolbar      | A screenshot just saved, with thumbnail, Edit / Copy / Open, for 15 s | The screenshots folder (inotify)   |
| Now Brief               | Weather, next reminder, Omarchy update, when nothing else is going on | wttr.in, `omarchy-update-available` |
| Live Updates (Android)  | Anything a script sends with `nowbar push`, or a command run with `nowbar-run` | IPC                         |

Not ported, since the desktop has no source for them: navigation, ride and
food delivery, sports scores, wallet tickets, workouts. Scripts can still
show those through `push`.

## Preview

![Now Bar popup](preview.png)

## Usage

| Action        | Effect                                                          |
| ------------- | --------------------------------------------------------------- |
| Left click    | Open/close the popup                                            |
| Scroll        | Next / previous activity                                        |
| Middle click  | Main action of the activity (pause timer, play/pause, stop...)  |
| Right click   | Hide the activity until it changes (a new track, timer paused...) |

### Popup keys

| Key              | Effect                                   |
| ---------------- | ---------------------------------------- |
| ← / → (h / l)    | Previous / next activity                 |
| Tab / Shift+Tab  | Next / previous activity                 |
| Enter / Space    | Main action                              |
| x                | Hide the activity until it changes       |
| 1 – 6            | Start the quick start timer with that number |
| s                | Start the stopwatch                      |
| p                | Start a Pomodoro                         |
| c                | Options                                  |
| q / Esc          | Close                                    |

> **Note:** while the popup is open it has the keyboard focus, like every
> Omarchy panel. Keys you type go to the popup, so Space or Enter can pause
> the timer.

## IPC

Everything goes through `omarchy-shell nowbar <method> [args]`:

| Method                    | What it does                                                    |
| ------------------------- | --------------------------------------------------------------- |
| `next` / `prev`           | Switch the pill to the next / previous activity                 |
| `toggle`                  | Open/close the popup (on the focused monitor)                   |
| `focus <id or module>`    | Focus an activity: `timer`, `media`, `privacy`, `build`...      |
| `primary`                 | Main action of the focused activity                             |
| `act <activity> <action>` | Any action, e.g. `act timer cancel`, `act media next` (`media` is the focused player) |
| `dismiss`                 | Hide the focused activity until it changes                      |
| `timer <duration>`        | Start a timer: `90` (seconds), `25m`, `1h30m`, or until `14:30` |
| `stopwatch`               | Start the stopwatch                                             |
| `pomodoro`                | Start a Pomodoro                                                |
| `sleep <duration>`        | Pause the media after `30` (minutes), `1h`, or at `23:00`       |
| `push <id> <json>`        | Add or update an activity from a script                         |
| `remove <id>`             | Remove a pushed activity                                        |
| `status`                  | JSON with the activities, the focused one, the cover color and the brief |

Keyboard shortcuts go in `~/.config/hypr/bindings.lua`. These keys are free
in the default Omarchy bindings:

```lua
o.bind("SUPER + period", "Now Bar: next activity", "omarchy-shell nowbar next")
o.bind("SUPER + SHIFT + period", "Now Bar: previous activity", "omarchy-shell nowbar prev")
o.bind("SUPER + ALT + period", "Now Bar: details", "omarchy-shell nowbar toggle")
o.bind("SUPER + CTRL + ALT + period", "Now Bar: main action", "omarchy-shell nowbar primary")
```

`primary` runs the focused activity's main action (play/pause, pause the
timer, stop the recording...) without opening the popup.

## Scripts

### `nowbar-run`: show any command in the pill

`bin/nowbar-run` runs a command in the foreground, exactly as given, and shows
it in the pill with the elapsed time. When it ends the card turns into
"Done in 1:23" or "Failed (exit 2) after 1:23" for a while, and a notification
is sent.

```bash
~/.config/omarchy/plugins/vinicgobbi.nowbar/bin/nowbar-run make
~/.config/omarchy/plugins/vinicgobbi.nowbar/bin/nowbar-run -t "System update" -- omarchy-update
~/.config/omarchy/plugins/vinicgobbi.nowbar/bin/nowbar-run -q -- ./deploy.sh   # -q: no notification
```

To type just `nowbar-run`, add an alias to your shell's config:

```bash
alias nowbar-run="$HOME/.config/omarchy/plugins/vinicgobbi.nowbar/bin/nowbar-run"
```

Its exit code is the command's, and Ctrl+C goes to the command. It needs
`jq` (part of Omarchy).

### Live updates from scripts

```bash
omarchy-shell nowbar push build '{"title":"Build #42","subtitle":"Compiling","progress":0.4,"pill":"Build 40%"}'
omarchy-shell nowbar push build '{"title":"Build #42","subtitle":"Done","progress":1,"ttl":30}'
omarchy-shell nowbar remove build
```

| Field      | Meaning                                                                   |
| ---------- | ------------------------------------------------------------------------- |
| `title`    | Required. Up to 80 characters                                             |
| `subtitle` | Second line in the popup                                                  |
| `pill`     | Shorter text for the pill (defaults to `title`)                           |
| `icon`     | A single Nerd Font glyph                                                  |
| `progress` | 0 to 1; leave it out for none                                             |
| `ttl`      | Seconds until it goes away on its own (max 24 h); leave it out to keep it |
| `priority` | `high`, `normal` (default) or `low`                                       |
| `urgent`   | `true` paints it red, like recording                                      |
| `state`    | `running`, `success` or `error` (red): sets the default icon              |
| `elapsed`  | `true` adds the time since the first push with this id                    |

The id is 1–32 letters, digits, `.`, `_` or `-`. Pushed activities are **text
only**: nothing in them is run, opened or shown as markup, and control
characters are stripped. At most 8 are kept, and they're gone after a shell
restart.

## Install

```bash
omarchy plugin add https://github.com/vinicgobbi/omarchy-plugin-nowbar --enable
```

The pill goes in the center of the bar by default. No step needs `sudo`,
polkit or the keyring.

- **Camera detection** reads which of *your own* processes have
  `/dev/video*` open (`/proc/<pid>/fd`, no root). With `inotify-tools`
  installed, it is checked only when a camera is opened or closed. Without
  it, it is checked every 5 seconds.
- **Cover art** is downloaded only over https from public hosts (or read from a
  local file), capped at 8 MB and 4096 px, checked to be a real PNG/JPEG/GIF/WebP,
  and cached in `~/.cache/omarchy/vinicgobbi.nowbar`. Same rules as
  omarchy-plugin-media.
- **Modes** (Do Not Disturb, stay awake) follow their state files, so they
  show up within a second; night light is checked every 5 seconds.
- **Timer and stopwatch state** is kept in
  `~/.local/state/vinicgobbi.nowbar/state.json`.
- **When a timer or a Pomodoro phase ends**, a notification is sent with
  `omarchy-notification-send`, so Do Not Disturb applies to it.
- **Screenshots** are noticed in the same folder `omarchy-capture-screenshot`
  saves to (`$OMARCHY_SCREENSHOT_DIR`, else `~/Pictures`), only with
  `inotify-tools` installed. "Edit" opens `$OMARCHY_SCREENSHOT_EDITOR`
  (`tensaku-edit` by default).
- **Media cards:** every player that is playing gets a card; a player you
  paused keeps its card (up to 3) so you can resume it, until it closes or
  you hide the card.
- **Now Brief** asks wttr.in for the weather every 30 minutes (your saved
  Omarchy weather location, or a guess from your IP) and runs
  `omarchy-update-available` every 3 hours. Choose "Empty" or "Hide" in the
  options to turn both off.

## Options

Use the gear in the popup (or `c`), or the widget's settings. You can:

- switch each activity type on or off;
- turn off "focus new activities";
- turn off "cover colors" (media takes its highlight color from the album
  cover: the most vivid color that covers a good part of it, adjusted to stay
  readable; black/white/gray covers keep the theme's color);
- hide the progress line or the `2/4` marker;
- choose what the pill shows when nothing is going on: the Now Brief
  (default), an empty pill, or no pill;
- set the quick start timers (minutes, comma separated) and the Pomodoro
  focus, break and long break lengths;
- set the pill's text width: the pill always keeps the same size, and text
  that doesn't fit either scrolls around (default) or is cut with "…".

## License

MIT
