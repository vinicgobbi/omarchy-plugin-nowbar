import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Bluetooth
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import qs.Commons
import "NowbarModel.js" as Model

// Collects every live source into one list of activities (see NowbarModel.js)
// and keeps which one has the focus, so the pill on every monitor shows the
// same thing. A third-party plugin can't read the shell's own services, so
// everything is read here: Quickshell services directly, the rest through
// omarchy-* commands with fixed argv.
Item {
  id: root

  property var shell: null
  readonly property string pluginId: "vinicgobbi.nowbar"

  // Set by the bar widget from its settings (module switches, auto focus).
  property var prefs: Model.normalizePrefs({})
  readonly property var modules: prefs.modules

  // Wall clock, bumped by `ticker` only while something on screen counts.
  property double now: Date.now()

  // --- timer & stopwatch (persisted across shell restarts) -------------------

  property var timerState: Model.idleTimer()
  property var stopwatchState: Model.idleStopwatch()
  property var pomodoroState: Model.idlePomodoro()
  // Focus blocks finished today, and whether the Pomodoro turned Do Not
  // Disturb on (so it only turns off what it turned on).
  property var pomodoroStats: Model.normalizePomodoroStats(null, Date.now())
  property bool pomodoroDndOwned: false
  property var sleepState: Model.idleSleep()
  readonly property var pomodoroCfg: Model.pomodoroConfig(prefs)
  property bool stateLoaded: false

  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/vinicgobbi.nowbar"

  function saveState() {
    if (!stateLoaded) return
    stateFile.setText(JSON.stringify({ timer: timerState, stopwatch: stopwatchState, pomodoro: pomodoroState, sleep: sleepState,
      updates: updatesState, bootId: updatesBootId, pomodoroStats: pomodoroStats, pomodoroDnd: pomodoroDndOwned }) + "\n")
  }

  function restoreState(text) {
    var data = {}
    try { data = JSON.parse(String(text || "{}")) || {} } catch (e) { data = {} }
    timerState = Model.normalizeTimer(data.timer)
    stopwatchState = Model.normalizeStopwatch(data.stopwatch)
    pomodoroState = Model.normalizePomodoro(data.pomodoro)
    sleepState = Model.normalizeSleep(data.sleep)
    updatesState = Model.normalizeUpdates(data.updates)
    pomodoroStats = Model.normalizePomodoroStats(data.pomodoroStats, Date.now())
    pomodoroDndOwned = data.pomodoroDnd === true
    updatesSavedBootId = typeof data.bootId === "string" ? data.bootId : ""
    updatesBootId = updatesSavedBootId
    stateLoaded = true
    root.now = Date.now()
    checkTimer()
  }

  Process {
    id: stateDirProcess
    command: ["mkdir", "-p", "--", root.stateDir]
    onExited: stateFile.reload()
  }

  FileView {
    id: stateFile
    path: root.stateDir + "/state.json"
    printErrors: false
    atomicWrites: true
    onLoaded: if (!root.stateLoaded) root.restoreState(text())
    onLoadFailed: if (!root.stateLoaded) root.restoreState("")
  }

  function startTimer(seconds) {
    var t = Model.startTimer(seconds, Date.now())
    // An invalid duration leaves a running timer alone.
    if (t.state !== "running") return false
    timerState = t
    root.now = Date.now()
    if (timerState.state === "running") focusId = "timer"
    saveState()
    return timerState.state === "running"
  }

  function startStopwatch() {
    stopwatchState = Model.startStopwatch(Date.now())
    root.now = Date.now()
    focusId = "stopwatch"
    saveState()
  }

  function startPomodoro() {
    pomodoroState = Model.startPomodoro(pomodoroCfg, Date.now())
    root.now = Date.now()
    focusId = "pomodoro"
    saveState()
  }

  function startSleep(seconds) {
    var s = Model.startTimer(seconds, Date.now())
    if (s.state !== "running") return false
    sleepState = s
    root.now = Date.now()
    saveState()
    return true
  }

  // --- Pomodoro: Do Not Disturb during focus (an option) ---------------------------

  readonly property bool pomodoroWantsDnd: prefs.pomodoroDnd === true && pomodoroState.state !== "idle" && pomodoroState.phase === "focus"
  onPomodoroWantsDndChanged: syncPomodoroDnd()
  onStateLoadedChanged: if (stateLoaded) syncPomodoroDnd()

  function syncPomodoroDnd() {
    if (!stateLoaded) return
    if (pomodoroWantsDnd && !pomodoroDndOwned) {
      // Already on by hand: leave it, and leave it on afterwards too.
      if (modesState.dnd === true) return
      Quickshell.execDetached(["omarchy-shell", "-q", "notifications", "setDnd", "on"])
      pomodoroDndOwned = true
      saveState()
      modesFollowUp.restart()
    } else if (!pomodoroWantsDnd && pomodoroDndOwned) {
      Quickshell.execDetached(["omarchy-shell", "-q", "notifications", "setDnd", "off"])
      pomodoroDndOwned = false
      saveState()
      modesFollowUp.restart()
    }
  }

  // Fixed headline first in every notification: the helper treats leading
  // "--x" words as options.
  function notify(glyph, headline, body) {
    Quickshell.execDetached(["omarchy-notification-send", "-g", glyph, "-u", "critical", headline, body])
  }

  // Runs on every tick (and after a restore): ends whatever ran out.
  function checkTimer() {
    var t = root.now
    var changed = false
    if (Model.timerFinished(timerState, t)) {
      notify("\u{f13ab}", "Timer finished", Model.presetLabel(timerState.durationMs / 1000) + " timer is up")
      // "Time's up" for a moment, with Repeat / +1 min / OK, in the pill.
      timerState = Model.doneTimer(timerState, t)
      focusId = "timer"
      changed = true
    }
    if (Model.doneExpired(timerState, t)) {
      timerState = Model.idleTimer()
      changed = true
    }
    if (Model.timerFinished(pomodoroState, t)) {
      var was = pomodoroState.phase
      if (was === "focus") pomodoroStats = Model.countFocusDone(pomodoroStats, t)
      pomodoroState = Model.nextPomodoro(pomodoroState, pomodoroCfg, t)
      notify("\u{f04fe}", was === "focus" ? "Focus done" : "Break over",
        was === "focus" ? "Take a " + (pomodoroState.phase === "longBreak" ? "long " : "") + "break: " + Model.presetLabel(pomodoroState.durationMs / 1000)
          : "Back to focus: " + Model.presetLabel(pomodoroState.durationMs / 1000))
      changed = true
    }
    if (Model.timerFinished(sleepState, t)) {
      sleepState = Model.idleSleep()
      pauseAllMedia()
      changed = true
    }
    if (changed) saveState()
  }

  // --- media (MPRIS) ----------------------------------------------------------

  readonly property var players: Mpris.players ? Mpris.players.values : []
  // Players seen playing this session, as { key: last time seen playing }. A
  // paused player only shows up if it is here, so stray paused browser tabs
  // don't fill the bar, but pausing from a card keeps the card to resume.
  property var playedKeys: ({})
  readonly property int maxPausedCards: 3
  // Any app can register an MPRIS player (sandboxed ones too); a pile of fake
  // "playing" players mustn't turn into a pile of cards.
  readonly property int maxPlayingCards: 6

  function playerKey(p) {
    return p ? String(p.dbusName || p.desktopEntry || p.identity || "") : ""
  }

  function isProxy(p) {
    return String(p && p.dbusName || "").toLowerCase().indexOf("playerctld") !== -1
  }

  function hasTrack(p) {
    return !!(p && (p.trackTitle || p.trackArtist))
  }

  // When each player was last seen going from playing to paused, as
  // { key: time }: a paused player gives up the pill after a while.
  property var pausedAt: ({})

  function syncLastPlaying() {
    var t = Date.now()
    var next = {}
    var paused = {}
    var alive = {}
    for (var i = 0; i < players.length; i++) alive[playerKey(players[i])] = true
    // Forget players that went away.
    for (var k in playedKeys) if (alive[k]) next[k] = playedKeys[k]
    for (var j = 0; j < players.length; j++) {
      var p = players[j]
      var key = playerKey(p)
      if (p && p.isPlaying && !isProxy(p) && hasTrack(p)) next[key] = t
      else if (p && !p.isPlaying && alive[key]) paused[key] = pausedAt[key] !== undefined ? pausedAt[key] : t
    }
    playedKeys = next
    pausedAt = paused
  }

  // Players kept out of the Now Bar (the "Media" options); media keys still
  // reach them.
  function isIgnored(p) {
    return Model.isIgnoredPlayer(prefs.ignoredPlayers, [p.identity, p.desktopEntry, p.dbusName])
  }

  // Names of the players around now, for the options' list.
  readonly property var playerNames: {
    var out = []
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!p || isProxy(p)) continue
      var n = String(p.identity || p.desktopEntry || "").trim()
      if (n && out.indexOf(n) === -1) out.push(n)
    }
    return out
  }

  onPlayersChanged: syncLastPlaying()

  Instantiator {
    model: root.players
    delegate: Connections {
      required property var modelData
      target: modelData
      function onIsPlayingChanged() { root.syncLastPlaying() }
    }
  }

  // Players shown as activities: every one playing (playerctld's proxy only
  // when no real player is), plus the last one that played if now paused.
  readonly property var mediaPlayers: {
    var list = []
    var proxies = []
    var paused = []
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!hasTrack(p) || isIgnored(p)) continue
      if (p.isPlaying) (isProxy(p) ? proxies : list).push(p)
      else if (!isProxy(p) && playedKeys[playerKey(p)] !== undefined) paused.push(p)
    }
    if (list.length === 0) list = proxies.slice(0, 1)
    list = list.slice(0, maxPlayingCards)
    // Most recently played first.
    paused.sort(function(a, b) { return playedKeys[playerKey(b)] - playedKeys[playerKey(a)] })
    return list.concat(paused.slice(0, maxPausedCards))
  }

  readonly property var mediaInfos: {
    // Read `now` so the position (which MPRIS doesn't push) refreshes each tick.
    var _tick = root.now
    return mediaPlayers.map(function(p) {
      return {
        key: playerKey(p),
        title: p.trackTitle || "",
        artist: p.trackArtist || "",
        album: p.trackAlbum || "",
        player: p.identity || p.desktopEntry || "",
        playing: !!p.isPlaying,
        canToggle: !!(p.canTogglePlaying || p.canPlay || p.canPause),
        canPrevious: !!p.canGoPrevious,
        canNext: !!p.canGoNext,
        canSeek: !!p.canSeek && !!p.positionSupported,
        position: p.positionSupported ? p.position : 0,
        length: p.lengthSupported ? p.length : 0,
        volumeSupported: !!p.volumeSupported,
        volume: p.volumeSupported ? p.volume : 0,
        shuffleSupported: !!p.shuffleSupported && !!p.canControl,
        shuffle: !!p.shuffle,
        loopSupported: !!p.loopSupported && !!p.canControl,
        loop: p.loopState === MprisLoopState.Track ? "track" : (p.loopState === MprisLoopState.Playlist ? "playlist" : "none"),
        canRaise: !!p.canRaise
      }
    })
  }

  // The player whose cover is shown (and colors the accent): the focused
  // media card, else the first one.
  readonly property var mediaPlayer: {
    var list = mediaPlayers
    if (list.length === 0) return null
    for (var i = 0; i < list.length; i++)
      if (Model.mediaId(playerKey(list[i])) === focusId) return list[i]
    return list[0]
  }
  readonly property string artActivityId: mediaPlayer ? Model.mediaId(playerKey(mediaPlayer)) : ""

  function playerForKey(key) {
    for (var i = 0; i < players.length; i++) if (playerKey(players[i]) === key) return players[i]
    return null
  }

  function pauseAllMedia() {
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (p && p.isPlaying) {
        if (p.canPause) p.pause()
        else if (p.canTogglePlaying) p.togglePlaying()
      }
    }
  }

  // --- Cover art: fetched/copied, byte-capped, and dimension-validated
  // before it ever reaches a QML Image. trackArtUrl is attacker-controlled
  // (any MPRIS player, including a hostile web page via a browser's media
  // session bridge) and Image has no built-in cap on response size or
  // decoded pixel count — a small, highly-compressed file claiming an
  // enormous width/height could make the shell allocate far more memory
  // than the ~22-64px it actually renders at, or crash outright. This
  // downloads/copies to a temp file with hard size and time caps, checks
  // its real dimensions with ImageMagick (itself resource-limited) without
  // ever handing raw remote bytes to Image, and only then publishes the
  // validated local path. Redirects are not followed — safeArtUrl only
  // vets the initial host, so following one could reach an internal
  // address it already rejected.
  readonly property int artMaxBytes: 8 * 1024 * 1024
  readonly property int artMaxDimension: 4096
  property int _artGeneration: 0
  property string _artCurrentFile: ""
  property string safeArtPath: ""

  readonly property string _artCacheDir: (Quickshell.env("XDG_CACHE_HOME") || (Quickshell.env("HOME") + "/.cache")) + "/omarchy/vinicgobbi.nowbar"

  readonly property string _artFetchScript: [
    "dir=$(dirname -- \"$2\")",
    "mkdir -p -- \"$dir\" || exit 1",
    "tmp=\"$2.tmp\"",
    "rm -f -- \"$tmp\"",
    "if [ \"$3\" = \"1\" ]; then",
    "  src=${1#file://}",
    // Regular files only: /dev/zero reports size 0 and never ends (it would
    // fill the disk), a FIFO would hang the fetch. head -c caps it anyway.
    "  [ -f \"$src\" ] || exit 1",
    "  size=$(stat -L -c%s -- \"$src\" 2>/dev/null) || exit 1",
    "  [ \"$size\" -le \"$4\" ] || exit 1",
    "  head -c \"$4\" -- \"$src\" > \"$tmp\" || exit 1",
    "else",
    // The URL passed safeArtUrl (https, a public-looking host), but a name
    // can still resolve to this machine or the LAN. Resolve it once, refuse
    // local addresses, and make curl connect to that address only, so a page
    // playing audio can't send the shell's requests into the local network.
    "  hp=${1#https://}; hp=${hp%%[/?#]*}; h=${hp%%:*}; p=443",
    "  [ \"$hp\" != \"$h\" ] && p=${hp##*:}",
    "  ip=$(getent ahostsv4 \"$h\" 2>/dev/null | awk '{ print $1; exit }')",
    "  [ -n \"$ip\" ] || ip=$(getent ahostsv6 \"$h\" 2>/dev/null | awk '{ print $1; exit }')",
    "  [ -n \"$ip\" ] || exit 1",
    "  case \"$ip\" in",
    "    *:*)",
    // IPv6: global unicast (2000::/3) only, and not v4-mapped.
    "      case \"$ip\" in [23]*:*) ;; *) exit 1 ;; esac",
    "      pin=\"[$ip]\" ;;",
    "    *)",
    "      ok=$(printf '%s\\n' \"$ip\" | awk -F. 'NF == 4 { a = $1 + 0; b = $2 + 0; if (a == 0 || a == 10 || a == 127 || a >= 224 || (a == 169 && b == 254) || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) || (a == 100 && b >= 64 && b <= 127) || (a == 198 && (b == 18 || b == 19))) print \"no\"; else print \"yes\" }')",
    "      [ \"$ok\" = yes ] || exit 1",
    "      pin=$ip ;;",
    "  esac",
    "  curl -fsS --proto =https --connect-timeout 3 --max-time 8 --max-filesize \"$4\" --resolve \"$h:$p:$pin\" -- \"$1\" 2>/dev/null | head -c \"$4\" > \"$tmp\"",
    "  [ -s \"$tmp\" ] || { rm -f -- \"$tmp\"; exit 1; }",
    "fi",
    // Only real PNG/JPEG/GIF/WebP, told apart by their first bytes, and
    // ImageMagick is told which decoder to use: left to guess, it would hand
    // a PostScript/PDF/SVG dressed up as cover art to Ghostscript or an SVG
    // renderer, far more attack surface than reading four image headers.
    "sig=$(head -c 12 -- \"$tmp\" | od -An -tx1 | tr -d ' \\n')",
    "case \"$sig\" in",
    "  89504e470d0a1a0a*) fmt=png;;",
    "  ffd8ff*) fmt=jpeg;;",
    "  474946383761*|474946383961*) fmt=gif;;",
    "  52494646????????57454250) fmt=webp;;",
    "  *) rm -f -- \"$tmp\"; exit 1;;",
    "esac",
    "dims=$(timeout 5 identify -limit area 64MB -limit memory 64MB -limit map 64MB -format '%w %h' -- \"${fmt}:${tmp}[0]\" 2>/dev/null) || { rm -f -- \"$tmp\"; exit 1; }",
    "w=${dims%% *}",
    "h=${dims##* }",
    "case \"$w\" in ''|*[!0-9]*) rm -f -- \"$tmp\"; exit 1;; esac",
    "case \"$h\" in ''|*[!0-9]*) rm -f -- \"$tmp\"; exit 1;; esac",
    "if [ \"$w\" -gt \"$5\" ] || [ \"$h\" -gt \"$5\" ]; then rm -f -- \"$tmp\"; exit 1; fi",
    "mv -f -- \"$tmp\" \"$2\""
  ].join("\n")

  // At most one fetch runs at a time (reassigning `command` on an
  // already-running Process is exactly what every other Process in this
  // codebase guards against — see e.g. VpnService.qml's `if (x.running)
  // return`). A track change while a fetch is in flight replaces this
  // instead of starting a second one; only the latest request matters.
  property var _artPending: null

  function _clearArt() {
    // Bump the generation too, not just the visible state: otherwise a
    // fetch already in flight for the track that just went away would
    // still match root._artGeneration when it lands and resurrect art for
    // a track that's no longer playing.
    root._artGeneration += 1
    root._artPending = null
    root.safeArtPath = ""
    root.artAccent = ""
    root.artBase = ""
    var stale = root._artCurrentFile
    root._artCurrentFile = ""
    if (stale) artCleanupProcess.remove(stale)
  }

  function _startArtFetch(request) {
    artFetchProcess.generation = request.generation
    artFetchProcess.targetPath = request.target
    artFetchProcess.command = ["bash", "-c", root._artFetchScript, "_",
      request.safe, request.target, request.isLocal ? "1" : "0", String(root.artMaxBytes), String(root.artMaxDimension)]
    artFetchProcess.running = true
  }

  function refreshArt() {
    var safe = Model.safeArtUrl(root.artUrl)
    if (safe === "") { root._clearArt(); return }

    root._artGeneration += 1
    var isLocal = /^file:\/\/\//i.test(safe)
    var generation = root._artGeneration
    var request = {
      safe: safe,
      generation: generation,
      isLocal: isLocal,
      target: root._artCacheDir + "/cover-" + generation + "-" + Math.floor(Math.random() * 1e6) + ".img"
    }

    if (artFetchProcess.running) {
      root._artPending = request
      return
    }
    root._startArtFetch(request)
  }

  readonly property string artUrl: mediaPlayer && mediaPlayer.trackArtUrl ? mediaPlayer.trackArtUrl : ""
  onArtUrlChanged: root.refreshArt()

  function initArtCache() {
    // Sweep anything left behind by a crashed previous session before this
    // one starts writing to the same cache directory.
    artStartupCleanupProcess.command = ["sh", "-c", "rm -rf -- \"$1\"; mkdir -p -- \"$1\"", "_", root._artCacheDir]
    artStartupCleanupProcess.running = true
    root.refreshArt()
  }

  Process { id: artStartupCleanupProcess }

  Process {
    id: artCleanupProcess
    property var _queue: []
    function remove(path) {
      if (!path) return
      if (running) { _queue.push(path); return }
      command = ["rm", "-f", "--", path]
      running = true
    }
    onExited: {
      if (_queue.length === 0) return
      var next = _queue.shift()
      command = ["rm", "-f", "--", next]
      running = true
    }
  }

  // --- accent color from the cover --------------------------------------------
  // Only ever run on the file artFetchProcess already checked (real
  // PNG/JPEG/GIF/WebP, size and dimensions capped), with ImageMagick's own
  // limits on top. NowbarModel.accentFromHistogram picks the color.
  property string artAccent: ""
  // The cover's base color (most of its area), for the popup's background.
  property string artBase: ""

  function extractAccent(path, generation) {
    if (accentProcess.running) { accentProcess.pending = { path: path, generation: generation }; return }
    accentProcess.generation = generation
    // The file was checked when fetched; the decoder is still named from its
    // first bytes (as the fetch does) rather than left to ImageMagick's guess.
    accentProcess.command = ["sh", "-c",
      "sig=$(head -c 12 -- \"$1\" | od -An -tx1 | tr -d ' \\n'); "
      + "case \"$sig\" in 89504e470d0a1a0a*) f=png;; ffd8ff*) f=jpeg;; 474946383761*|474946383961*) f=gif;; 52494646????????57454250) f=webp;; *) exit 1;; esac; "
      + "exec timeout 5 magick -limit area 64MB -limit memory 64MB -limit map 64MB \"$f:$1[0]\" -resize 64x64 -colors 12 -depth 8 -format %c histogram:info:-",
      "_", path]
    accentProcess.running = true
  }

  Process {
    id: accentProcess
    property int generation: 0
    property var pending: null
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // A newer track may have replaced the cover meanwhile.
        if (accentProcess.generation !== root._artGeneration) return
        root.artAccent = Model.accentFromHistogram(text)
        // A gray cover keeps the theme: no accent means no tint either.
        root.artBase = root.artAccent !== "" ? Model.baseFromHistogram(text) : ""
      }
    }
    onExited: {
      var next = pending
      pending = null
      if (next) root.extractAccent(next.path, next.generation)
    }
  }

  Process {
    id: artFetchProcess
    property int generation: 0
    property string targetPath: ""
    onExited: function(exitCode) {
      // A newer track may have started a fresh fetch while this one was in
      // flight; only publish (or clean up in place of) a result that's
      // still the one currently requested.
      if (generation === root._artGeneration) {
        if (exitCode === 0) {
          var previous = root._artCurrentFile
          root._artCurrentFile = targetPath
          root.safeArtPath = Util.fileUrl(targetPath)
          root.extractAccent(targetPath, generation)
          if (previous && previous !== targetPath) artCleanupProcess.remove(previous)
        } else {
          root.safeArtPath = ""
          root.artAccent = ""
          root.artBase = ""
        }
      } else if (exitCode === 0) {
        artCleanupProcess.remove(targetPath)
      }

      // At most one fetch runs at a time: start whatever the latest
      // track-change queued while this one was in flight.
      var pending = root._artPending
      root._artPending = null
      if (pending) root._startArtFetch(pending)
    }
  }

  function mediaAction(key, action) {
    var p = playerForKey(key)
    if (!p) return
    preferredMediaKey = key
    if (action === "playPause") {
      if (p.canTogglePlaying) p.togglePlaying()
      else if (p.isPlaying && p.canPause) p.pause()
      else if (p.canPlay) p.play()
    } else if (action === "next" && p.canGoNext) p.next()
    else if (action === "previous" && p.canGoPrevious) p.previous()
    else if ((action === "back10" || action === "forward10") && p.canSeek && p.positionSupported) {
      var len = p.lengthSupported ? p.length : 0
      var to = p.position + (action === "back10" ? -10 : 10)
      p.position = Math.max(0, len > 0 ? Math.min(len - 1, to) : to)
    } else if (action === "shuffle" && p.shuffleSupported) p.shuffle = !p.shuffle
    else if (action === "loop" && p.loopSupported) {
      var cur = p.loopState === MprisLoopState.Track ? "track" : (p.loopState === MprisLoopState.Playlist ? "playlist" : "none")
      var nxt = Model.nextLoop(cur)
      p.loopState = nxt === "track" ? MprisLoopState.Track : (nxt === "playlist" ? MprisLoopState.Playlist : MprisLoopState.None)
    } else if (action === "raise" && p.canRaise) p.raise()
  }

  // --- the "media" IPC target ---------------------------------------------------
  // The Now Bar is a clone of omarchy.media (manifest), so the shell turns the
  // built-in media service off and Omarchy's media keys
  // (`omarchy-shell media playPause|next|previous`, `sourceSwitch` from
  // omarchy-audio-source-switch) land here. Same methods and answers as
  // omarchy.media / omarchy-plugin-media, plus the OSD on each action.

  // The player the last media key or media card was about.
  property string preferredMediaKey: ""

  function canHandle(p, action) {
    if (!p) return false
    if (action === "next") return !!p.canGoNext
    if (action === "previous") return !!p.canGoPrevious
    if (action === "play") return !!(p.canPlay || p.canTogglePlaying)
    if (action === "pause") return !!(p.canPause || p.canTogglePlaying)
    if (action === "playPause") return !!(p.canTogglePlaying || p.canPlay || p.canPause)
    return false
  }

  // Players a source switch cycles through: with a track, playing or able
  // to play; real players before playerctld's proxy.
  readonly property var cyclePlayers: {
    var real = []
    var proxies = []
    for (var i = 0; i < players.length; i++) {
      var p = players[i]
      if (!hasTrack(p) || !(p.isPlaying || p.canPlay || p.canTogglePlaying)) continue
      (isProxy(p) ? proxies : real).push(p)
    }
    real.sort(function(a, b) { return playerKey(a).localeCompare(playerKey(b)) })
    return real.concat(proxies)
  }

  // Which player a media key acts on.
  function mediaKeyPlayer(action) {
    var focusedPlayer = focused && focused.module === "media" ? playerForKey(focused.target) : null
    var preferred = playerForKey(preferredMediaKey)
    var playing = null
    for (var i = 0; i < players.length && !playing; i++)
      if (players[i].isPlaying && !isProxy(players[i])) playing = players[i]
    for (var j = 0; j < players.length && !playing; j++)
      if (players[j].isPlaying) playing = players[j]
    // Pausing goes to what is playing: a paused card in focus shouldn't
    // swallow the key while music goes on elsewhere.
    if ((action === "pause" || action === "playPause") && playing) {
      if (focusedPlayer && focusedPlayer.isPlaying) return focusedPlayer
      if (preferred && preferred.isPlaying) return preferred
      return playing
    }
    var order = [focusedPlayer, preferred, playing].concat(mediaPlayers).concat(cyclePlayers).concat(players)
    for (var k = 0; k < order.length; k++) if (order[k] && hasTrack(order[k]) && canHandle(order[k], action)) return order[k]
    for (var m = 0; m < order.length; m++) if (order[m] && canHandle(order[m], action)) return order[m]
    return null
  }

  function trackSignature(p) {
    return p ? [p.trackTitle || "", p.trackArtist || "", p.trackAlbum || ""].join("\u001f") : ""
  }

  function osdMessage(p, fallback) {
    if (!p) return fallback
    var title = Model.clean(p.trackTitle || p.identity || p.desktopEntry || "", 120)
    var artist = Model.clean(p.trackArtist || "", 80)
    return title && artist ? title + " - " + artist : (title || fallback)
  }

  function showOsd(label, icon, p) {
    if (!shell) return
    shell.summon("omarchy.osd", JSON.stringify({ icon: icon, message: osdMessage(p, label) }))
  }

  // After next/previous, wait for the new track before showing it.
  property var pendingOsd: null

  Timer {
    id: osdWait
    interval: 120
    onTriggered: {
      var w = root.pendingOsd
      if (!w) return
      var p = root.playerForKey(w.key)
      if (!p || root.trackSignature(p) !== w.before || w.tries >= 10) {
        root.pendingOsd = null
        root.showOsd(w.label, w.icon, p)
        return
      }
      w.tries += 1
      osdWait.restart()
    }
  }

  function runMediaKey(action, feedback) {
    var p = mediaKeyPlayer(action)
    if (!p || !canHandle(p, action)) return false
    var before = trackSignature(p)
    var label = "Play/pause"
    var icon = "media"
    if (action === "next") { p.next(); label = "Next"; icon = "media-next" }
    else if (action === "previous") { p.previous(); label = "Previous"; icon = "media-previous" }
    else if (action === "play") {
      if (p.canPlay) p.play(); else p.togglePlaying()
      label = "Play"; icon = "media-play"
    } else if (action === "pause") {
      if (p.canPause) p.pause(); else p.togglePlaying()
      label = "Pause"; icon = "media-pause"
    } else {
      var wasPlaying = p.isPlaying
      if (wasPlaying && p.canPause) p.pause()
      else if (!wasPlaying && p.canPlay) p.play()
      else p.togglePlaying()
      label = wasPlaying ? "Pause" : "Play"
      icon = wasPlaying ? "media-pause" : "media-play"
    }
    preferredMediaKey = playerKey(p)
    root.now = Date.now()
    if (feedback !== false) {
      if (action === "next" || action === "previous") {
        pendingOsd = { key: playerKey(p), before: before, label: label, icon: icon, tries: 0 }
        osdWait.restart()
      } else {
        showOsd(label, icon, p)
      }
    }
    return true
  }

  // Cycle which player the keys (and the pill) follow; with `transfer`, the
  // one that was playing pauses and the next one plays.
  function switchSource(delta, transfer) {
    var list = cyclePlayers
    if (list.length === 0) return false
    var current = mediaKeyPlayer("playPause")
    var index = 0
    for (var i = 0; i < list.length; i++) if (playerKey(list[i]) === playerKey(current)) { index = i; break }
    var next = list[((index + delta) % list.length + list.length) % list.length]
    preferredMediaKey = playerKey(next)
    if (transfer && current && current.isPlaying && next && playerKey(next) !== playerKey(current)) {
      if (next.canPlay) next.play(); else if (next.canTogglePlaying && !next.isPlaying) next.togglePlaying()
      if (current.canPause) current.pause(); else if (current.canTogglePlaying) current.togglePlaying()
    }
    // Follow it in the pill too, once its card is there.
    var target = Model.mediaId(playerKey(next))
    Qt.callLater(function() { root.focusOn(target) })
    showOsd("Source", "media-source", next)
    return true
  }

  function mediaStatusJson() {
    var p = mediaKeyPlayer("playPause")
    return JSON.stringify({
      hasPlayer: p !== null,
      hasMedia: !!(p && (p.trackTitle || p.trackArtist)),
      playing: p ? !!p.isPlaying : false,
      identity: p ? (p.identity || "") : "",
      desktopEntry: p ? (p.desktopEntry || "") : "",
      title: p ? (p.trackTitle || "") : "",
      artist: p ? (p.trackArtist || "") : "",
      album: p && p.trackAlbum ? p.trackAlbum : "",
      artUrl: p && p.trackArtUrl ? p.trackArtUrl : "",
      canGoNext: p ? !!p.canGoNext : false,
      canGoPrevious: p ? !!p.canGoPrevious : false,
      canTogglePlaying: p ? !!p.canTogglePlaying : false
    })
  }

  IpcHandler {
    target: "media"

    function status(): string { return root.mediaStatusJson() }
    function playPause(): string { return root.runMediaKey("playPause") ? "ok" : "unhandled" }
    function next(): string { return root.runMediaKey("next") ? "ok" : "unhandled" }
    function previous(): string { return root.runMediaKey("previous") ? "ok" : "unhandled" }
    function play(): string { return root.runMediaKey("play") ? "ok" : "unhandled" }
    function pause(): string { return root.runMediaKey("pause") ? "ok" : "unhandled" }
    function sourceNext(): string { return root.switchSource(1, false) ? "ok" : "unhandled" }
    function sourcePrevious(): string { return root.switchSource(-1, false) ? "ok" : "unhandled" }
    function sourceSwitch(): string { return root.switchSource(1, true) ? "ok" : "unhandled" }
    function sourceSwitchPrevious(): string { return root.switchSource(-1, true) ? "ok" : "unhandled" }
    function ping(): string { return "ok" }
  }

  function findActivity(activityId) {
    for (var i = 0; i < allActivities.length; i++) if (allActivities[i].id === activityId) return allActivities[i]
    return null
  }

  // Seek a media card to a fraction (0..1) of its track.
  function seek(activityId, fraction) {
    var a = findActivity(activityId)
    if (!a || a.module !== "media" || !a.seekable) return false
    var p = playerForKey(a.target)
    if (!p) return false
    p.position = Math.max(0, Math.min(1, fraction)) * a.length
    root.now = Date.now()
    return true
  }

  function setVolume(activityId, value) {
    var a = findActivity(activityId)
    if (!a || a.module !== "media" || a.volume < 0) return false
    var p = playerForKey(a.target)
    if (!p || !p.volumeSupported) return false
    p.volume = Math.max(0, Math.min(1, value))
    root.now = Date.now()
    return true
  }

  // --- reminders (omarchy-reminder) -------------------------------------------

  property var reminders: []

  function refreshReminders() {
    if (!modules.reminders || remindersProcess.running) return
    remindersProcess.running = true
  }

  Process {
    id: remindersProcess
    command: ["omarchy-reminder", "show", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var next = Model.parseReminders(text)
        var fired = Model.firedReminders(root.reminders, next, Date.now())
        root.reminders = next
        if (fired.length > 0) {
          var f = fired[fired.length - 1]
          root.firedReminder = { label: f.label, message: f.message, at: f.at }
          firedReminderTimer.restart()
        }
      }
    }
    onExited: function(exitCode) { if (exitCode !== 0) root.reminders = [] }
  }

  // A reminder that just went off: "Reminder · now" for a minute, to snooze.
  property var firedReminder: null

  Timer {
    id: firedReminderTimer
    interval: Model.REMINDER_DONE_MS
    onTriggered: root.firedReminder = null
  }

  // The next reminder, 5 minutes later: its timer stopped, a new one set for
  // what was left plus 5 (omarchy-reminder only counts from now).
  function postponeReminder() {
    var t = Date.now()
    var next = null
    for (var i = 0; i < reminders.length && !next; i++) if (reminders[i].at > t) next = reminders[i]
    if (!next || !Model.validReminderUnit(next.unit)) return
    Quickshell.execDetached(["systemctl", "--user", "stop", next.unit + ".timer"])
    Quickshell.execDetached(["omarchy-reminder", String(Model.postponeMinutes(next.at, t, 5)), next.message || next.label])
    remindersFollowUp.restart()
  }

  function snoozeReminder(minutes) {
    var f = firedReminder
    firedReminder = null
    if (!f) return
    Quickshell.execDetached(["omarchy-reminder", String(minutes), f.message || f.label])
    remindersFollowUp.restart()
  }

  // omarchy-reminder creates (and clears) transient systemd user timers; their
  // unit files show up here, so a new reminder appears at once instead of on
  // the next poll. Needs inotifywait; the poll below covers the rest.
  Process {
    id: remindersWatch
    command: ["sh", "-c",
      "command -v inotifywait >/dev/null 2>&1 || exit 3; d=\"${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/systemd/transient\"; "
      + "[ -d \"$d\" ] || exit 4; exec setpriv --pdeathsig TERM inotifywait -mq -e create,delete,moved_to --format %f -- \"$d\""]
    running: root.modules.reminders
    stdout: SplitParser {
      onRead: function(name) { if (String(name).indexOf("omarchy-reminder-") === 0) remindersDebounce.restart() }
    }
    onExited: function(exitCode) { if (exitCode !== 3 && root.modules.reminders) remindersWatchRetry.restart() }
  }

  Timer {
    id: remindersDebounce
    interval: 300
    onTriggered: root.refreshReminders()
  }

  Timer {
    id: remindersWatchRetry
    interval: 60000
    onTriggered: if (root.modules.reminders && !remindersWatch.running) remindersWatch.running = true
  }

  Timer {
    interval: 10000
    repeat: true
    running: root.modules.reminders
    triggeredOnStart: true
    onTriggered: root.refreshReminders()
  }

  // --- screen recording (gpu-screen-recorder) -----------------------------------

  // { active, startedAt }: startedAt comes from the recorder's own uptime, so
  // a recording started before the shell still shows the right time.
  property var recording: ({ active: false, startedAt: 0 })

  function refreshRecording() {
    if (!modules.recording || recordingProcess.running) return
    recordingProcess.running = true
  }

  Process {
    id: recordingProcess
    // Only this user's recorder: another account recording doesn't count.
    command: ["sh", "-c", "pid=$(pgrep -o -u \"$(id -u)\" -f '^gpu-screen-recorder') || exit 1; ps -o etimes= -p \"$pid\"; "
      + "head -c 512 /tmp/omarchy-screenrecord-filename 2>/dev/null"]
    // Prints the recorder's uptime in seconds (nothing when not recording),
    // then the file omarchy-capture-screenrecording is writing to.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").split("\n")
        var out = String(lines[0] || "").trim()
        if (out === "") {
          if (root.recording.active) {
            root.recording = { active: false, startedAt: 0 }
            // It stopped: show the video once Omarchy is done with it.
            if (root.recordingPath !== "") { recordedPoll.tries = 0; recordedPoll.restart() }
          }
          return
        }
        var file = String(lines[1] || "").trim()
        if (Model.validRecordingPath(file, root.recordingDir)) root.recordingPath = file
        // Keep the first estimate: re-reading it every poll would jitter by a second.
        if (root.recording.active) return
        var secs = parseInt(out, 10)
        root.recording = { active: true, startedAt: isNaN(secs) ? Date.now() : Date.now() - secs * 1000 }
      }
    }
  }

  Timer {
    interval: 2000
    repeat: true
    running: root.modules.recording
    triggeredOnStart: true
    onTriggered: root.refreshRecording()
  }

  // --- a recording just saved ----------------------------------------------------------
  // Same folder as omarchy-capture-screenrecording. After it stops, Omarchy
  // trims and normalizes the file (then removes its filename note): the card
  // shows up once that is done, with a thumbnail (ffmpegthumbnailer, part of
  // Omarchy) and Play / Copy / Folder, for 20 seconds.

  readonly property string recordingDir: Quickshell.env("OMARCHY_SCREENRECORD_DIR") || Quickshell.env("XDG_VIDEOS_DIR") || (Quickshell.env("HOME") + "/Videos")
  property string recordingPath: ""
  // { path, name, thumb, until } or null
  property var recorded: null
  property string recordedThumb: ""

  Timer {
    id: recordedPoll
    property int tries: 0
    interval: 1000
    onTriggered: {
      if (recordedCheck.running) return
      tries += 1
      var thumb = root._artCacheDir + "/recording-" + Date.now() + ".png"
      recordedCheck.thumb = thumb
      recordedCheck.command = ["sh", "-c",
        "[ -e /tmp/omarchy-screenrecord-filename ] && exit 2; "
        + "[ -f \"$1\" ] && [ ! -L \"$1\" ] && [ ! -e \"${1%.mp4}-processed.mp4\" ] || exit 2; "
        + "command -v ffmpegthumbnailer >/dev/null 2>&1 && ffmpegthumbnailer -i \"$1\" -o \"$2\" -s 256 -q 6 >/dev/null 2>&1; "
        // 0: with a thumbnail, 3: without one (the card shows an icon).
        + "[ -s \"$2\" ] && exit 0; exit 3",
        "_", root.recordingPath, thumb]
      recordedCheck.running = true
    }
  }

  Process {
    id: recordedCheck
    property string thumb: ""
    onExited: function(exitCode) {
      if (exitCode === 2) {
        // Still being processed: try again, for up to a minute.
        if (recordedPoll.tries < 60) recordedPoll.restart()
        else root.recordingPath = ""
        return
      }
      if ((exitCode !== 0 && exitCode !== 3) || !root.modules.recording) { root.recordingPath = ""; return }
      var path = root.recordingPath
      var shot = exitCode === 0 ? thumb : ""
      if (root.recordedThumb) artCleanupProcess.remove(root.recordedThumb)
      root.recordedThumb = shot
      root.recorded = { path: path, name: path.slice(path.lastIndexOf("/") + 1), thumb: shot, until: Date.now() + Model.RECORDED_SHOW_MS }
      root.recordingPath = ""
      root.now = Date.now()
    }
  }

  function recordedAction(action) {
    var r = recorded
    if (!r) return
    if (action === "open") Quickshell.execDetached(["xdg-open", r.path])
    else if (action === "folder") Quickshell.execDetached(["xdg-open", root.recordingDir])
    // As a file: pastes into a chat, a file manager...
    else if (action === "copy") Quickshell.execDetached(["wl-copy", "--type", "text/uri-list", Util.fileUrl(r.path)])
    recorded = null
  }

  // --- dictation (voxtype) ---------------------------------------------------------

  property string dictationState: "idle"

  Process {
    id: dictationProcess
    command: ["omarchy-voxtype-status"]
    running: root.modules.dictation
    stdout: SplitParser {
      onRead: function(line) { root.dictationState = Model.parseVoxtype(line) }
    }
    // The script exits 0 right away when voxtype isn't installed; anything
    // else is a crash of the follower, worth retrying later.
    onExited: function(exitCode) {
      root.dictationState = "idle"
      if (exitCode !== 0 && root.modules.dictation) dictationRetry.restart()
    }
  }

  Timer {
    id: dictationRetry
    interval: 15000
    onTriggered: if (root.modules.dictation && !dictationProcess.running) dictationProcess.running = true
  }

  // --- privacy: microphone (PipeWire) ------------------------------------------------

  readonly property var pwNodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var micSource: Pipewire.defaultAudioSource
  readonly property bool micMuted: micSource && micSource.audio ? micSource.audio.muted : false

  // Capture streams: an app recording audio. Monitor streams (peak meters,
  // visualizers reading what's playing) aren't the microphone.
  readonly property var captureStreams: {
    var list = []
    for (var i = 0; i < pwNodes.length; i++) {
      var n = pwNodes[i]
      if (!n || !n.isStream || n.isSink !== false || !n.audio) continue
      if (n.audio.muted) continue
      var props = n.ready && n.properties ? n.properties : {}
      if (String(props["stream.monitor"] || "") === "true") continue
      list.push(n)
    }
    return list
  }

  // Video capture through PipeWire (portal clients): the device itself is
  // then held by the PipeWire daemon, so this is where the app name is.
  readonly property var videoStreams: {
    var list = []
    for (var i = 0; i < pwNodes.length; i++) {
      var n = pwNodes[i]
      if (!n || !n.isStream || n.isSink !== false || n.audio) continue
      if ((n.type & PwNodeType.Video) === 0) continue
      list.push(n)
    }
    return list
  }

  PwObjectTracker { objects: root.captureStreams.concat(root.videoStreams).concat(root.micSource ? [root.micSource] : []) }

  function streamAppName(n) {
    var props = n && n.ready && n.properties ? n.properties : {}
    return props["application.name"] || props["application.process.binary"] || n.description || n.name || ""
  }

  readonly property var micApps: captureStreams.map(streamAppName)

  function muteMic() {
    if (micSource && micSource.audio) micSource.audio.muted = true
  }

  // --- privacy: camera (/dev/video*) ------------------------------------------------
  // Who has a video device open, read from /proc/*/fd of this user's
  // processes (no root needed). Re-checked when inotify sees the device
  // opened or closed; without inotifywait it is polled instead.

  property var cameraUsers: []

  function refreshCamera() {
    if (!modules.privacy) return
    if (cameraProcess.running) { cameraProcess.again = true; return }
    cameraProcess.running = true
  }

  Process {
    id: cameraProcess
    property bool again: false
    command: ["sh", "-c",
      "find /proc/[0-9]*/fd -maxdepth 1 -lname '/dev/video*' -printf '%h\\n' 2>/dev/null | sort -u | "
      + "while IFS= read -r d; do p=${d#/proc/}; cat \"/proc/${p%/fd}/comm\" 2>/dev/null; done; exit 0"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.cameraUsers = Model.parseVideoUsers(text)
    }
    onExited: if (again) { again = false; root.refreshCamera() }
  }

  property bool cameraPolling: false

  Process {
    id: cameraWatch
    // Exit 3: no inotifywait (poll instead). Exit 4: no camera right now
    // (look again later, one may be plugged in).
    command: ["sh", "-c",
      "command -v inotifywait >/dev/null 2>&1 || exit 3; set -- /dev/video*; [ -e \"$1\" ] || exit 4; "
      + "exec setpriv --pdeathsig TERM inotifywait -mq -e open,close --format x \"$@\""]
    running: root.modules.privacy
    stdout: SplitParser {
      onRead: cameraDebounce.restart()
    }
    onRunningChanged: if (running) root.refreshCamera()
    onExited: function(exitCode) {
      root.cameraPolling = exitCode === 3
      if (exitCode !== 3 && root.modules.privacy) cameraWatchRetry.restart()
    }
  }

  Timer {
    id: cameraDebounce
    interval: 300
    onTriggered: root.refreshCamera()
  }

  Timer {
    id: cameraWatchRetry
    interval: 30000
    onTriggered: if (root.modules.privacy && !cameraWatch.running) cameraWatch.running = true
  }

  Timer {
    interval: 5000
    repeat: true
    running: root.cameraPolling && root.modules.privacy
    onTriggered: root.refreshCamera()
  }

  readonly property var privacyInfo: {
    var videoApps = videoStreams.map(streamAppName)
    return {
      micApps: micApps,
      micMuted: micMuted,
      cameraActive: cameraUsers.length > 0 || videoStreams.length > 0,
      cameraApps: Model.cameraAppNames(cameraUsers).concat(videoApps)
    }
  }

  // --- modes: Do Not Disturb, stay awake, night light ------------------------------

  property var modesState: ({ dnd: false, stayAwake: false, nightlight: false })

  function refreshModes() {
    if (!modules.modes) return
    if (modesProcess.running) { modesProcess.again = true; return }
    modesProcess.running = true
  }

  Process {
    id: modesProcess
    property bool again: false
    // Always four lines (an empty one when a call fails), in this order, then
    // the active NetworkManager connections (see Model.parseModes).
    command: ["sh", "-c",
      "a=$(omarchy-shell notifications isDnd 2>/dev/null | head -n1); "
      + "b=$(omarchy-shell idle status 2>/dev/null | head -n1); "
      + "c=$(omarchy-shell nightlight status 2>/dev/null | head -n1); "
      + "d=$(command -v tailscale >/dev/null 2>&1 && timeout 3 tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null | head -n1); "
      + "printf '%s\\n%s\\n%s\\n%s\\n' \"$a\" \"$b\" \"$c\" \"$d\"; "
      + "command -v nmcli >/dev/null 2>&1 && timeout 3 nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | head -n 20; exit 0"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.modesState = Model.parseModes(text)
    }
    onExited: if (again) { again = false; root.refreshModes() }
  }

  Timer {
    interval: 5000
    repeat: true
    running: root.modules.modes
    triggeredOnStart: true
    onTriggered: root.refreshModes()
  }

  // Stay awake is a file in this folder and DND is saved to notifications.json,
  // so a change made anywhere (keybinding, menu, the shell's own toggles)
  // shows up right away instead of on the next poll. Night light keeps no
  // state file, so only the poll catches it.
  readonly property string omarchyStateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy"

  FileView {
    path: root.omarchyStateDir + "/indicators"
    watchChanges: root.modules.modes
    printErrors: false
    onFileChanged: modesDebounce.restart()
  }

  FileView {
    path: root.omarchyStateDir + "/notifications.json"
    watchChanges: root.modules.modes
    printErrors: false
    onFileChanged: { reload(); modesDebounce.restart() }
  }

  Timer {
    id: modesDebounce
    interval: 150
    onTriggered: root.refreshModes()
  }

  // The toggles answer through the shell's own IPC, a moment later.
  Timer {
    id: modesFollowUp
    interval: 600
    onTriggered: root.refreshModes()
  }

  function modeAction(action) {
    if (action === "dnd") Quickshell.execDetached(["omarchy-shell", "-q", "notifications", "setDnd", "off"])
    else if (action === "stayAwake") Quickshell.execDetached(["omarchy-toggle-idle", "allow-idle"])
    else if (action === "nightlight") Quickshell.execDetached(["omarchy-shell", "-q", "nightlight", "disable"])
    else if (action.indexOf("vpnDown:") === 0) {
      var vpn = (modesState.vpns || [])[parseInt(action.slice(8), 10)]
      if (vpn && vpn.kind === "nm" && vpn.raw) Quickshell.execDetached(["nmcli", "connection", "down", "id", vpn.raw])
    }
    modesFollowUp.restart()
  }

  // --- quick toggles: what Omarchy's indicators do, both ways -------------------------
  // The indicators widget turns things on as well as off; so do these (the
  // popup's Quick toggles, and IPC `quick <id>`).

  property bool hasVoxtype: false

  Process {
    id: voxtypeCheck
    command: ["sh", "-c", "command -v voxtype >/dev/null 2>&1"]
    onExited: function(exitCode) { root.hasVoxtype = exitCode === 0 }
  }

  readonly property var quickIds: ["dnd", "nightlight", "stayAwake", "record", "reminder", "dictation"]

  // Whether each toggle is on right now.
  readonly property var quickStates: ({
    dnd: modesState.dnd === true,
    nightlight: modesState.nightlight === true,
    stayAwake: modesState.stayAwake === true,
    record: recording.active === true,
    reminder: reminders.length > 0,
    dictation: dictationState !== "idle"
  })

  // Returns true when it opened something else (a menu, a panel), so the
  // popup can step aside.
  function quickToggle(id) {
    if (id === "dnd") Quickshell.execDetached(["omarchy-shell", "-q", "notifications", "toggleDnd"])
    else if (id === "nightlight") Quickshell.execDetached(["omarchy-shell", "-q", "nightlight", "toggle"])
    else if (id === "stayAwake") Quickshell.execDetached(["omarchy-toggle-idle", "toggle"])
    else if (id === "record") {
      if (recording.active) {
        Quickshell.execDetached(["omarchy-capture-screenrecording", "--stop-recording"])
        recordingFollowUp.restart()
        return false
      }
      Quickshell.execDetached(["omarchy-menu", "toggle", "trigger.capture.screenrecord"])
      return true
    } else if (id === "reminder") {
      Quickshell.execDetached(["omarchy-reminder", "-i"])
      return true
    } else if (id === "dictation") {
      Quickshell.execDetached(["omarchy-voxtype-config"])
      return true
    } else return false
    modesFollowUp.restart()
    return false
  }

  // --- replacing Omarchy's indicators widget (opt-in, from a button) -----------------
  // The Now Bar shows everything the indicators show, and the Quick toggles
  // turn them on. With the widget off, the Now Bar also answers its
  // `omarchy.indicators refresh` IPC (called by omarchy-reminder and the
  // screen recorder), so those show up at once.

  // bin/nowbar-indicators turns the widget off (remembering its place in the
  // bar) or back on where it was.
  readonly property string indicatorsScript: decodeURIComponent(String(Qt.resolvedUrl("bin/nowbar-indicators")).replace(/^file:\/\//, ""))
  // "replaced" (the widget is off), "native", or "" before the first check.
  property string indicatorsState: ""
  property string indicatorsAction: ""

  function checkIndicators() {
    if (indicatorsProcess.running) return
    indicatorsAction = "status"
    indicatorsProcess.command = [indicatorsScript, "status"]
    indicatorsProcess.running = true
  }

  function setIndicators(replace) {
    if (indicatorsProcess.running) return false
    indicatorsAction = replace ? "replace" : "restore"
    indicatorsProcess.command = [indicatorsScript, indicatorsAction]
    indicatorsProcess.running = true
    return true
  }

  Process {
    id: indicatorsProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (root.indicatorsAction !== "status") return
        if (t === "native" || t === "replaced") root.indicatorsState = t
        // `omarchy plugin list` asks the shell over IPC, which doesn't answer
        // yet while the shell is starting: try again in a moment.
        else if (root.indicatorsState === "") indicatorsRetry.restart()
      }
    }
    onExited: function(exitCode) {
      var action = root.indicatorsAction
      root.indicatorsAction = ""
      if (action === "status") return
      if (exitCode !== 0) root.notify("\u{f009b}", "Indicators", "Couldn't " + action + " them (exit " + exitCode + ")")
      else if (action === "replace") root.notify("\u{f009b}", "Indicators are in the Now Bar now", "Omarchy's indicators widget is off; Quick toggles are in the Now Bar popup")
      else root.notify("\u{f009b}", "Indicators restored", "Omarchy's indicators widget is back in the bar")
      root.checkIndicators()
    }
  }

  Timer {
    id: indicatorsRetry
    interval: 3000
    onTriggered: root.checkIndicators()
  }

  function refreshAll() {
    refreshReminders()
    refreshRecording()
    refreshModes()
    refreshCamera()
  }

  // Only while the indicators widget is off: two handlers can't share a target.
  IpcHandler {
    target: "omarchy.indicators"
    enabled: root.indicatorsState === "replaced"

    function refresh(): void { root.refreshAll() }
  }

  // --- charging (UPower) -----------------------------------------------------------

  readonly property var chargingInfo: {
    var d = UPower.displayDevice
    if (!d || !d.ready || !d.isLaptopBattery) return null
    return {
      present: d.isPresent !== false,
      charging: d.state === UPowerDeviceState.Charging,
      onBattery: UPower.onBattery,
      percentage: d.percentage,
      timeToFull: d.timeToFull,
      timeToEmpty: d.timeToEmpty
    }
  }

  // --- Bluetooth: a device that just connected, for a few seconds ---------------------

  // { address: { address, name, battery, until } }
  property var btRecent: ({})

  function bluetoothConnected(dev) {
    if (!modules.bluetooth || !dev) return
    var next = {}
    for (var k in btRecent) next[k] = btRecent[k]
    var address = String(dev.address || "")
    next[address] = {
      address: address,
      name: dev.name || dev.deviceName || "",
      battery: dev.batteryAvailable ? dev.battery : -1,
      audio: String(dev.icon || "").indexOf("audio") === 0,
      until: Date.now() + Model.BLUETOOTH_SHOW_MS
    }
    btRecent = next
    root.now = Date.now()
  }

  function pruneBluetooth(t) {
    var next = {}
    var changed = false
    for (var k in btRecent) {
      if (btRecent[k].until > t) next[k] = btRecent[k]
      else changed = true
    }
    if (changed) btRecent = next
  }

  // Plays through the device: its PipeWire sink (bluez_output.<MAC>) becomes
  // the default output (wireplumber's wpctl). The sink can take a few seconds
  // to show up after connecting.
  function useForAudio(address) {
    var mac = String(address || "")
    if (!/^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/.test(mac)) return
    Quickshell.execDetached(["sh", "-c",
      "m=$(printf %s \"$1\" | tr : _); i=0; while [ $i -lt 10 ]; do "
      + "id=$(pw-dump 2>/dev/null | jq -r --arg p \"bluez_output.$m\" "
      + "'[.[] | select(.type == \"PipeWire:Interface:Node\") | select((.info.props[\"node.name\"] // \"\") | startswith($p))][0].id // empty'); "
      + "[ -n \"$id\" ] && exec wpctl set-default \"$id\"; i=$((i + 1)); sleep 0.5; done; exit 1", "_", mac])
  }

  // Connected devices running low (mouse, keyboard, headphones), as long as
  // they are low.
  readonly property var btLowDevices: {
    var _tick = root.now
    var out = []
    var list = Bluetooth.devices ? Bluetooth.devices.values : []
    for (var i = 0; i < list.length; i++) {
      var d = list[i]
      if (!d || !d.connected || !d.batteryAvailable) continue
      var a = Model.btLowActivity({ address: d.address, name: d.name || d.deviceName, battery: d.battery })
      if (a) out.push(a)
    }
    return out
  }

  // Only changes count: devices already connected when the shell starts
  // don't pop up.
  Instantiator {
    model: Bluetooth.devices ? Bluetooth.devices.values : []
    delegate: Connections {
      required property var modelData
      target: modelData
      function onConnectedChanged() { if (modelData.connected) root.bluetoothConnected(modelData) }
    }
  }

  // --- screenshots: a file just saved in the screenshots folder ----------------------
  // Same folder as omarchy-capture-screenshot. Needs inotifywait.

  readonly property string screenshotDir: Quickshell.env("OMARCHY_SCREENSHOT_DIR") || Quickshell.env("XDG_PICTURES_DIR") || (Quickshell.env("HOME") + "/Pictures")
  readonly property string screenshotEditor: Quickshell.env("OMARCHY_SCREENSHOT_EDITOR") || "tensaku-edit"
  // { path, name, until } or null
  property var screenshot: null

  Process {
    id: screenshotWatch
    command: ["sh", "-c",
      "command -v inotifywait >/dev/null 2>&1 || exit 3; [ -d \"$1\" ] || exit 4; "
      // Regular files only: a symlink named like an image (from an archive,
      // say) would otherwise be shown and copied as if it were a screenshot.
      + "setpriv --pdeathsig TERM inotifywait -mq -e close_write,moved_to --format %f -- \"$1\" | "
      + "while IFS= read -r f; do [ -f \"$1/$f\" ] && [ ! -L \"$1/$f\" ] && printf '%s\\n' \"$f\"; done", "_", root.screenshotDir]
    running: root.modules.screenshot
    stdout: SplitParser {
      onRead: function(name) {
        if (!Model.validScreenshotName(name)) return
        root.screenshot = { path: root.screenshotDir + "/" + name, name: name, until: Date.now() + Model.SCREENSHOT_SHOW_MS }
        root.now = Date.now()
      }
    }
    // No inotifywait (3): nothing to do. No folder yet (4) or a crash: retry.
    onExited: function(exitCode) {
      if (exitCode !== 3 && root.modules.screenshot) screenshotWatchRetry.restart()
    }
  }

  Timer {
    id: screenshotWatchRetry
    interval: 60000
    onTriggered: if (root.modules.screenshot && !screenshotWatch.running) screenshotWatch.running = true
  }

  function screenshotAction(action) {
    var s = screenshot
    if (!s) return
    if (action === "edit") Quickshell.execDetached([screenshotEditor, s.path])
    else if (action === "open") Quickshell.execDetached(["xdg-open", s.path])
    else if (action === "copy") Quickshell.execDetached(["sh", "-c", "[ -f \"$1\" ] && [ ! -L \"$1\" ] && wl-copy --type \"$2\" < \"$1\"", "_", s.path,
      /\.png$/i.test(s.path) ? "image/png" : "image/jpeg"])
    screenshot = null
  }

  // --- weather (the Now Brief) and Omarchy updates --------------------------------------
  // The whole wttr.in report (?format=j1) is fetched every 20 minutes, and
  // again when the weather card is opened with an older one. It replaces
  // Omarchy's weather widget: same source, same saved location.

  property string weatherRaw: ""
  property double weatherFetchedAt: 0
  property bool updateAvailable: false
  readonly property bool weatherEnabled: modules.weather

  // Parsed again when the raw report, the unit or the hour (night/day,
  // "now" slot) changes.
  // `now` ticks every second; this only changes value every 10 minutes, so
  // the report isn't parsed again on each tick.
  readonly property int weatherSlot: Math.floor(root.now / 600000)
  readonly property var weather: {
    var _slot = weatherSlot
    return weatherRaw ? Model.parseWttr(weatherRaw, Date.now(), { unit: prefs.weatherUnit, locale: Qt.locale().name }) : null
  }

  function refreshWeather() {
    if (!weatherEnabled || weatherProcess.running) return
    weatherProcess.running = true
  }

  // Older than 10 minutes: fetch again (when the card is shown).
  function refreshWeatherIfStale() {
    if (Date.now() - weatherFetchedAt > 10 * 60 * 1000) refreshWeather()
  }

  Process {
    id: weatherProcess
    // Same location rules as Omarchy's weather: the saved place if any, else
    // wttr.in's guess from the IP. The report is capped at 512 KB.
    command: ["sh", "-c",
      "q=''; if [ -s \"$HOME/.local/state/omarchy/settings/weather.json\" ]; then "
      + "l=$(omarchy-weather-location 2>/dev/null); [ -n \"$l\" ] && q=$(jq -rn --arg l \"$l\" '$l | @uri'); fi; "
      + "curl -fsS --max-time 10 \"https://wttr.in/${q}?format=j1\" 2>/dev/null | head -c 524288"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // Keep the last good report when offline or when wttr.in answers junk.
        if (Model.parseWttr(text, Date.now(), {}) === null) return
        root.weatherRaw = text
        root.weatherFetchedAt = Date.now()
      }
    }
  }

  // --- replacing Omarchy's weather widget (opt-in, from a button) ------------------------
  // bin/nowbar-weather-widget turns omarchy.weather off and points Omarchy's
  // weather shortcut here, or undoes it. Nothing happens until the user asks.

  readonly property string weatherWidgetScript: decodeURIComponent(String(Qt.resolvedUrl("bin/nowbar-weather-widget")).replace(/^file:\/\//, ""))
  // "replaced", "native", or "" before the first check.
  property string weatherWidgetState: ""
  property string weatherWidgetAction: ""

  function checkWeatherWidget() {
    if (weatherWidgetProcess.running) return
    weatherWidgetAction = "status"
    weatherWidgetProcess.command = [weatherWidgetScript, "status"]
    weatherWidgetProcess.running = true
  }

  function setWeatherWidget(replace) {
    if (weatherWidgetProcess.running) return false
    weatherWidgetAction = replace ? "replace" : "restore"
    weatherWidgetProcess.command = [weatherWidgetScript, weatherWidgetAction]
    weatherWidgetProcess.running = true
    return true
  }

  Timer {
    id: weatherWidgetRetry
    interval: 3000
    onTriggered: root.checkWeatherWidget()
  }

  Process {
    id: weatherWidgetProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var t = String(text || "").trim()
        if (t === "replaced" || t === "native") root.weatherWidgetState = t
        // The shell doesn't answer `omarchy plugin list` while starting.
        else if (root.weatherWidgetAction === "status" && root.weatherWidgetState === "") weatherWidgetRetry.restart()
      }
    }
    onExited: function(exitCode) {
      var action = root.weatherWidgetAction
      root.weatherWidgetAction = ""
      if (action === "status") return
      if (exitCode !== 0) root.notify("\u{f0599}", "Weather widget", "Couldn't " + action + " it (exit " + exitCode + ")")
      else if (action === "replace") root.notify("\u{f0599}", "Weather is in the Now Bar now", "The weather widget is off; SUPER+CTRL+ALT+W opens the weather card")
      else root.notify("\u{f0599}", "Weather widget restored", "SUPER+CTRL+ALT+W opens Omarchy's weather again")
    }
  }

  Process {
    id: updateProcess
    command: ["omarchy-update-available"]
    onExited: function(exitCode) { root.updateAvailable = exitCode === 0 }
  }

  Timer {
    interval: 20 * 60 * 1000
    repeat: true
    running: root.weatherEnabled
    triggeredOnStart: true
    onTriggered: root.refreshWeather()
  }

  // Also re-reads the weather now and then without a tick running (the
  // `weather` binding above only follows `now`).
  Timer {
    interval: 10 * 60 * 1000
    repeat: true
    running: root.weatherEnabled && !root.needsTick
    onTriggered: root.now = Date.now()
  }

  Timer {
    interval: 3 * 3600 * 1000
    repeat: true
    // The Updates card tells it otherwise.
    running: root.weatherEnabled && !root.modules.updates
    triggeredOnStart: true
    onTriggered: if (!updateProcess.running) updateProcess.running = true
  }

  // --- updates waiting (bin/nowbar-updates) -----------------------------------------
  // Checked every `updateInterval` minutes (counted from the last check, kept
  // in state.json across restarts), and once after the computer starts when
  // "Check at startup" is on. Nothing here needs sudo; the Update button opens
  // a terminal running Omarchy's updater, which asks for the password there.

  property var updatesState: Model.normalizeUpdates(null)
  property bool updatesChecking: false
  // This boot's id, and the one the last startup check ran in: a shell
  // restart in the same boot isn't a startup.
  property string updatesBootId: ""
  property string updatesSavedBootId: ""
  // With "Check at startup" off, the first check comes one interval after this.
  readonly property double serviceStartedAt: Date.now()
  // What this system can check (see bin/nowbar-updates --available): a
  // fresh Omarchy has Omarchy, official and AUR; Flatpak only if installed.
  property var availableUpdateSources: []
  readonly property var updateSources: Model.activeSources(prefs.updateSourceList, availableUpdateSources)
  readonly property var shownUpdates: Model.updatesFor(updatesState, updateSources)
  readonly property string updatesScript: decodeURIComponent(String(Qt.resolvedUrl("bin/nowbar-updates")).replace(/^file:\/\//, ""))

  function checkUpdates() {
    if (!modules.updates || updatesProcess.running || updateSources.length === 0) return false
    updatesProcess.command = [updatesScript].concat(updateSources)
    updatesChecking = true
    updatesProcess.running = true
    return true
  }

  function checkUpdatesIfDue() {
    var last = updatesState.checkedAt > 0 ? updatesState.checkedAt : (prefs.updateOnStartup ? 0 : serviceStartedAt)
    if (Model.updatesDue(last, prefs.updateInterval, Date.now())) checkUpdates()
  }

  Process {
    id: updatesProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var prev = Model.updatesFor(root.updatesState, root.updateSources)
        root.updatesState = Model.mergeUpdates(root.updatesState, Model.parseUpdates(text), Date.now())
        root.saveState()
        // The card was already there: something new waiting brings it to
        // the pill all the same, like a new activity would.
        if (prev.items.length > 0 && Model.newUpdates(prev, root.shownUpdates) > 0) root.focusNewcomer("updates")
      }
    }
    onExited: root.updatesChecking = false
  }

  Process {
    id: updateSourcesProcess
    command: [root.updatesScript, "--available"]
    running: root.modules.updates
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.availableUpdateSources = Model.parseAvailableSources(text)
    }
  }

  Process {
    id: bootIdProcess
    command: ["cat", "/proc/sys/kernel/random/boot_id"]
    running: root.stateLoaded && root.modules.updates
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var id = String(text || "").trim()
        if (!id) return
        root.updatesBootId = id
        if (id !== root.updatesSavedBootId && root.prefs.updateOnStartup) updatesStartup.start()
      }
    }
  }

  // A little after login, so the network is up.
  Timer {
    id: updatesStartup
    interval: 45000
    onTriggered: {
      if (!root.checkUpdates()) return
      root.updatesSavedBootId = root.updatesBootId
      root.saveState()
    }
  }

  Timer {
    interval: 60000
    repeat: true
    running: root.modules.updates && root.stateLoaded
    onTriggered: root.checkUpdatesIfDue()
  }

  // Updating anywhere (the Update button, a terminal) writes pacman's log or
  // flatpak's .changed stamp: check again once it has been quiet for a bit,
  // so the card goes away by itself. Needs inotifywait.
  Process {
    id: updatesWatch
    command: ["sh", "-c",
      "command -v inotifywait >/dev/null 2>&1 || exit 3; set --; "
      + "for f in /var/log/pacman.log /var/lib/flatpak/.changed \"$HOME/.local/share/flatpak/.changed\"; do [ -e \"$f\" ] && set -- \"$@\" \"$f\"; done; "
      + "[ $# -gt 0 ] || exit 4; exec setpriv --pdeathsig TERM inotifywait -mq -e modify,attrib,close_write --format x -- \"$@\""]
    running: root.modules.updates && root.stateLoaded
    stdout: SplitParser {
      onRead: function(line) { updatesSettle.restart() }
    }
    onExited: function(exitCode) { if (exitCode !== 3 && exitCode !== 4 && root.modules.updates) updatesWatchRetry.restart() }
  }

  Timer {
    id: updatesSettle
    interval: 20000
    onTriggered: root.checkUpdates()
  }

  Timer {
    id: updatesWatchRetry
    interval: 60000
    onTriggered: if (root.modules.updates && !updatesWatch.running) updatesWatch.running = true
  }

  function runUpdate() {
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation", Model.updateCommand(shownUpdates.items)])
  }

  // --- pushed live updates (IPC) ---------------------------------------------------

  property var pushes: ({})

  // --- activities ------------------------------------------------------------------

  readonly property var allActivities: {
    var t = root.now
    var list = []
    list.push(Model.timerActivity(timerState, t))
    list.push(Model.stopwatchActivity(stopwatchState, t))
    list.push(Model.pomodoroActivity(pomodoroState, pomodoroCfg, t, Model.normalizePomodoroStats(pomodoroStats, t)))
    list.push(Model.sleepActivity(sleepState, t))
    list.push(Model.remindersActivity(reminders, t))
    list.push(Model.recordingActivity(recording, t))
    list.push(Model.dictationActivity(dictationState))
    list.push(Model.privacyActivity(privacyInfo))
    list.push(Model.modesActivity(modesState))
    list.push(Model.chargingActivity(chargingInfo))
    list.push(Model.batteryActivity(chargingInfo))
    for (var m = 0; m < mediaInfos.length; m++) list.push(Model.mediaActivity(mediaInfos[m]))
    for (var b in btRecent) list.push(Model.bluetoothActivity(btRecent[b]))
    for (var bl = 0; bl < btLowDevices.length; bl++) list.push(btLowDevices[bl])
    if (screenshot) list.push(Model.screenshotActivity(screenshot))
    if (recorded) list.push(Model.recordedActivity(recorded))
    if (firedReminder) list.push(Model.firedReminderActivity(firedReminder))
    if (weatherEnabled) list.push(Model.weatherActivity(weather, updateAvailable && !modules.updates))
    if (weatherEnabled) list.push(Model.rainActivity(weather))
    if (modules.updates) list.push(Model.updatesActivity(shownUpdates, updatesChecking))
    for (var k in pushes) list.push(Model.pushActivity(pushes[k], t))
    return list.filter(function(a) { return !!a })
  }

  // Activities hidden by hand, as { id: signature }; one comes back when it
  // changes state (a new track, the timer paused...).
  property var dismissed: ({})

  readonly property var activities: Model.visibleActivities(allActivities, prefs, dismissed)

  property string focusId: ""
  property var knownIds: ({})
  // After a manual switch, newcomers don't steal the focus for a while.
  property double manualUntil: 0

  readonly property int focusIndex: Model.indexOfId(activities, focusId)
  readonly property var focused: focusIndex >= 0 ? activities[focusIndex] : null
  readonly property int count: activities.length

  onAllActivitiesChanged: {
    var next = Model.pruneDismissed(dismissed, allActivities)
    if (next !== dismissed) dismissed = next
  }

  onActivitiesChanged: {
    var ids = {}
    for (var i = 0; i < activities.length; i++) ids[activities[i].id] = activities[i].priority
    var next = Model.resolveFocus({
      list: activities,
      focusId: focusId,
      knownIds: knownIds,
      autoFocus: prefs.autoFocus,
      manualUntil: manualUntil,
      now: Date.now()
    })
    knownIds = ids
    if (next !== focusId) focusId = next
  }

  // Gives `id` the focus as if it had just shown up: only with "Focus new
  // activities" on, not right after a switch by hand, and not over something
  // more important.
  function focusNewcomer(id) {
    if (!prefs.autoFocus || Date.now() < manualUntil) return false
    var i = Model.indexOfId(activities, id)
    if (i < 0) return false
    var a = activities[i]
    if (focused && focused.id !== id && focused.priority < a.priority) return false
    focusId = id
    return true
  }

  function step(delta) {
    var i = Model.nextIndex(activities.length, focusIndex, delta)
    if (i < 0) return false
    focusId = activities[i].id
    manualUntil = Date.now() + 8000
    freshenMedia(activities[i])
    return true
  }

  // A paused player chosen by hand starts its "leaves the pill" clock over.
  function freshenMedia(a) {
    if (!a || a.module !== "media" || a.playing || pausedAt[a.target] === undefined) return
    var next = {}
    for (var k in pausedAt) next[k] = pausedAt[k]
    next[a.target] = Date.now()
    pausedAt = next
  }

  // A player paused for a while (the "Media" options) gives the pill to the
  // most important other activity; it stays in the carousel. Never to another
  // player paused just as long, so two of them don't take turns.
  function releaseStaleMedia() {
    var a = focused
    var t = Date.now()
    var minutes = prefs.mediaPausedMinutes
    if (!a || t < manualUntil || !Model.staleMedia(a, pausedAt[a.target], t, minutes)) return
    // Not under you while you look at it.
    if (root.shell && root.shell.isPluginOpen(root.pluginId)) return
    for (var i = 0; i < activities.length; i++) {
      var b = activities[i]
      if (b.id !== a.id && !Model.staleMedia(b, pausedAt[b.target], t, minutes)) { focusId = b.id; return }
    }
  }

  Timer {
    interval: 30000
    repeat: true
    running: root.focused !== null && root.focused.module === "media" && !root.focused.playing && root.prefs.mediaPausedMinutes > 0
    onTriggered: root.releaseStaleMedia()
  }

  // An activity id, or a module name / push id as a shortcut ("media" is the
  // focused media card if there is one, else the first).
  function resolveId(idOrModule) {
    var key = String(idOrModule || "")
    var list = activities
    for (var i = 0; i < list.length; i++) if (list[i].id === key) return key
    if (focused && focused.module === key) return focused.id
    for (var j = 0; j < list.length; j++) if (list[j].module === key || list[j].id === "push:" + key) return list[j].id
    return ""
  }

  function focusOn(idOrModule) {
    var id = resolveId(idOrModule)
    if (!id) return false
    focusId = id
    manualUntil = Date.now() + 8000
    var i = Model.indexOfId(activities, id)
    if (i >= 0) freshenMedia(activities[i])
    return true
  }

  function dismiss(activityId) {
    var a = null
    for (var i = 0; i < activities.length; i++) if (activities[i].id === activityId) a = activities[i]
    if (!a || a.ambient) return false
    if (a.module === "push") return removePush(a.id.slice(5))
    var next = {}
    for (var k in dismissed) next[k] = dismissed[k]
    next[a.id] = a.signature
    dismissed = next
    return true
  }

  function removePush(id) {
    if (!(id in pushes)) return false
    var next = {}
    for (var k in pushes) if (k !== id) next[k] = pushes[k]
    pushes = next
    return true
  }

  // Only what the activity offers right now (no "pause" on a paused timer,
  // nothing on an activity that isn't there).
  function offersAction(activityId, actionId) {
    for (var i = 0; i < allActivities.length; i++) {
      var a = allActivities[i]
      if (a.id !== activityId) continue
      for (var j = 0; j < a.actions.length; j++) if (a.actions[j].id === actionId) return true
    }
    return false
  }

  // Runs one of an activity's actions (the ids from NowbarModel.js).
  function act(activityId, actionId) {
    activityId = resolveId(activityId) || activityId
    if (!offersAction(activityId, actionId)) return false
    var a = findActivity(activityId)
    var t = Date.now()
    root.now = t
    if (activityId === "pomodoro") {
      if (actionId === "pause") pomodoroState = Model.pausePomodoro(pomodoroState, t)
      else if (actionId === "resume") pomodoroState = Model.resumePomodoro(pomodoroState, t)
      else if (actionId === "skip") pomodoroState = Model.nextPomodoro(pomodoroState, pomodoroCfg, t)
      else if (actionId === "stop") pomodoroState = Model.idlePomodoro()
      saveState()
    } else if (activityId === "sleep") {
      if (actionId === "add") sleepState = Model.extendTimer(sleepState, 600, t)
      else if (actionId === "cancel") sleepState = Model.idleSleep()
      saveState()
    } else if (activityId === "screenshot") {
      screenshotAction(actionId)
    } else if (activityId === "recorded") {
      recordedAction(actionId)
    } else if (activityId === "reminderDone") {
      if (actionId === "snooze5") snoozeReminder(5)
      else if (actionId === "snooze15") snoozeReminder(15)
      else firedReminder = null
    } else if (activityId === "reminders" && actionId === "postpone") {
      postponeReminder()
    } else if (activityId.indexOf("bt:") === 0 && actionId === "audio") {
      useForAudio(activityId.slice(3))
    } else if (activityId === "timer" && timerState.state === "done") {
      if (actionId === "repeat") timerState = Model.startTimer(timerState.durationMs / 1000, t)
      else if (actionId === "add") timerState = Model.startTimer(60, t)
      else timerState = Model.idleTimer()
      saveState()
    } else if (activityId === "timer") {
      if (actionId === "pause") timerState = Model.pauseTimer(timerState, t)
      else if (actionId === "resume") timerState = Model.resumeTimer(timerState, t)
      else if (actionId === "add") timerState = Model.extendTimer(timerState, 60, t)
      else if (actionId === "cancel") timerState = Model.idleTimer()
      saveState()
    } else if (activityId === "stopwatch") {
      if (actionId === "pause") stopwatchState = Model.pauseStopwatch(stopwatchState, t)
      else if (actionId === "resume") stopwatchState = Model.resumeStopwatch(stopwatchState, t)
      else if (actionId === "lap") stopwatchState = Model.lapStopwatch(stopwatchState, t)
      else if (actionId === "reset") stopwatchState = Model.idleStopwatch()
      saveState()
    } else if (activityId === "reminders" && actionId === "clear") {
      Quickshell.execDetached(["omarchy-reminder", "clear"])
      reminders = []
      remindersFollowUp.restart()
    } else if (activityId === "recording" && actionId === "stop") {
      Quickshell.execDetached(["omarchy-capture-screenrecording", "--stop-recording"])
      recordingFollowUp.restart()
    } else if (activityId === "privacy" && actionId === "muteMic") {
      muteMic()
    } else if (activityId === "modes") {
      modeAction(actionId)
    } else if (a && a.module === "media") {
      mediaAction(a.target, actionId)
    } else if (activityId === "updates") {
      if (actionId === "update") runUpdate()
      else if (actionId === "check") checkUpdates()
    } else if (activityId.indexOf("push:") === 0 && actionId === "remove") {
      removePush(activityId.slice(5))
    } else {
      return false
    }
    return true
  }

  // The primary action: middle click on the pill, Enter in the popup.
  function primary(activityId) {
    for (var i = 0; i < activities.length; i++) {
      var a = activities[i]
      if (a.id === activityId && a.actions.length > 0) return act(a.id, a.actions[0].id)
    }
    return false
  }

  Timer {
    id: remindersFollowUp
    interval: 800
    onTriggered: root.refreshReminders()
  }

  Timer {
    id: recordingFollowUp
    interval: 1000
    onTriggered: root.refreshRecording()
  }

  // One clock for everything that counts: timer, stopwatch, recording,
  // reminders, pushes with a TTL, and the media position.
  readonly property bool needsTick: timerState.state === "running" || timerState.state === "done"
    || recorded !== null
    || stopwatchState.state === "running"
    || recording.active
    || reminders.length > 0
    || Object.keys(pushes).length > 0
    || pomodoroState.state === "running"
    || sleepState.state === "running"
    || Object.keys(btRecent).length > 0
    || screenshot !== null
    || mediaPlayers.some(function(p) { return p.isPlaying })

  Timer {
    id: ticker
    interval: 1000
    repeat: true
    running: root.needsTick
    onTriggered: {
      root.now = Date.now()
      for (var i = 0; i < root.mediaPlayers.length; i++) {
        var p = root.mediaPlayers[i]
        if (p.isPlaying && p.positionSupported) p.positionChanged()
      }
      root.checkTimer()
      root.pruneBluetooth(root.now)
      if (root.screenshot && root.screenshot.until <= root.now) root.screenshot = null
      if (root.recorded && root.recorded.until <= root.now) root.recorded = null
      var pruned = Model.prunePushes(root.pushes, root.now)
      if (pruned !== root.pushes) root.pushes = pruned
    }
  }

  Component.onCompleted: {
    stateDirProcess.running = true
    checkWeatherWidget()
    checkIndicators()
    voxtypeCheck.running = true
    syncLastPlaying()
    initArtCache()
  }

  // Re-read the polled sources right away when a module is switched back on.
  onModulesChanged: {
    refreshReminders()
    refreshRecording()
    refreshModes()
    refreshCamera()
  }

  function statusJson() {
    return JSON.stringify({
      focus: focusId,
      coverAccent: artAccent,
      coverBase: artBase,
      weather: weather ? { temp: weather.temp, unit: weather.unit, desc: weather.desc, location: weather.location } : null,
      activities: activities.map(function(a) {
        return { id: a.id, module: a.module, title: a.title, subtitle: a.subtitle, progress: a.progress }
      })
    })
  }

  // Asks the bar widget to show its options (IPC `settings`).
  signal settingsRequested(string tab)

  IpcHandler {
    target: "nowbar"

    // Open the popup on the options: settings [activities|look|quick|weather|updates]
    function settings(tab: string): string {
      var t = String(tab || "")
      if (t === "timers") t = "quick"   // the tab's old name
      if (t !== "" && ["activities", "look", "quick", "weather", "updates"].indexOf(t) === -1)
        return "unknown tab: use activities, look, quick, weather or updates"
      root.settingsRequested(t)
      if (root.shell && !root.shell.isPluginOpen(root.pluginId)) root.shell.summon(root.pluginId, "{}")
      return "ok"
    }

    function status(): string { return root.statusJson() }
    // Check for updates now (the Updates card).
    function updates(): string {
      if (!root.modules.updates) return "error: the updates module is turned off"
      if (root.updatesChecking) return "already checking"
      return root.checkUpdates() ? "checking" : "error: no source turned on"
    }
    function next(): string { return root.step(1) ? "ok" : "empty" }
    function prev(): string { return root.step(-1) ? "ok" : "empty" }
    function toggle(): string {
      return root.shell && root.shell.toggle(root.pluginId) ? "ok" : "unavailable"
    }
    function focus(id: string): string { return root.focusOn(id) ? "ok" : "not found" }
    // Middle-click equivalent on the focused activity.
    function primary(): string { return root.focused && root.primary(root.focused.id) ? "ok" : "none" }
    // The camera/microphone card is a privacy warning: only a click hides it,
    // so a process using them can't make it go away through IPC.
    function dismiss(): string {
      if (root.focused && root.focused.module === "privacy") return "refused: hide it from the Now Bar itself"
      return root.focused && root.dismiss(root.focused.id) ? "ok" : "none"
    }
    // Any action of any activity, e.g. `act timer cancel`, `act media next`.
    function act(activityId: string, actionId: string): string {
      return root.act(String(activityId), String(actionId)) ? "ok" : "unknown activity or action"
    }

    // timer 90 | 25m | 1h30m | 14:30 (the next 14:30)
    function timer(duration: string): string {
      return root.startTimer(Model.parseTimerArg(duration, Date.now())) ? "ok" : "invalid duration: use seconds, 25m, 1h30m or HH:MM"
    }
    function stopwatch(): string { root.startStopwatch(); return "ok" }
    function pomodoro(): string { root.startPomodoro(); return "ok" }
    // Same as the Quick toggles: dnd, nightlight, stayAwake, record, reminder, dictation.
    function quick(id: string): string {
      if (root.quickIds.indexOf(String(id)) === -1) return "unknown: use " + root.quickIds.join(", ")
      root.quickToggle(String(id))
      return "ok"
    }
    // Open the popup on the weather card (Omarchy's weather shortcut can
    // point here once the weather widget is off).
    function weather(): string {
      if (!root.weatherEnabled) return "error: the weather card is turned off"
      root.refreshWeatherIfStale()
      if (!root.focusOn("brief")) return "no weather yet"
      if (root.shell && !root.shell.isPluginOpen(root.pluginId)) root.shell.summon(root.pluginId, "{}")
      return "ok"
    }
    // Pause the media after a while: sleep 30m | 45 (minutes) | 23:00
    function sleep(duration: string): string {
      var d = String(duration || "")
      var secs = /^\d{1,4}$/.test(d) ? parseInt(d, 10) * 60 : Model.parseTimerArg(d, Date.now())
      return root.startSleep(secs) ? "ok" : "invalid duration: use minutes, 1h, or HH:MM"
    }

    // push <id> <json>: {"title", "subtitle", "pill", "icon", "progress" 0-1,
    // "ttl" seconds, "priority" high|normal|low, "urgent" bool,
    // "state" running|success|error, "elapsed" bool}. Text only.
    function push(id: string, json: string): string {
      if (!root.modules.push) return "error: the push module is turned off"
      var r = Model.sanitizePush(id, json, Date.now())
      if (!r.ok) return "error: " + r.error
      root.pushes = Model.upsertPush(root.pushes, r.item)
      return "ok"
    }
    function remove(id: string): string { return root.removePush(String(id)) ? "ok" : "not found" }
  }
}
