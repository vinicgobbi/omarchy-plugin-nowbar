# Contributing

## Local setup

`omarchy plugin validate .` rejects a plugin folder that contains a
symlink, so a plain `ln -s` of this repo into
`~/.config/omarchy/plugins/` won't load. Clone it there instead
(a real, separate working copy — like `omarchy plugin add` would
leave):

```bash
git clone "$(pwd)" ~/.config/omarchy/plugins/vinicgobbi.nowbar
omarchy-shell shell rescanPlugins
omarchy plugin enable vinicgobbi.nowbar
```

To pick up local edits without re-cloning, add this repo as a remote
in the installed copy and pull:

```bash
git -C ~/.config/omarchy/plugins/vinicgobbi.nowbar remote add dev "$(pwd)"
git -C ~/.config/omarchy/plugins/vinicgobbi.nowbar pull dev main
```

`BarWidget.qml` and `AdvancedSettings.qml` are reloaded when the installed
copy changes, but the shell may keep using the previously compiled version
(seen with a change to the pill's text), so if a change doesn't show up,
restart the shell. `Service.qml` (and `NowbarModel.js`, which it imports)
is loaded once and kept alive by the shell, so a change to it always needs
a full shell restart:

```bash
omarchy restart shell
```

Validate the manifest before publishing:

```bash
omarchy plugin validate .
```

Try things by hand through IPC:

```bash
omarchy-shell nowbar timer 90
omarchy-shell nowbar push test '{"title":"Hello","progress":0.5,"ttl":30}'
omarchy-shell nowbar status
```

## Structure

- `manifest.json` — plugin metadata (id, kinds, entry points) and the
  widget's settings schema
- `NowbarModel.js` — all the logic that doesn't need QML: turning each
  source into an "activity", the timer and stopwatch state, parsing
  command output, validating pushed activities, sorting and deciding
  which activity has the focus, and the preferences. Runs under Node,
  see `tests/`
- `Service.qml` — reads every source (MPRIS, PipeWire, UPower,
  `omarchy-reminder`, `gpu-screen-recorder`, `omarchy-voxtype-status`,
  `/dev/video*` users, the shell's DND/idle/night light IPC, `nmcli` and
  `tailscale`, Bluetooth, the screenshots folder, wttr.in (`?format=j1`, for
  the place in Omarchy's `weather.json`), Open-Meteo's geocoding (only while
  searching for a place in the options) and `omarchy-update-available`), keeps
  the list of activities and the focus, saves the timer/stopwatch/Pomodoro/sleep timer to
  `~/.local/state/vinicgobbi.nowbar/state.json`, and owns the `nowbar`
  IPC target
- `BarWidget.qml` — the pill and the carousel popup. It follows the
  service, so every monitor shows the same activity, and hands the
  widget's settings to the service
- `WeatherCard.qml` — the weather card's layout (data from
  `NowbarModel.parseWttr`)
- `AdvancedSettings.qml` — the options view inside the popup
- `bin/nowbar-weather-widget` — `replace` / `restore` / `status`: turns
  `omarchy.weather` off (or back on, where it was) and adds (or removes) a marked block in
  `~/.config/hypr/bindings.lua` pointing SUPER+CTRL+ALT+W at
  `omarchy-shell nowbar weather`; run only from the options/weather card
  buttons or by hand
- `bin/nowbar-indicators` — `replace` / `restore` / `status`: turns
  `omarchy.indicators` off (remembering its place in the bar) or back on
  where it was. `Service.qml` answers `omarchy.indicators refresh` only
  while that widget is off (two handlers can't share an IPC target)
- `bin/nowbar-run` — runs a command and shows it in the pill through
  `omarchy-shell nowbar push` (payload built with `jq`)

The manifest declares `"omarchy": { "clonedFrom": "omarchy.media" }`:
enabling the Now Bar turns the built-in media service off (it goes to
`disabledPlugins` in `shell.json`), `Service.qml` owns the `media` IPC target
that Omarchy's media keys call, and the plugin may summon `omarchy.osd`. A
plugin can only clone one source, so the indicators' `omarchy.indicators
refresh` (called by `omarchy-reminder` and the screen recorder) stays with the
built-in indicators; the Now Bar watches the same things on its own instead.

A third-party plugin can't read the shell's own services (`serviceFor`
only returns the plugin's own), so everything is read directly. Every
command runs with a fixed argv: nothing coming from a player, a process
name or a pushed activity is ever passed to a shell or shown as markup.

## Tests

```bash
node --test tests/*.test.js
```

## CI

`.github/workflows/ci.yml` runs on every push to `main` (and on pull
requests): it validates `manifest.json`, runs the `NowbarModel.js` unit
tests, runs Shellcheck on any shell scripts, and lints every `.qml` file
with `qmllint`, so a syntax error can't land on `main`.

## Commits and releases

Commits follow [Conventional Commits](https://www.conventionalcommits.org/)
and are checked with [Commitizen](https://commitizen-tools.github.io/commitizen/):

```bash
pipx install commitizen
cz commit   # interactive, conventional-commits-compliant commit
```

Releases are automatic: `.github/workflows/release.yml` runs after CI
passes on every push to `main` (it can also be run by hand from the
Actions tab, on `main`). It uses Commitizen to bump `manifest.json`'s
version and the changelog based on the commit types since the last
release, tags it (`vX.Y.Z`), and publishes a GitHub Release with the
changelog entry. If there's nothing to bump (no `feat`/`fix`/`BREAKING
CHANGE` commits since the last release), it's a no-op — no tag, no
release.

When it does bump, the workflow pushes a `bump: version …` commit to
`main`, so run `git pull` before your next push.
