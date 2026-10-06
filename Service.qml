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
  property var sleepState: Model.idleSleep()
  readonly property var pomodoroCfg: Model.pomodoroConfig(prefs)
  property bool stateLoaded: false

  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/vinicgobbi.nowbar"

  function saveState() {
    if (!stateLoaded) return
    stateFile.setText(JSON.stringify({ timer: timerState, stopwatch: stopwatchState, pomodoro: pomodoroState, sleep: sleepState }) + "\n")
  }

  function restoreState(text) {
    var data = {}
    try { data = JSON.parse(String(text || "{}")) || {} } catch (e) { data = {} }
    timerState = Model.normalizeTimer(data.timer)
    stopwatchState = Model.normalizeStopwatch(data.stopwatch)
    pomodoroState = Model.normalizePomodoro(data.pomodoro)
    sleepState = Model.normalizeSleep(data.sleep)
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
      timerState = Model.idleTimer()
      changed = true
    }
    if (Model.timerFinished(pomodoroState, t)) {
      var was = pomodoroState.phase
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

  function playerKey(p) {
    return p ? String(p.dbusName || p.desktopEntry || p.identity || "") : ""
  }

  function isProxy(p) {
    return String(p && p.dbusName || "").toLowerCase().indexOf("playerctld") !== -1
  }

  function hasTrack(p) {
    return !!(p && (p.trackTitle || p.trackArtist))
  }

  function syncLastPlaying() {
    var t = Date.now()
    var next = {}
    var alive = {}
    for (var i = 0; i < players.length; i++) alive[playerKey(players[i])] = true
    // Forget players that went away.
    for (var k in playedKeys) if (alive[k]) next[k] = playedKeys[k]
    for (var j = 0; j < players.length; j++) {
      var p = players[j]
      if (p && p.isPlaying && !isProxy(p) && hasTrack(p)) next[playerKey(p)] = t
    }
    playedKeys = next
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
      if (!hasTrack(p)) continue
      if (p.isPlaying) (isProxy(p) ? proxies : list).push(p)
      else if (!isProxy(p) && playedKeys[playerKey(p)] !== undefined) paused.push(p)
    }
    if (list.length === 0) list = proxies.slice(0, 1)
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
        player: p.identity || p.desktopEntry || "",
        playing: !!p.isPlaying,
        canToggle: !!(p.canTogglePlaying || p.canPlay || p.canPause),
        canPrevious: !!p.canGoPrevious,
        canNext: !!p.canGoNext,
        canSeek: !!p.canSeek && !!p.positionSupported,
        position: p.positionSupported ? p.position : 0,
        length: p.lengthSupported ? p.length : 0,
        volumeSupported: !!p.volumeSupported,
        volume: p.volumeSupported ? p.volume : 0
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
    "  curl -fsS --proto =https --connect-timeout 3 --max-time 8 --max-filesize \"$4\" -- \"$1\" 2>/dev/null | head -c \"$4\" > \"$tmp\"",
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

  function extractAccent(path, generation) {
    if (accentProcess.running) { accentProcess.pending = { path: path, generation: generation }; return }
    accentProcess.generation = generation
    accentProcess.command = ["timeout", "5", "magick", "-limit", "area", "64MB", "-limit", "memory", "64MB",
      "-limit", "map", "64MB", path + "[0]", "-resize", "64x64", "-colors", "12", "-format", "%c", "histogram:info:-"]
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
        if (accentProcess.generation === root._artGeneration) root.artAccent = Model.accentFromHistogram(text)
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
    if (action === "playPause") {
      if (p.canTogglePlaying) p.togglePlaying()
      else if (p.isPlaying && p.canPause) p.pause()
      else if (p.canPlay) p.play()
    } else if (action === "next" && p.canGoNext) p.next()
    else if (action === "previous" && p.canGoPrevious) p.previous()
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
      onStreamFinished: root.reminders = Model.parseReminders(text)
    }
    onExited: function(exitCode) { if (exitCode !== 0) root.reminders = [] }
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
    command: ["sh", "-c", "pid=$(pgrep -o -f '^gpu-screen-recorder') || exit 1; ps -o etimes= -p \"$pid\""]
    // Prints the recorder's uptime in seconds, nothing when not recording.
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var out = String(text || "").trim()
        if (out === "") {
          if (root.recording.active) root.recording = { active: false, startedAt: 0 }
          return
        }
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
      + "exec setpriv --pdeathsig TERM inotifywait -mq -e close_write,moved_to --format %f -- \"$1\"", "_", root.screenshotDir]
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
    else if (action === "copy") Quickshell.execDetached(["sh", "-c", "wl-copy --type \"$2\" < \"$1\"", "_", s.path,
      /\.png$/i.test(s.path) ? "image/png" : "image/jpeg"])
    screenshot = null
  }

  // --- Now Brief: weather and updates, for the pill when nothing goes on ---------------

  property var weather: ({ icon: "", temp: "", condition: "" })
  property bool updateAvailable: false
  readonly property bool briefEnabled: prefs.whenEmpty === "brief"

  Process {
    id: weatherProcess
    // Same location rules as omarchy-weather-icon: the saved place if any,
    // else wttr.in's guess from the IP.
    command: ["sh", "-c",
      "q=''; if [ -s \"$HOME/.local/state/omarchy/settings/weather.json\" ]; then "
      + "l=$(omarchy-weather-location 2>/dev/null); [ -n \"$l\" ] && q=$(jq -rn --arg l \"$l\" '$l | @uri'); fi; "
      + "i=$(omarchy-weather-icon 2>/dev/null | head -n1); "
      + "t=$(curl -fsS --max-time 8 \"https://wttr.in/${q}?format=%t|%C\" 2>/dev/null | head -c 200 | head -n1); "
      + "printf '%s\\n%s\\n' \"$i\" \"$t\""]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var w = Model.parseWeather(text)
        // Keep the last good reading when offline.
        if (w.temp) root.weather = w
      }
    }
  }

  Process {
    id: updateProcess
    command: ["omarchy-update-available"]
    onExited: function(exitCode) { root.updateAvailable = exitCode === 0 }
  }

  Timer {
    interval: 30 * 60 * 1000
    repeat: true
    running: root.briefEnabled
    triggeredOnStart: true
    onTriggered: if (!weatherProcess.running) weatherProcess.running = true
  }

  Timer {
    interval: 3 * 3600 * 1000
    repeat: true
    running: root.briefEnabled
    triggeredOnStart: true
    onTriggered: if (!updateProcess.running) updateProcess.running = true
  }

  readonly property var brief: briefEnabled
    ? Model.briefInfo({ weather: weather, reminders: reminders, updates: updateAvailable, now: root.now })
    : null

  // --- pushed live updates (IPC) ---------------------------------------------------

  property var pushes: ({})

  // --- activities ------------------------------------------------------------------

  readonly property var allActivities: {
    var t = root.now
    var list = []
    list.push(Model.timerActivity(timerState, t))
    list.push(Model.stopwatchActivity(stopwatchState, t))
    list.push(Model.pomodoroActivity(pomodoroState, pomodoroCfg, t))
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
    if (screenshot) list.push(Model.screenshotActivity(screenshot))
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
    for (var i = 0; i < activities.length; i++) ids[activities[i].id] = true
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

  function step(delta) {
    var i = Model.nextIndex(activities.length, focusIndex, delta)
    if (i < 0) return false
    focusId = activities[i].id
    manualUntil = Date.now() + 8000
    return true
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
    return true
  }

  function dismiss(activityId) {
    var a = null
    for (var i = 0; i < activities.length; i++) if (activities[i].id === activityId) a = activities[i]
    if (!a) return false
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
  readonly property bool needsTick: timerState.state === "running"
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
      var pruned = Model.prunePushes(root.pushes, root.now)
      if (pruned !== root.pushes) root.pushes = pruned
    }
  }

  Component.onCompleted: {
    stateDirProcess.running = true
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
      brief: brief ? brief.pillText : "",
      activities: activities.map(function(a) {
        return { id: a.id, module: a.module, title: a.title, subtitle: a.subtitle, progress: a.progress }
      })
    })
  }

  IpcHandler {
    target: "nowbar"

    function status(): string { return root.statusJson() }
    function next(): string { return root.step(1) ? "ok" : "empty" }
    function prev(): string { return root.step(-1) ? "ok" : "empty" }
    function toggle(): string {
      return root.shell && root.shell.toggle(root.pluginId) ? "ok" : "unavailable"
    }
    function focus(id: string): string { return root.focusOn(id) ? "ok" : "not found" }
    // Middle-click equivalent on the focused activity.
    function primary(): string { return root.focused && root.primary(root.focused.id) ? "ok" : "none" }
    function dismiss(): string { return root.focused && root.dismiss(root.focused.id) ? "ok" : "none" }
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
