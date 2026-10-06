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
- **Quick start:** 1, 5, 10 and 25 minute timers and a stopwatch, one click
  away in the popup.
- **Live updates from scripts:** your own scripts can show their progress
  in the pill (builds, downloads, deploys...). See [IPC](#ipc).

### Activities

| Samsung Now Bar         | Here                                                        | Source                                       |
| ----------------------- | ----------------------------------------------------------- | -------------------------------------------- |
| Media player            | Cover, title · artist, progress, play/pause, previous, next; highlight color taken from the cover | MPRIS |
| Timer / Stopwatch       | Built in: pause, +1 min, laps; survives a shell restart      | This plugin (notifies when the timer ends)   |
| Alarms / reminders      | Countdown to the next `omarchy-reminder`, clear             | `omarchy-reminder show --json`               |
| Voice / screen recorder | Screen recording with elapsed time, stop                    | `gpu-screen-recorder`                        |
| Interpreter / voice     | Dictation: listening / transcribing                         | `omarchy-voxtype-status`                     |
| Privacy indicator       | Camera and/or microphone in use, which apps, mute the mic   | PipeWire + who has `/dev/video*` open        |
| Modes & Routines / DND  | Do Not Disturb, stay awake, night light (while on), turn off | The shell's own IPC                          |
| Charging                | `Charging · 63%`, time until full                           | UPower                                       |
| Live Updates (Android)  | Anything a script sends with `nowbar push`                  | IPC                                          |

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
| 1 – 4            | Start a 1 / 5 / 10 / 25 minute timer     |
| s                | Start the stopwatch                      |
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
| `act <activity> <action>` | Any action, e.g. `act timer cancel`, `act media next`           |
| `dismiss`                 | Hide the focused activity until it changes                      |
| `timer <seconds>`         | Start a timer (up to 24 h)                                      |
| `stopwatch`               | Start the stopwatch                                             |
| `push <id> <json>`        | Add or update an activity from a script                         |
| `remove <id>`             | Remove a pushed activity                                        |
| `status`                  | JSON with the activities and the focused one                    |

Keyboard shortcuts go in `~/.config/hypr/bindings.lua`. These keys are free
in the default Omarchy bindings:

```lua
o.bind("SUPER + period", "Now Bar: next activity", "omarchy-shell nowbar next")
o.bind("SUPER + SHIFT + period", "Now Bar: previous activity", "omarchy-shell nowbar prev")
o.bind("SUPER + ALT + period", "Now Bar: details", "omarchy-shell nowbar toggle")
```

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
- **When the timer ends**, a notification is sent with
  `omarchy-notification-send`, so Do Not Disturb applies to it.

## Options

Use the gear in the popup (or `c`), or the widget's settings. You can:

- switch each activity type on or off;
- turn off "focus new activities";
- turn off "cover colors" (media takes its highlight color from the album
  cover: the most vivid color that covers a good part of it, adjusted to stay
  readable; black/white/gray covers keep the theme's color);
- hide the progress line or the `2/4` marker;
- hide the pill when nothing is going on (by default a small icon stays so
  the popup can still be opened);
- set the pill's text width: the pill always keeps the same size, and text
  that doesn't fit either scrolls around (default) or is cut with "…".

## License

MIT
