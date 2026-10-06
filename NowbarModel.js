// Pure logic for the Now Bar: every live source (media, timer, recording...)
// is turned into an "activity" here, and the list of activities is sorted
// and focused here too. No QML in this file, so it runs under `node --test`.
//
// An activity is:
//   { id, module, priority, icon, urgent, title, subtitle, pillText,
//     progress (0..1, or -1 for none), details: [string], actions: [{id, label, icon}],
//     signature }
// actions[0] is the primary action (middle click on the pill, Enter in the popup).
// `signature` changes whenever the activity changes state; a dismissed
// activity comes back once its signature differs from the one dismissed.

// --- text --------------------------------------------------------------------

var MAX_FIELD_CHARS = 120

// Strips control characters (newlines, ANSI escapes, bidi overrides...) and
// caps the length, so text from outside (players, scripts, process names)
// can't break the layout or spoof other lines.
function clean(value, max) {
  var limit = max || MAX_FIELD_CHARS
  // Cut first: a player can send megabytes of title, and this runs every second.
  var t = String(value === undefined || value === null ? "" : value).slice(0, limit * 4 + 64)
  t = t.replace(/[\u0000-\u001f\u007f-\u009f‎‏‪-‮⁦-⁩]/g, " ")
  t = t.replace(/\s+/g, " ").trim()
  return t.length > limit ? t.slice(0, limit - 1) + "…" : t
}

function pad2(n) {
  return (n < 10 ? "0" : "") + n
}

// 65000 -> "1:05", 3723000 -> "1:02:03". Negative values count as zero.
function formatDuration(ms) {
  var s = Math.max(0, Math.floor(Number(ms) / 1000) || 0)
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  var sec = s % 60
  return h > 0 ? h + ":" + pad2(m) + ":" + pad2(sec) : m + ":" + pad2(sec)
}

// Like formatDuration, but rounds up: a timer with 0.4 s left still shows 0:01.
function formatCountdown(ms) {
  return formatDuration(Math.ceil(Math.max(0, Number(ms) || 0) / 1000) * 1000)
}

// 5400 -> "1h 30m", 300 -> "5m", 40 -> "<1m".
function formatEta(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds) || 0))
  if (s < 60) return "<1m"
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  if (h > 0) return m > 0 ? h + "h " + m + "m" : h + "h"
  return m + "m"
}

// "45 s", "1 min", "1 min 30 s", "1 h", "1 h 30 min"
function presetLabel(seconds) {
  var s = Math.max(0, Math.floor(Number(seconds) || 0))
  if (s < 60) return s + " s"
  var h = Math.floor(s / 3600)
  var m = Math.floor((s % 3600) / 60)
  var sec = s % 60
  if (h > 0) return m > 0 ? h + " h " + m + " min" : h + " h"
  return sec > 0 ? m + " min " + sec + " s" : m + " min"
}

// "90" (seconds), "25m", "1h30m", "45s", or a clock time "14:30" (the next
// one: tomorrow if it already passed). Returns seconds, or 0 when invalid.
// `now` is epoch ms; the clock time uses the local time zone.
function parseTimerArg(arg, now) {
  var t = String(arg === undefined || arg === null ? "" : arg).trim().toLowerCase()
  if (/^\d{1,6}$/.test(t)) return parseInt(t, 10)
  var clock = /^(\d{1,2}):(\d{2})$/.exec(t)
  if (clock) {
    var h = parseInt(clock[1], 10)
    var m = parseInt(clock[2], 10)
    if (h > 23 || m > 59) return 0
    var d = new Date(now)
    var target = new Date(d.getFullYear(), d.getMonth(), d.getDate(), h, m, 0, 0).getTime()
    if (target <= now) target = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1, h, m, 0, 0).getTime()
    return Math.round((target - now) / 1000)
  }
  var units = /^(?:(\d{1,3})h)?\s*(?:(\d{1,4})m(?:in)?)?\s*(?:(\d{1,5})s)?$/.exec(t)
  if (units && (units[1] || units[2] || units[3]))
    return (parseInt(units[1] || "0", 10) * 3600) + (parseInt(units[2] || "0", 10) * 60) + parseInt(units[3] || "0", 10)
  return 0
}

// Quick start timers, as minutes separated by commas ("1,5,10,25"). Returns
// seconds, at most 6 entries, each 1 min to 24 h. Empty means no timers;
// text with nothing usable in it falls back to the default.
var DEFAULT_PRESETS = "1,5,10,25"

function parsePresets(text) {
  if (text !== undefined && text !== null && String(text).trim() === "") return []
  var out = []
  var parts = String(text === undefined || text === null ? "" : text).split(",")
  for (var i = 0; i < parts.length && out.length < 6; i++) {
    var p = parts[i].trim()
    if (!/^\d{1,4}$/.test(p)) continue
    var m = parseInt(p, 10)
    if (m >= 1 && m <= 1440 && out.indexOf(m * 60) === -1) out.push(m * 60)
  }
  return out.length ? out : (String(text) === DEFAULT_PRESETS ? [] : parsePresets(DEFAULT_PRESETS))
}

// --- priorities --------------------------------------------------------------
// Lower comes first. Privacy and recording win because they're things the
// user must not miss; paused media is the least interesting thing to show.

var PRIORITY = {
  privacy: 10,
  battery: 15,
  recording: 20,
  screenshot: 25,
  dictation: 30,
  pushHigh: 35,
  timer: 40,
  pomodoro: 42,
  reminderSoon: 45,
  stopwatch: 50,
  bluetooth: 55,
  mediaPlaying: 60,
  push: 65,
  sleep: 70,
  reminder: 75,
  charging: 80,
  pushLow: 85,
  modes: 90,
  mediaPaused: 95,
  brief: 99
}

var REMINDER_SOON_SECONDS = 5 * 60

// --- timer & stopwatch -------------------------------------------------------
// timer:     { state: "idle"|"running"|"paused", durationMs, endsAt, remainingMs }
// stopwatch: { state: "idle"|"running"|"paused", startedAt, accumulatedMs, laps: [ms] }

var MAX_TIMER_MS = 24 * 3600 * 1000
var MAX_LAPS = 99

function idleTimer() {
  return { state: "idle", durationMs: 0, endsAt: 0, remainingMs: 0 }
}

function idleStopwatch() {
  return { state: "idle", startedAt: 0, accumulatedMs: 0, laps: [] }
}

function num(v, fallback) {
  var n = Number(v)
  return isFinite(n) ? n : fallback
}

// Whatever was read back from disk: anything malformed becomes idle.
function normalizeTimer(t) {
  if (!t || typeof t !== "object") return idleTimer()
  var state = t.state === "running" || t.state === "paused" ? t.state : "idle"
  var duration = Math.min(MAX_TIMER_MS, Math.max(0, num(t.durationMs, 0)))
  if (state === "idle" || duration <= 0) return idleTimer()
  return {
    state: state,
    durationMs: duration,
    endsAt: Math.max(0, num(t.endsAt, 0)),
    remainingMs: Math.min(duration, Math.max(0, num(t.remainingMs, 0)))
  }
}

function normalizeStopwatch(s) {
  if (!s || typeof s !== "object") return idleStopwatch()
  var state = s.state === "running" || s.state === "paused" ? s.state : "idle"
  if (state === "idle") return idleStopwatch()
  var laps = Array.isArray(s.laps) ? s.laps : []
  var kept = []
  for (var i = 0; i < laps.length && kept.length < MAX_LAPS; i++) {
    var lap = num(laps[i], -1)
    if (lap >= 0) kept.push(lap)
  }
  return {
    state: state,
    startedAt: Math.max(0, num(s.startedAt, 0)),
    accumulatedMs: Math.max(0, num(s.accumulatedMs, 0)),
    laps: kept
  }
}

function startTimer(seconds, now) {
  var ms = Math.min(MAX_TIMER_MS, Math.max(0, Math.floor(num(seconds, 0))) * 1000)
  if (ms <= 0) return idleTimer()
  return { state: "running", durationMs: ms, endsAt: now + ms, remainingMs: ms }
}

function timerRemaining(t, now) {
  if (!t || t.state === "idle") return 0
  if (t.state === "paused") return Math.max(0, t.remainingMs)
  return Math.max(0, t.endsAt - now)
}

function pauseTimer(t, now) {
  if (!t || t.state !== "running") return t
  return { state: "paused", durationMs: t.durationMs, endsAt: 0, remainingMs: timerRemaining(t, now) }
}

function resumeTimer(t, now) {
  if (!t || t.state !== "paused") return t
  return { state: "running", durationMs: t.durationMs, endsAt: now + t.remainingMs, remainingMs: t.remainingMs }
}

function extendTimer(t, seconds, now) {
  if (!t || t.state === "idle") return t
  var add = Math.max(0, num(seconds, 0)) * 1000
  var remaining = Math.min(MAX_TIMER_MS, timerRemaining(t, now) + add)
  var duration = Math.min(MAX_TIMER_MS, Math.max(t.durationMs, remaining))
  if (t.state === "paused") return { state: "paused", durationMs: duration, endsAt: 0, remainingMs: remaining }
  return { state: "running", durationMs: duration, endsAt: now + remaining, remainingMs: remaining }
}

function timerFinished(t, now) {
  return !!t && t.state === "running" && now >= t.endsAt
}

function stopwatchElapsed(s, now) {
  if (!s || s.state === "idle") return 0
  if (s.state === "paused") return s.accumulatedMs
  return s.accumulatedMs + Math.max(0, now - s.startedAt)
}

function startStopwatch(now) {
  return { state: "running", startedAt: now, accumulatedMs: 0, laps: [] }
}

function pauseStopwatch(s, now) {
  if (!s || s.state !== "running") return s
  return { state: "paused", startedAt: 0, accumulatedMs: stopwatchElapsed(s, now), laps: s.laps.slice() }
}

function resumeStopwatch(s, now) {
  if (!s || s.state !== "paused") return s
  return { state: "running", startedAt: now, accumulatedMs: s.accumulatedMs, laps: s.laps.slice() }
}

// Laps are stored as the total elapsed time when each one was taken.
function lapStopwatch(s, now) {
  if (!s || s.state !== "running") return s
  var laps = s.laps.concat([stopwatchElapsed(s, now)])
  if (laps.length > MAX_LAPS) laps = laps.slice(laps.length - MAX_LAPS)
  return { state: "running", startedAt: s.startedAt, accumulatedMs: s.accumulatedMs, laps: laps }
}

function timerActivity(t, now) {
  if (!t || t.state === "idle") return null
  var remaining = timerRemaining(t, now)
  var running = t.state === "running"
  var text = formatCountdown(remaining)
  return {
    id: "timer",
    module: "timer",
    priority: PRIORITY.timer,
    icon: running ? "\u{f13ab}" : "\u{f1adf}",
    urgent: false,
    title: running ? text : text + " (paused)",
    subtitle: "Timer · " + presetLabel(t.durationMs / 1000),
    pillText: running ? text : text + " ‖",
    progress: t.durationMs > 0 ? 1 - remaining / t.durationMs : -1,
    details: [],
    actions: running
      ? [{ id: "pause", label: "Pause", icon: "\u{f03e4}" }, { id: "add", label: "+1 min", icon: "\u{f0415}" }, { id: "cancel", label: "Cancel", icon: "\u{f0156}" }]
      : [{ id: "resume", label: "Resume", icon: "\u{f040a}" }, { id: "add", label: "+1 min", icon: "\u{f0415}" }, { id: "cancel", label: "Cancel", icon: "\u{f0156}" }],
    signature: t.state + ":" + t.durationMs
  }
}

function stopwatchActivity(s, now) {
  if (!s || s.state === "idle") return null
  var elapsed = stopwatchElapsed(s, now)
  var running = s.state === "running"
  var text = formatDuration(elapsed)
  var details = []
  // Newest lap first, each with its own split time.
  for (var i = s.laps.length - 1; i >= 0 && details.length < 5; i--) {
    var split = s.laps[i] - (i > 0 ? s.laps[i - 1] : 0)
    details.push("Lap " + (i + 1) + "  " + formatDuration(split) + "  (" + formatDuration(s.laps[i]) + ")")
  }
  return {
    id: "stopwatch",
    module: "timer",
    priority: PRIORITY.stopwatch,
    icon: "\u{f520}",
    urgent: false,
    title: running ? text : text + " (paused)",
    subtitle: "Stopwatch" + (s.laps.length ? " · " + s.laps.length + (s.laps.length === 1 ? " lap" : " laps") : ""),
    pillText: running ? text : text + " ‖",
    progress: -1,
    details: details,
    actions: running
      ? [{ id: "pause", label: "Pause", icon: "\u{f03e4}" }, { id: "lap", label: "Lap", icon: "\u{f023b}" }, { id: "reset", label: "Reset", icon: "\u{f099b}" }]
      : [{ id: "resume", label: "Resume", icon: "\u{f040a}" }, { id: "reset", label: "Reset", icon: "\u{f099b}" }],
    signature: s.state
  }
}

// --- pomodoro -------------------------------------------------------------------
// p:   { state: "idle"|"running"|"paused", phase: "focus"|"break"|"longBreak",
//        focusDone (focus blocks finished), durationMs, endsAt, remainingMs }
// cfg: { focus, shortBreak, longBreak, every } in minutes / focus blocks.

function idlePomodoro() {
  return { state: "idle", phase: "focus", focusDone: 0, durationMs: 0, endsAt: 0, remainingMs: 0 }
}

function pomodoroConfig(prefs) {
  var p = prefs || {}
  return {
    focus: clampInt(p.pomodoroFocus, 1, 180, 25),
    shortBreak: clampInt(p.pomodoroBreak, 1, 60, 5),
    longBreak: clampInt(p.pomodoroLongBreak, 1, 120, 15),
    every: 4
  }
}

function phaseMinutes(phase, cfg) {
  return phase === "focus" ? cfg.focus : (phase === "longBreak" ? cfg.longBreak : cfg.shortBreak)
}

function startPomodoroPhase(phase, focusDone, cfg, now) {
  var ms = phaseMinutes(phase, cfg) * 60000
  return { state: "running", phase: phase, focusDone: focusDone, durationMs: ms, endsAt: now + ms, remainingMs: ms }
}

function startPomodoro(cfg, now) {
  return startPomodoroPhase("focus", 0, cfg, now)
}

function normalizePomodoro(p) {
  if (!p || typeof p !== "object") return idlePomodoro()
  var state = p.state === "running" || p.state === "paused" ? p.state : "idle"
  var phase = p.phase === "break" || p.phase === "longBreak" ? p.phase : "focus"
  var duration = Math.min(MAX_TIMER_MS, Math.max(0, num(p.durationMs, 0)))
  if (state === "idle" || duration <= 0) return idlePomodoro()
  return {
    state: state,
    phase: phase,
    focusDone: Math.max(0, Math.min(999, Math.floor(num(p.focusDone, 0)))),
    durationMs: duration,
    endsAt: Math.max(0, num(p.endsAt, 0)),
    remainingMs: Math.min(duration, Math.max(0, num(p.remainingMs, 0)))
  }
}

// The timer helpers work on any { state, durationMs, endsAt, remainingMs }.
function pausePomodoro(p, now) {
  if (!p || p.state !== "running") return p
  var t = pauseTimer(p, now)
  return { state: "paused", phase: p.phase, focusDone: p.focusDone, durationMs: p.durationMs, endsAt: 0, remainingMs: t.remainingMs }
}

function resumePomodoro(p, now) {
  if (!p || p.state !== "paused") return p
  return { state: "running", phase: p.phase, focusDone: p.focusDone, durationMs: p.durationMs, endsAt: now + p.remainingMs, remainingMs: p.remainingMs }
}

// The phase after the current one: focus -> break (a long one every
// `every` focus blocks) -> focus...
function nextPomodoro(p, cfg, now) {
  if (p.phase === "focus") {
    var done = p.focusDone + 1
    return startPomodoroPhase(done % cfg.every === 0 ? "longBreak" : "break", done, cfg, now)
  }
  return startPomodoroPhase("focus", p.focusDone, cfg, now)
}

var PHASE_LABEL = { focus: "Focus", "break": "Break", longBreak: "Long break" }

function pomodoroActivity(p, cfg, now) {
  if (!p || p.state === "idle") return null
  var remaining = timerRemaining(p, now)
  var running = p.state === "running"
  var text = formatCountdown(remaining)
  var label = PHASE_LABEL[p.phase]
  var round = (p.focusDone % cfg.every) + (p.phase === "focus" ? 1 : 0)
  return {
    id: "pomodoro",
    module: "timer",
    priority: PRIORITY.pomodoro,
    icon: p.phase === "focus" ? "\u{f04fe}" : "\u{f0176}",
    urgent: false,
    title: label + " \u00b7 " + text + (running ? "" : " (paused)"),
    subtitle: "Pomodoro \u00b7 " + (p.phase === "focus" ? "round " + Math.max(1, round) + "/" + cfg.every : p.focusDone + " done"),
    pillText: label + " " + text + (running ? "" : " \u2016"),
    progress: p.durationMs > 0 ? 1 - remaining / p.durationMs : -1,
    details: [],
    actions: [
      running ? { id: "pause", label: "Pause", icon: "\u{f03e4}" } : { id: "resume", label: "Resume", icon: "\u{f040a}" },
      { id: "skip", label: "Skip", icon: "\u{f04ad}" },
      { id: "stop", label: "Stop", icon: "\u{f04db}" }
    ],
    signature: p.state + ":" + p.phase
  }
}

// --- sleep timer (pauses the media when it ends) -----------------------------------
// s: { state: "idle"|"running", durationMs, endsAt }

function idleSleep() {
  return { state: "idle", durationMs: 0, endsAt: 0, remainingMs: 0 }
}

function normalizeSleep(s) {
  var t = normalizeTimer(s)
  return t.state === "running" ? t : idleSleep()
}

function sleepActivity(s, now) {
  if (!s || s.state !== "running") return null
  var remaining = timerRemaining(s, now)
  return {
    id: "sleep",
    module: "timer",
    priority: PRIORITY.sleep,
    icon: "\u{f04b2}",
    urgent: false,
    title: "Media stops in " + formatCountdown(remaining),
    subtitle: "Sleep timer \u00b7 " + presetLabel(s.durationMs / 1000),
    pillText: "Sleep " + formatCountdown(remaining),
    progress: s.durationMs > 0 ? 1 - remaining / s.durationMs : -1,
    details: [],
    actions: [{ id: "add", label: "+10 min", icon: "\u{f0415}" }, { id: "cancel", label: "Cancel", icon: "\u{f0156}" }],
    signature: "running:" + s.durationMs
  }
}

// --- reminders (omarchy-reminder show --json) --------------------------------

// Returns [{ unit, label, at (epoch ms) }], earliest first. `text` is the
// command's stdout; anything unexpected yields [].
function parseReminders(text) {
  var data
  try { data = JSON.parse(String(text || "")) } catch (e) { return [] }
  var list = data && Array.isArray(data.reminders) ? data.reminders : []
  var out = []
  for (var i = 0; i < list.length && out.length < 20; i++) {
    var r = list[i]
    if (!r || typeof r !== "object") continue
    var at = num(r.at, 0)
    if (at <= 0) continue
    out.push({
      unit: clean(r.unit, 80),
      label: clean(r.label || r.message || "Reminder"),
      at: at * 1000,
      minutes: Math.max(0, Math.floor(num(r.minutes, 0)))
    })
  }
  out.sort(function(a, b) { return a.at - b.at })
  return out
}

function remindersActivity(reminders, now) {
  var pending = []
  for (var i = 0; i < (reminders || []).length; i++) if (reminders[i].at > now) pending.push(reminders[i])
  if (pending.length === 0) return null
  var next = pending[0]
  var left = next.at - now
  var total = next.minutes > 0 ? next.minutes * 60000 : 0
  var details = []
  for (var j = 1; j < pending.length && details.length < 5; j++)
    details.push(pending[j].label + "  ·  in " + formatCountdown(pending[j].at - now))
  return {
    id: "reminders",
    module: "reminders",
    priority: left <= REMINDER_SOON_SECONDS * 1000 ? PRIORITY.reminderSoon : PRIORITY.reminder,
    icon: "\u{f088c}",
    urgent: false,
    title: next.label,
    subtitle: "Reminder in " + formatCountdown(left) + (pending.length > 1 ? " · +" + (pending.length - 1) + " more" : ""),
    pillText: formatCountdown(left),
    progress: total > 0 ? Math.max(0, Math.min(1, 1 - left / total)) : -1,
    details: details,
    actions: [{ id: "clear", label: pending.length > 1 ? "Clear all" : "Clear", icon: "\u{f0156}" }],
    signature: next.unit + ":" + pending.length
  }
}

// --- screen recording ---------------------------------------------------------

function recordingActivity(rec, now) {
  if (!rec || !rec.active) return null
  var elapsed = rec.startedAt > 0 ? now - rec.startedAt : 0
  return {
    id: "recording",
    module: "recording",
    priority: PRIORITY.recording,
    icon: "\u{f044a}",
    urgent: true,
    title: "Screen recording",
    subtitle: rec.startedAt > 0 ? formatDuration(elapsed) : "Recording",
    pillText: rec.startedAt > 0 ? formatDuration(elapsed) : "REC",
    progress: -1,
    details: [],
    actions: [{ id: "stop", label: "Stop", icon: "\u{f04db}" }],
    signature: "on"
  }
}

// --- dictation (omarchy-voxtype-status, one JSON object per line) -------------

function parseVoxtype(line) {
  var data
  try { data = JSON.parse(String(line || "")) } catch (e) { return "idle" }
  if (!data || typeof data !== "object") return "idle"
  var state = String(data.alt || data["class"] || "idle")
  return state === "recording" || state === "transcribing" ? state : "idle"
}

function dictationActivity(state) {
  if (state !== "recording" && state !== "transcribing") return null
  var recording = state === "recording"
  return {
    id: "dictation",
    module: "dictation",
    priority: PRIORITY.dictation,
    icon: recording ? "\u{f036c}" : "\u{f051f}",
    urgent: recording,
    title: recording ? "Listening…" : "Transcribing…",
    subtitle: "Dictation",
    pillText: recording ? "Listening" : "Transcribing",
    progress: -1,
    details: [],
    actions: [],
    signature: state
  }
}

// --- privacy: microphone and camera -------------------------------------------

// Output of the camera probe: one process name (/proc/<pid>/comm) per line.
// PipeWire's own daemons hold the device on behalf of portal clients; they
// are dropped from the names (the device still counts as in use).
var CAMERA_DAEMONS = ["pipewire", "wireplumber", "pipewire-media-session"]

function parseVideoUsers(text) {
  var lines = String(text || "").split("\n")
  var seen = {}
  var out = []
  for (var i = 0; i < lines.length && i < 200; i++) {
    var name = clean(lines[i], 40)
    if (!name || seen[name.toLowerCase()]) continue
    seen[name.toLowerCase()] = true
    out.push(name)
  }
  return out
}

function cameraAppNames(users) {
  var out = []
  for (var i = 0; i < (users || []).length; i++)
    if (CAMERA_DAEMONS.indexOf(String(users[i]).toLowerCase()) === -1) out.push(users[i])
  return out
}

function uniqueNames(names) {
  var seen = {}
  var out = []
  for (var i = 0; i < (names || []).length; i++) {
    var n = clean(names[i], 40)
    if (!n || seen[n.toLowerCase()]) continue
    seen[n.toLowerCase()] = true
    out.push(n)
  }
  return out
}

// p = { micApps: [names], micMuted, cameraActive, cameraApps: [names] }
function privacyActivity(p) {
  if (!p) return null
  var mic = (p.micApps || []).length > 0 && !p.micMuted
  var cam = !!p.cameraActive
  if (!mic && !cam) return null
  var micApps = uniqueNames(p.micApps)
  var camApps = uniqueNames(p.cameraApps)
  var what = mic && cam ? "Camera and microphone in use" : (cam ? "Camera in use" : "Microphone in use")
  var apps = uniqueNames((cam ? camApps : []).concat(mic ? micApps : []))
  var details = []
  if (cam) details.push("\u{f0100}  Camera: " + (camApps.length ? camApps.join(", ") : "unknown app"))
  if (mic) details.push("\u{f036c}  Microphone: " + (micApps.length ? micApps.join(", ") : "unknown app"))
  return {
    id: "privacy",
    module: "privacy",
    priority: PRIORITY.privacy,
    icon: cam ? "\u{f0100}" : "\u{f036c}",
    urgent: true,
    title: what,
    subtitle: apps.length ? apps.join(", ") : "",
    pillText: cam && mic ? "Cam + mic" : (cam ? "Camera" : "Mic"),
    progress: -1,
    details: details,
    actions: mic ? [{ id: "muteMic", label: "Mute mic", icon: "\u{f036d}" }] : [],
    signature: (cam ? "c" : "") + (mic ? "m" : "") + ":" + apps.join(",")
  }
}

// --- modes: Do Not Disturb, stay awake, night light ----------------------------

// Output of the modes probe: DND state ("on"/"off"), idle status JSON, night
// light status JSON, Tailscale's BackendState, then `nmcli -t -f NAME,TYPE
// connection show --active`, one connection per line. Missing or broken
// lines count as "off".
function parseModes(text) {
  var lines = String(text || "").split("\n")
  function json(line) {
    try { var v = JSON.parse(line || ""); return v && typeof v === "object" ? v : {} } catch (e) { return {} }
  }
  var idle = json(lines[1])
  var night = json(lines[2])
  var vpns = []
  if (String(lines[3] || "").trim() === "Running") vpns.push({ name: "Tailscale", kind: "tailscale" })
  for (var i = 4; i < lines.length && vpns.length < 6; i++) {
    var c = parseNmcliLine(lines[i])
    if (c && (c.type === "vpn" || c.type === "wireguard")) vpns.push({ name: c.name, raw: c.rawName, kind: "nm" })
  }
  return {
    dnd: String(lines[0] || "").trim() === "on",
    stayAwake: idle.stayAwake === true,
    nightlight: night.enabled === true,
    vpns: vpns
  }
}

// nmcli's terse output escapes ":" and "\\" inside fields with a backslash.
function parseNmcliLine(line) {
  var fields = []
  var cur = ""
  var t = String(line || "")
  for (var i = 0; i < t.length; i++) {
    var ch = t.charAt(i)
    if (ch === "\\" && i + 1 < t.length) { cur += t.charAt(++i); continue }
    if (ch === ":") { fields.push(cur); cur = ""; continue }
    cur += ch
  }
  fields.push(cur)
  if (fields.length < 2 || !fields[0]) return null
  return { name: clean(fields[0], 60), rawName: fields[0], type: fields[fields.length - 1] }
}

function modesActivity(m) {
  var vpns = m && Array.isArray(m.vpns) ? m.vpns : []
  if (!m || !(m.dnd || m.stayAwake || m.nightlight || vpns.length)) return null
  var on = []
  var actions = []
  var details = []
  if (m.dnd) { on.push("Do Not Disturb"); actions.push({ id: "dnd", label: "DND off", icon: "\u{f009b}" }) }
  if (m.stayAwake) { on.push("Stay awake"); actions.push({ id: "stayAwake", label: "Stay awake off", icon: "\u{f0176}" }) }
  if (m.nightlight) { on.push("Night light"); actions.push({ id: "nightlight", label: "Night light off", icon: "\u{f0594}" }) }
  for (var i = 0; i < vpns.length; i++) {
    on.push(vpns.length === 1 ? "VPN " + vpns[i].name : vpns[i].name)
    details.push("\u{f0582}  VPN: " + vpns[i].name)
    // Tailscale may need operator rights to go down: leave it to its own tools.
    if (vpns[i].kind === "nm") actions.push({ id: "vpnDown:" + i, label: "Disconnect " + vpns[i].name, icon: "\u{f0582}" })
  }
  return {
    id: "modes",
    module: "modes",
    priority: PRIORITY.modes,
    icon: m.dnd ? "\u{f009b}" : (m.stayAwake ? "\u{f0176}" : (m.nightlight ? "\u{f0594}" : "\u{f0582}")),
    urgent: false,
    title: on.length === 1 ? on[0] : on.length + " modes on",
    subtitle: on.length === 1 ? "On" : on.join(" · "),
    pillText: on.length === 1 ? on[0] : on.length + " modes",
    progress: -1,
    details: details,
    actions: actions,
    signature: (m.dnd ? "d" : "") + (m.stayAwake ? "s" : "") + (m.nightlight ? "n" : "") + ":" + vpns.map(function(v) { return v.name }).join(",")
  }
}

// --- charging (UPower display device) -----------------------------------------
// b = { present, charging, full, onBattery, percentage (0..1), timeToFull (s) }

function chargingActivity(b) {
  if (!b || !b.present || b.onBattery || !b.charging) return null
  var pct = Math.round(Math.max(0, Math.min(1, num(b.percentage, 0))) * 100)
  var eta = num(b.timeToFull, 0) > 0 ? "Full in " + formatEta(b.timeToFull) : "Charging"
  return {
    id: "charging",
    module: "charging",
    priority: PRIORITY.charging,
    icon: "\u{f0084}",
    urgent: false,
    title: "Charging · " + pct + "%",
    subtitle: eta,
    pillText: pct + "%",
    progress: pct / 100,
    details: [],
    actions: [],
    signature: "charging"
  }
}

// Low battery: on battery and at or below LOW_BATTERY. b also has timeToEmpty (s).
var LOW_BATTERY = 0.15

function batteryActivity(b) {
  if (!b || !b.present || !b.onBattery) return null
  var frac = Math.max(0, Math.min(1, num(b.percentage, 1)))
  if (frac > LOW_BATTERY) return null
  var pct = Math.round(frac * 100)
  var left = num(b.timeToEmpty, 0) > 0 ? formatEta(b.timeToEmpty) + " left" : "Plug in the charger"
  return {
    id: "battery",
    module: "charging",
    priority: PRIORITY.battery,
    icon: pct <= 5 ? "\u{f0083}" : "\u{f007a}",
    urgent: true,
    title: "Battery low \u00b7 " + pct + "%",
    subtitle: left,
    pillText: pct + "% \u00b7 " + (num(b.timeToEmpty, 0) > 0 ? formatEta(b.timeToEmpty) : "low"),
    progress: frac,
    details: [],
    actions: [],
    // Shows up again (after a dismiss) at each 5% step down.
    signature: "low:" + Math.ceil(pct / 5)
  }
}

// --- media (MPRIS) --------------------------------------------------------------
// m = { key, title, artist, player, playing, canPrevious, canNext, canToggle,
//       position (s), length (s), canSeek, volumeSupported, volume (0..1) }
// One activity per player: "media:<key>".

function mediaId(key) {
  return "media:" + String(key || "player").replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 80)
}

function mediaActivity(m) {
  if (!m || !(m.title || m.artist)) return null
  var title = clean(m.title || m.player || "Media")
  var artist = clean(m.artist)
  var player = clean(m.player, 40)
  var actions = []
  if (m.canToggle) actions.push({ id: "playPause", label: m.playing ? "Pause" : "Play", icon: m.playing ? "\u{f03e4}" : "\u{f040a}" })
  if (m.canPrevious) actions.push({ id: "previous", label: "Previous", icon: "\u{f04ae}" })
  if (m.canNext) actions.push({ id: "next", label: "Next", icon: "\u{f04ad}" })
  var len = num(m.length, 0)
  var pos = num(m.position, 0)
  var timed = len > 0 && len < 1e9
  return {
    id: mediaId(m.key),
    module: "media",
    target: String(m.key || ""),
    seekable: timed && !!m.canSeek,
    length: timed ? len : 0,
    volume: m.volumeSupported ? Math.max(0, Math.min(1, num(m.volume, 0))) : -1,
    priority: m.playing ? PRIORITY.mediaPlaying : PRIORITY.mediaPaused,
    icon: m.playing ? "\u{f075a}" : "\u{f03e4}",
    urgent: false,
    title: title,
    subtitle: [artist, player].filter(function(x) { return x }).join(" · "),
    pillText: artist ? title + " · " + artist : title,
    progress: len > 0 && len < 1e9 ? Math.max(0, Math.min(1, pos / len)) : -1,
    details: len > 0 && len < 1e9 ? [formatDuration(pos * 1000) + " / " + formatDuration(len * 1000)] : [],
    actions: actions,
    signature: (m.playing ? "p:" : "s:") + clean(m.key, 80) + ":" + title
  }
}

// --- cover art ---------------------------------------------------------------
// Same rules as omarchy-plugin-media: the URL comes from whatever is playing.

// Host names that point at this machine or the local network.
function isPrivateHost(host) {
  var h = String(host || "").toLowerCase().replace(/\.$/, "")
  if (h === "" || h === "localhost" || h.charAt(0) === "[") return true
  if (/\.(local|localhost|internal|lan|home|corp|intranet)$/.test(h)) return true
  // A host made only of numbers is an IP address. The resolver also takes
  // short, octal and hex spellings ("127.1", "2130706433", "0177.0.0.1",
  // "0x7f.1") that a dotted-quad check would wave through, so anything but
  // the plain four-decimals form counts as internal.
  if (h.split(".").every(function(part) { return /^(\d+|0x[0-9a-f]*)$/.test(part) })) {
    var m = /^(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$/.exec(h)
    if (!m) return true
    var a = parseInt(m[1], 10), b = parseInt(m[2], 10)
    return a === 0 || a === 10 || a === 127 || a >= 224
      || (a === 169 && b === 254)
      || (a === 172 && b >= 16 && b <= 31)
      || (a === 192 && b === 168)
      || (a === 100 && b >= 64 && b <= 127)
      || (a === 198 && (b === 18 || b === 19))
  }
  return false
}

// Cover art URL that is safe to hand to an Image: https to a public host, or
// a local file. Anything else (http, data:, internal hosts...) becomes "".
// Otherwise a web page playing audio could make the shell request any URL.
function safeArtUrl(url) {
  var u = String(url || "")
  if (u === "" || u.length > 2048 || /[\s\u0000-\u001f]/.test(u)) return ""
  if (/^file:\/\/\//i.test(u)) return u
  var m = /^https:\/\/([^\/?#:@]+)(?::(\d{1,5}))?(?:[\/?#]|$)/i.exec(u)
  if (!m) return ""
  return isPrivateHost(m[1]) ? "" : u
}

// --- accent color from the cover ------------------------------------------------
// Input: ImageMagick's `-format %c histogram:info:-` of the (already validated)
// cover, one "count: (r,g,b) #RRGGBB ..." line per color. Output: "#rrggbb", or
// "" when the cover has no real color (black, white, gray), so the theme's
// accent stays.

function parseHistogram(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length && out.length < 64; i++) {
    // #RRGGBB[AA], or #RRRRGGGGBBBB[AAAA] for 16-bit images (high bytes kept).
    var m = /^\s*(\d+):\s*\([^)]*\)\s*#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8}|[0-9A-Fa-f]{12}|[0-9A-Fa-f]{16})\b/.exec(lines[i])
    if (!m) continue
    var hex = m[2]
    var step = hex.length >= 12 ? 4 : 2
    out.push({
      count: parseInt(m[1], 10),
      r: parseInt(hex.slice(0, 2), 16) / 255,
      g: parseInt(hex.slice(step, step + 2), 16) / 255,
      b: parseInt(hex.slice(2 * step, 2 * step + 2), 16) / 255
    })
  }
  return out
}

function rgbToHsl(r, g, b) {
  var max = Math.max(r, g, b)
  var min = Math.min(r, g, b)
  var l = (max + min) / 2
  var d = max - min
  if (d === 0) return { h: 0, s: 0, l: l }
  var s = d / (1 - Math.abs(2 * l - 1))
  var h
  if (max === r) h = ((g - b) / d) % 6
  else if (max === g) h = (b - r) / d + 2
  else h = (r - g) / d + 4
  h = h * 60
  if (h < 0) h += 360
  return { h: h, s: Math.min(1, s), l: l }
}

function hslToHex(h, s, l) {
  var c = (1 - Math.abs(2 * l - 1)) * s
  var x = c * (1 - Math.abs((h / 60) % 2 - 1))
  var m = l - c / 2
  var rgb = h < 60 ? [c, x, 0] : h < 120 ? [x, c, 0] : h < 180 ? [0, c, x]
    : h < 240 ? [0, x, c] : h < 300 ? [x, 0, c] : [c, 0, x]
  return "#" + rgb.map(function(v) {
    var n = Math.round((v + m) * 255)
    return (n < 16 ? "0" : "") + Math.max(0, Math.min(255, n)).toString(16)
  }).join("")
}

var ACCENT_MIN_SATURATION = 0.22

// The most "vivid" color weighted by how much of the cover it covers, then
// brought to a lightness/saturation that reads well on a dark or light bar.
function accentFromHistogram(text) {
  var colors = parseHistogram(text)
  var best = null
  var bestScore = 0
  for (var i = 0; i < colors.length; i++) {
    var c = colors[i]
    var max = Math.max(c.r, c.g, c.b)
    var min = Math.min(c.r, c.g, c.b)
    var sat = max > 0 ? (max - min) / max   // HSV saturation
      : 0
    if (sat < ACCENT_MIN_SATURATION || max < 0.2 || (min > 0.92)) continue
    var score = c.count * sat * sat * max
    if (score > bestScore) { bestScore = score; best = c }
  }
  if (!best) return ""
  var hsl = rgbToHsl(best.r, best.g, best.b)
  return hslToHex(hsl.h, Math.max(0.45, hsl.s), Math.max(0.5, Math.min(0.7, hsl.l)))
}

// The cover's base color: the one covering most of it, a bit in favor of
// colored ones over gray. "" when the histogram is empty or unreadable.
function baseFromHistogram(text) {
  var colors = parseHistogram(text)
  var best = null
  var bestScore = 0
  for (var i = 0; i < colors.length; i++) {
    var c = colors[i]
    var max = Math.max(c.r, c.g, c.b)
    var min = Math.min(c.r, c.g, c.b)
    var sat = max > 0 ? (max - min) / max : 0
    var score = c.count * (0.35 + sat)
    if (score > bestScore) { bestScore = score; best = c }
  }
  if (!best) return ""
  var hsl = rgbToHsl(best.r, best.g, best.b)
  return hslToHex(hsl.h, hsl.s, hsl.l)
}

// A popup background from the cover's base color: same hue, saturation kept
// moderate, and a lightness close to a dark (or light) theme's, so the
// theme's text color stays readable on it.
function surfaceTint(hex, dark) {
  var m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(String(hex || ""))
  if (!m) return ""
  var hsl = rgbToHsl(parseInt(m[1], 16) / 255, parseInt(m[2], 16) / 255, parseInt(m[3], 16) / 255)
  return hslToHex(hsl.h, Math.min(0.55, hsl.s), dark ? 0.17 : 0.91)
}

// --- live updates pushed by scripts (IPC `push <id> <json>`) --------------------
// Text only: nothing in a pushed activity is ever run, opened or rendered as
// markup. Ids are short slugs so they can't collide with built-in modules.

var MAX_PUSHED = 8
var MAX_PUSH_PAYLOAD = 4096
var MAX_PUSH_TTL = 24 * 3600

function validPushId(id) {
  return /^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}$/.test(String(id || ""))
}

// Returns { ok: true, item } or { ok: false, error }. `item` is stored as is
// and turned into an activity by pushActivity().
function sanitizePush(id, payload, now) {
  if (!validPushId(id)) return { ok: false, error: "invalid id (use 1-32 letters, digits, '.', '_' or '-')" }
  var raw = String(payload === undefined || payload === null ? "" : payload)
  if (raw.length > MAX_PUSH_PAYLOAD) return { ok: false, error: "payload too large" }
  var data
  try { data = JSON.parse(raw) } catch (e) { return { ok: false, error: "payload is not valid JSON" } }
  if (!data || typeof data !== "object" || Array.isArray(data)) return { ok: false, error: "payload must be a JSON object" }
  var title = clean(data.title, 80)
  if (!title) return { ok: false, error: "title is required" }
  var progress = data.progress === undefined || data.progress === null ? -1 : num(data.progress, -1)
  if (progress !== -1) progress = Math.max(0, Math.min(1, progress))
  var ttl = Math.floor(num(data.ttl, 0))
  ttl = ttl > 0 ? Math.min(ttl, MAX_PUSH_TTL) : 0
  var priority = data.priority === "high" || data.priority === "low" ? data.priority : "normal"
  // A glyph is at most a couple of code points; anything longer is ignored.
  var icon = clean(data.icon, 4)
  if (Array.from(icon).length > 2) icon = ""
  var state = data.state === "success" || data.state === "error" || data.state === "running" ? data.state : ""
  return {
    ok: true,
    item: {
      id: String(id),
      title: title,
      subtitle: clean(data.subtitle, 120),
      pillText: clean(data.pill || data.title, 40),
      icon: icon,
      progress: progress,
      priority: priority,
      urgent: data.urgent === true || state === "error",
      state: state,
      // "elapsed": true shows the time since the first push with this id.
      startedAt: data.elapsed === true ? now : 0,
      expiresAt: ttl > 0 ? now + ttl * 1000 : 0,
      updatedAt: now
    }
  }
}

// Adds or replaces `item` in `items` (an object keyed by id), dropping the
// oldest entry when over the limit.
function upsertPush(items, item) {
  var next = {}
  var keys = []
  for (var k in items) { next[k] = items[k]; keys.push(k) }
  var prev = items[item.id]
  if (prev && prev.startedAt > 0 && item.startedAt > 0) {
    var kept = {}
    for (var f in item) kept[f] = item[f]
    kept.startedAt = prev.startedAt
    item = kept
  }
  next[item.id] = item
  if (!(item.id in items)) keys.push(item.id)
  while (keys.length > MAX_PUSHED) {
    var oldest = keys[0]
    for (var i = 1; i < keys.length; i++) if (next[keys[i]].updatedAt < next[oldest].updatedAt) oldest = keys[i]
    delete next[oldest]
    keys.splice(keys.indexOf(oldest), 1)
  }
  return next
}

function prunePushes(items, now) {
  var next = {}
  var changed = false
  for (var k in items) {
    var it = items[k]
    if (it.expiresAt > 0 && it.expiresAt <= now) changed = true
    else next[k] = it
  }
  return changed ? next : items
}

var PUSH_STATE_ICON = { running: "\u{f0996}", success: "\u{f05e0}", error: "\u{f0028}" }

function pushActivity(item, now) {
  var elapsed = item.startedAt > 0 ? formatDuration(Math.max(0, (now || item.updatedAt) - item.startedAt)) : ""
  return {
    id: "push:" + item.id,
    module: "push",
    priority: item.priority === "high" ? PRIORITY.pushHigh : (item.priority === "low" ? PRIORITY.pushLow : PRIORITY.push),
    icon: item.icon || PUSH_STATE_ICON[item.state] || "\u{f0996}",
    urgent: item.urgent,
    title: item.title,
    subtitle: elapsed ? (item.subtitle ? item.subtitle + " \u00b7 " : "") + elapsed : item.subtitle,
    pillText: elapsed ? item.pillText + " \u00b7 " + elapsed : item.pillText,
    progress: item.progress,
    details: [],
    actions: [{ id: "remove", label: "Dismiss", icon: "\u{f0156}" }],
    signature: String(item.updatedAt)
  }
}

// --- Bluetooth device just connected (shown for a few seconds) ---------------------
// d = { address, name, battery (0..1, or -1 when unknown) }

var BLUETOOTH_SHOW_MS = 10000

function bluetoothActivity(d) {
  if (!d) return null
  var name = clean(d.name, 60) || "Bluetooth device"
  var hasBattery = num(d.battery, -1) >= 0
  var pct = hasBattery ? Math.round(Math.min(1, d.battery) * 100) : -1
  return {
    id: "bt:" + String(d.address || "").replace(/[^A-Fa-f0-9:]/g, "").slice(0, 17),
    module: "bluetooth",
    priority: PRIORITY.bluetooth,
    icon: "\u{f00b1}",
    urgent: false,
    title: name,
    subtitle: "Connected" + (hasBattery ? " \u00b7 battery " + pct + "%" : ""),
    pillText: hasBattery ? name + " \u00b7 " + pct + "%" : name,
    progress: hasBattery ? pct / 100 : -1,
    details: [],
    actions: [],
    signature: "connected"
  }
}

// --- screenshot just taken (shown for a few seconds) ---------------------------------

var SCREENSHOT_SHOW_MS = 15000

// A file name inotifywait reported in the screenshots folder: a plain name
// (no path, no control characters, not hidden) ending in .png/.jpg/.jpeg.
function validScreenshotName(name) {
  var n = String(name || "")
  return n.length > 0 && n.length <= 200 && n.charAt(0) !== "." && !/[\/\u0000-\u001f\u007f]/.test(n)
    && /\.(png|jpe?g)$/i.test(n)
}

// s = { path, name }
function screenshotActivity(s) {
  if (!s || !s.path) return null
  return {
    id: "screenshot",
    module: "screenshot",
    priority: PRIORITY.screenshot,
    icon: "\u{f0e51}",
    urgent: false,
    image: s.path,
    title: "Screenshot saved",
    subtitle: clean(s.name, 80),
    pillText: "Screenshot",
    progress: -1,
    details: [],
    actions: [
      { id: "edit", label: "Edit", icon: "\u{f03eb}" },
      { id: "copy", label: "Copy", icon: "\u{f018f}" },
      { id: "open", label: "Open", icon: "\u{f03cc}" }
    ],
    signature: clean(s.name, 80)
  }
}

// --- weather (the Now Brief) ----------------------------------------------------------
// A card that is always in the carousel (when there is data) but never takes
// the pill from a live activity: it is "ambient". The pill shows it only when
// nothing else is going on, as the Now Brief.

// wttr.in weather codes -> Nerd Font glyphs; same mapping as Omarchy's weather
// panel (plugins/panels/weather/Model.js).
function weatherIcon(code, night) {
  var c = parseInt(String(code || "0"), 10)
  switch (c) {
    case 113: return night ? "\u{e32b}" : "\u{e30d}"
    case 116: return night ? "\u{e32e}" : "\u{e302}"
    case 119: case 122: return "\u{e33d}"
    case 143: case 248: case 260: return night ? "\u{e346}" : "\u{e313}"
    case 176: case 263: case 353: return night ? "\u{e333}" : "\u{e308}"
    case 179: case 227: case 230: case 323: case 326: case 368: return night ? "\u{e327}" : "\u{e30a}"
    case 182: case 185: case 281: case 284: case 311: case 314:
    case 317: case 320: case 350: case 362: case 365: case 374: case 377: return "\u{e3ad}"
    case 200: case 386: case 389: case 392: case 395: return "\u{e31d}"
    case 266: case 293: case 296: case 299: case 302: case 305: case 308: case 356: case 359: return "\u{e318}"
    case 329: case 332: case 335: case 338: case 371: return "\u{e31a}"
    default: return "\u{e33d}"
  }
}

// The color of the sky for a condition: drives the card's accent and the
// popup's tint, like a cover does for media.
function weatherColor(code, night) {
  var c = parseInt(String(code || "0"), 10)
  if (c === 200 || (c >= 386 && c <= 395)) return "#7b5cd6"                       // storm
  if ([179, 227, 230, 323, 326, 329, 332, 335, 338, 368, 371].indexOf(c) !== -1) return "#9cc3e6" // snow
  if ([182, 185, 281, 284, 311, 314, 317, 320, 350, 362, 365, 374, 377].indexOf(c) !== -1) return "#7fa7c9" // sleet
  if ([176, 263, 266, 293, 296, 299, 302, 305, 308, 353, 356, 359].indexOf(c) !== -1) return "#3d8fe0" // rain
  if (c === 143 || c === 248 || c === 260) return "#8e9aa8"                        // fog
  if (c === 119 || c === 122) return night ? "#5a6a8f" : "#7d8ea6"               // cloudy
  if (c === 116) return night ? "#4b5fb5" : "#e8b04a"                             // partly cloudy
  return night ? "#4a56c8" : "#f2a33a"                                             // clear
}

// "05:19 AM" -> minutes since midnight (or -1).
function clockMinutes(text) {
  var m = /^(\d{1,2}):(\d{2})\s*(AM|PM)?$/i.exec(String(text || "").trim())
  if (!m) return -1
  var h = parseInt(m[1], 10) % 12
  if (!m[3]) h = parseInt(m[1], 10)
  else if (m[3].toUpperCase() === "PM") h += 12
  var min = parseInt(m[2], 10)
  return h > 23 || min > 59 ? -1 : h * 60 + min
}

function clockLabel(minutes) {
  return minutes < 0 ? "" : Math.floor(minutes / 60) + ":" + pad2(minutes % 60)
}

// °C or °F: an explicit choice, else the country of the forecast, else the
// locale. Same rules as Omarchy's weather panel.
function useImperial(unit, localeName, country) {
  if (unit === "imperial") return true
  if (unit === "metric") return false
  var c = String(country || "").trim().replace(/[._-]+/g, " ").toLowerCase()
  if (c) return ["us", "usa", "united states", "united states of america", "liberia", "myanmar", "burma"].indexOf(c) !== -1
  var name = String(localeName || "").replace(".", "_")
  return /^en[_-]US($|[_.-])/.test(name) || /^en[_-]LR($|[_.-])/.test(name) || /^my($|[_.-])/.test(name)
}

var DAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

// wttr.in's ?format=j1 answer -> what the card shows, or null when it can't be
// read. `now` is epoch ms (local time decides "now", night and day names);
// `opts` = { unit: "auto"|"metric"|"imperial", locale }.
function parseWttr(text, now, opts) {
  var data
  try { data = JSON.parse(String(text || "")) } catch (e) { return null }
  var cur = data && Array.isArray(data.current_condition) ? data.current_condition[0] : null
  var days = data && Array.isArray(data.weather) ? data.weather : []
  if (!cur || typeof cur !== "object" || days.length === 0) return null
  var o = opts || {}
  var area = data.nearest_area && data.nearest_area[0] ? data.nearest_area[0] : {}
  function val(v) { return v && v[0] ? v[0].value : "" }
  var country = clean(val(area.country), 40)
  var imperial = useImperial(o.unit, o.locale, country)
  function temp(c, f) {
    var n = parseFloat(imperial ? f : c)
    return isFinite(n) ? Math.round(n) : null
  }
  var t = temp(cur.temp_C, cur.temp_F)
  if (t === null) return null

  var d = new Date(now)
  var nowMin = d.getHours() * 60 + d.getMinutes()
  var astro = days[0].astronomy && days[0].astronomy[0] ? days[0].astronomy[0] : {}
  var sunrise = clockMinutes(astro.sunrise)
  var sunset = clockMinutes(astro.sunset)
  var night = sunrise >= 0 && sunset >= 0 ? (nowMin < sunrise || nowMin >= sunset) : false

  // Next hours: wttr gives 3-hour slots per day; take the 8 starting with
  // the slot we are in.
  var hours = []
  for (var di = 0; di < days.length && hours.length < 8; di++) {
    var hourly = Array.isArray(days[di].hourly) ? days[di].hourly : []
    var dAstro = days[di].astronomy && days[di].astronomy[0] ? days[di].astronomy[0] : {}
    var dRise = clockMinutes(dAstro.sunrise)
    var dSet = clockMinutes(dAstro.sunset)
    for (var hi = 0; hi < hourly.length && hours.length < 8; hi++) {
      var h = hourly[hi]
      var slot = Math.floor(num(h.time, -1) / 100)
      if (slot < 0 || slot > 23) continue
      if (di === 0 && (slot + 3) * 60 <= nowMin) continue
      var slotNight = dRise >= 0 && dSet >= 0 ? (slot * 60 < dRise || slot * 60 >= dSet) : false
      var ht = temp(h.tempC, h.tempF)
      if (ht === null) continue
      hours.push({
        label: hours.length === 0 ? "Now" : pad2(slot) + "h",
        icon: weatherIcon(h.weatherCode, slotNight),
        temp: ht,
        rain: Math.max(0, Math.min(100, Math.round(num(h.chanceofrain, 0))))
      })
    }
  }

  // "Now" is the current reading, not the slot's forecast.
  if (hours.length) {
    hours[0].temp = t
    hours[0].icon = weatherIcon(cur.weatherCode, night)
  }

  var forecast = []
  for (var k = 0; k < days.length && k < 3; k++) {
    var day = days[k]
    var hs = Array.isArray(day.hourly) ? day.hourly : []
    var mid = hs.length ? hs[Math.min(4, hs.length - 1)] : null   // around noon
    var rain = 0
    for (var r = 0; r < hs.length; r++) rain = Math.max(rain, Math.round(num(hs[r].chanceofrain, 0)))
    var date = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(day.date || ""))
    var name = k === 0 ? "Today" : (k === 1 ? "Tomorrow"
      : (date ? DAY_NAMES[new Date(parseInt(date[1], 10), parseInt(date[2], 10) - 1, parseInt(date[3], 10)).getDay()] : ""))
    var lo = temp(day.mintempC, day.mintempF)
    var hi2 = temp(day.maxtempC, day.maxtempF)
    if (lo === null || hi2 === null) continue
    forecast.push({ name: name, icon: weatherIcon(mid ? mid.weatherCode : cur.weatherCode, false), min: lo, max: hi2, rain: Math.max(0, Math.min(100, rain)) })
  }

  var windKmh = Math.round(num(cur.windspeedKmph, 0))
  var windMph = Math.round(num(cur.windspeedMiles, windKmh / 1.609))
  var feels = temp(cur.FeelsLikeC, cur.FeelsLikeF)
  return {
    temp: t,
    unit: imperial ? "°F" : "°C",
    feels: feels === null ? t : feels,
    desc: clean(val(cur.weatherDesc), 40),
    code: parseInt(String(cur.weatherCode || "0"), 10) || 0,
    night: night,
    icon: weatherIcon(cur.weatherCode, night),
    color: weatherColor(cur.weatherCode, night),
    humidity: Math.max(0, Math.min(100, Math.round(num(cur.humidity, 0)))),
    wind: (imperial ? windMph + " mph" : windKmh + " km/h") + (cur.winddir16Point ? " " + clean(cur.winddir16Point, 4) : ""),
    uv: Math.max(0, Math.round(num(cur.uvIndex, 0))),
    location: clean(val(area.areaName), 40),
    sunrise: clockLabel(sunrise),
    sunset: clockLabel(sunset),
    hours: hours,
    days: forecast
  }
}

// The weather card (ambient). w: parseWttr() result or null; update: whether
// an Omarchy update is available (told on the card and in the pill).
function weatherActivity(w, update) {
  if (!w && !update) return null
  var details = update ? ["\u{f06b0}  Omarchy update available"] : []
  if (!w) {
    return {
      id: "brief", module: "weather", ambient: true, priority: PRIORITY.brief,
      icon: "\u{f06b0}", urgent: false, title: "Update available", subtitle: "Omarchy",
      pillText: "Update available", progress: -1, details: [], actions: [], signature: "update"
    }
  }
  var today = w.days.length ? w.days[0] : null
  var pill = w.temp + "°" + (w.desc ? " · " + w.desc : "")
  return {
    id: "brief",
    module: "weather",
    ambient: true,
    priority: PRIORITY.brief,
    icon: w.icon,
    color: w.color,
    urgent: false,
    weather: w,
    title: w.temp + w.unit + (w.desc ? " · " + w.desc : ""),
    subtitle: [w.location, today ? "H " + today.max + "° L " + today.min + "°" : ""].filter(function(x) { return x }).join(" · "),
    pillText: update ? pill + "  ·  \u{f06b0} Update" : pill,
    progress: -1,
    details: details,
    actions: [],
    signature: "weather"
  }
}

// --- list & focus -----------------------------------------------------------------

function sortActivities(list) {
  var out = (list || []).filter(function(a) { return !!a })
  out.sort(function(a, b) {
    if (a.priority !== b.priority) return a.priority - b.priority
    return a.id < b.id ? -1 : (a.id > b.id ? 1 : 0)
  })
  return out
}

// Drops activities whose module is turned off, and dismissed ones whose state
// hasn't changed since. `dismissed` is { activityId: signature }.
function visibleActivities(list, prefs, dismissed) {
  var out = []
  for (var i = 0; i < (list || []).length; i++) {
    var a = list[i]
    if (!a) continue
    if (prefs && prefs.modules && prefs.modules[a.module] === false) continue
    if (dismissed && dismissed[a.id] !== undefined && dismissed[a.id] === a.signature) continue
    out.push(a)
  }
  return sortActivities(out)
}

// Forget dismissals of activities that are gone or changed state, so a new
// recording or a new timer shows up again.
function pruneDismissed(dismissed, list) {
  var sig = {}
  for (var i = 0; i < (list || []).length; i++) if (list[i]) sig[list[i].id] = list[i].signature
  var next = {}
  var changed = false
  for (var k in dismissed) {
    if (sig[k] !== undefined && sig[k] === dismissed[k]) next[k] = dismissed[k]
    else changed = true
  }
  return changed ? next : dismissed
}

function indexOfId(list, id) {
  for (var i = 0; i < (list || []).length; i++) if (list[i].id === id) return i
  return -1
}

function nextIndex(length, index, delta) {
  if (!(length > 0)) return -1
  var i = index >= 0 && index < length ? index : 0
  return ((i + delta) % length + length) % length
}

// Which activity has the focus after the list changed.
//   s = { list, focusId, knownIds: {id: true}, autoFocus, manualUntil, now }
// A newcomer (an id not in knownIds) takes the focus when autoFocus is on and
// the user hasn't switched by hand in the last few seconds, as long as it is
// at least as important as the current one. Otherwise the focus stays on the
// same id; if that one is gone, it goes to the most important activity.
function resolveFocus(s) {
  var list = s.list || []
  if (list.length === 0) return ""
  var current = indexOfId(list, s.focusId)
  if (s.autoFocus && !(s.now < s.manualUntil)) {
    for (var i = 0; i < list.length; i++) {
      var a = list[i]
      if (s.knownIds && s.knownIds[a.id]) continue
      if (current === -1 || a.priority <= list[current].priority) return a.id
    }
  }
  return current === -1 ? list[0].id : s.focusId
}

// --- bar widget preferences -----------------------------------------------------------

var MODULES = ["media", "timer", "reminders", "recording", "dictation", "privacy", "modes", "charging", "push", "bluetooth", "screenshot", "weather"]

// The popup's Quick toggles and Quick start extras, in the order shown.
var QUICK_TOGGLES = ["dnd", "nightlight", "stayAwake", "record", "reminder", "dictation"]
var QUICK_START_EXTRAS = ["stopwatch", "pomodoro", "sleep"]

// "a,b,c" -> the known ids it names, in the canonical order. A missing value
// means all of them; an empty one means none.
function parseIdList(text, allowed) {
  if (text === undefined || text === null) return allowed.slice()
  var wanted = String(text).split(",").map(function(x) { return x.trim() })
  return allowed.filter(function(id) { return wanted.indexOf(id) !== -1 })
}

// The list with `id` turned on or off, as the "a,b,c" string stored in settings.
function toggleIdList(list, allowed, id, on) {
  var next = allowed.filter(function(x) { return x === id ? on : list.indexOf(x) !== -1 })
  return next.join(",")
}

function defaultPrefs() {
  return {
    moduleMedia: true,
    moduleTimer: true,      // timer and stopwatch
    moduleReminders: true,
    moduleRecording: true,
    moduleDictation: true,
    modulePrivacy: true,
    moduleModes: true,
    moduleCharging: true,
    modulePush: true,
    moduleBluetooth: true,
    moduleScreenshot: true,
    moduleWeather: true,
    weatherUnit: "auto",    // "auto" (country, then locale), "metric" or "imperial"
    autoFocus: true,        // a new activity takes the pill
    whenEmpty: "brief",     // "brief": weather/next reminder/updates; "icon": empty pill; "hide": no pill
    showProgress: true,     // thin progress line under the pill text
    showCount: true,        // "2/4" when there is more than one activity
    showQuickToggles: true, // the popup's Quick toggles (DND, night light, stay awake...)
    quickToggleItems: QUICK_TOGGLES.join(","),       // which of them
    showQuickStart: true,   // the popup's Quick start (timers, stopwatch, Pomodoro, sleep)
    quickStartItems: QUICK_START_EXTRAS.join(","),   // which extras, besides the timers
    coverAccent: true,      // media: accent color taken from the cover art
    textMode: "scroll",     // text longer than the pill: "scroll" (marquee) or "ellipsis" (cut with ...)
    maxWidth: 220,          // width of the text area: the pill always has this size
    timerPresets: DEFAULT_PRESETS, // quick start timers, minutes
    pomodoroFocus: 25,
    pomodoroBreak: 5,
    pomodoroLongBreak: 15
  }
}

function moduleKey(module) {
  return "module" + module.charAt(0).toUpperCase() + module.slice(1)
}

function clampInt(value, min, max, fallback) {
  var n = parseInt(value, 10)
  if (isNaN(n)) return fallback
  return Math.max(min, Math.min(max, n))
}

function normalizePrefs(input) {
  var d = defaultPrefs()
  var src = input && typeof input === "object" ? input : {}
  var out = {}
  for (var k in d) if (typeof d[k] === "boolean") out[k] = typeof src[k] === "boolean" ? src[k] : d[k]
  out.whenEmpty = src.whenEmpty === "hide" || src.whenEmpty === "icon" ? src.whenEmpty : "brief"
  out.textMode = src.textMode === "ellipsis" ? "ellipsis" : "scroll"
  out.weatherUnit = src.weatherUnit === "metric" || src.weatherUnit === "imperial" ? src.weatherUnit : "auto"
  out.maxWidth = clampInt(src.maxWidth, 80, 600, d.maxWidth)
  var presets = parsePresets(src.timerPresets === undefined ? d.timerPresets : src.timerPresets)
  out.timerPresets = presets.map(function(x) { return x / 60 }).join(",")
  out.presetSeconds = presets
  out.pomodoroFocus = clampInt(src.pomodoroFocus, 1, 180, d.pomodoroFocus)
  out.pomodoroBreak = clampInt(src.pomodoroBreak, 1, 60, d.pomodoroBreak)
  out.pomodoroLongBreak = clampInt(src.pomodoroLongBreak, 1, 120, d.pomodoroLongBreak)
  out.quickToggles = parseIdList(src.quickToggleItems, QUICK_TOGGLES)
  out.quickToggleItems = out.quickToggles.join(",")
  out.quickStartExtras = parseIdList(src.quickStartItems, QUICK_START_EXTRAS)
  out.quickStartItems = out.quickStartExtras.join(",")
  out.modules = {}
  for (var i = 0; i < MODULES.length; i++) out.modules[MODULES[i]] = out[moduleKey(MODULES[i])]
  return out
}

// What to store on the widget's entry in shell.json: only the options that
// differ from the defaults, plus any keys of the existing entry that aren't
// ours (so settings we don't know about are never dropped).
function entrySettings(prefs, existing) {
  var d = defaultPrefs()
  var out = {}
  var src = existing && typeof existing === "object" ? existing : {}
  for (var k in src) if (!(k in d) && k !== "id") out[k] = src[k]
  for (var name in d) if (prefs[name] !== d[name]) out[name] = prefs[name]
  return out
}

function tooltipLabel(activity, index, count) {
  if (!activity) return "Now Bar · nothing going on"
  var lines = [activity.title]
  if (activity.subtitle) lines.push(activity.subtitle)
  if (count > 1) lines.push((index + 1) + "/" + count + " · scroll to switch")
  return lines.join("\n")
}

if (typeof module !== "undefined") {
  module.exports = {
    clean: clean,
    formatDuration: formatDuration,
    formatCountdown: formatCountdown,
    formatEta: formatEta,
    presetLabel: presetLabel,
    parseTimerArg: parseTimerArg,
    parsePresets: parsePresets,
    idlePomodoro: idlePomodoro,
    pomodoroConfig: pomodoroConfig,
    startPomodoro: startPomodoro,
    normalizePomodoro: normalizePomodoro,
    pausePomodoro: pausePomodoro,
    resumePomodoro: resumePomodoro,
    nextPomodoro: nextPomodoro,
    pomodoroActivity: pomodoroActivity,
    idleSleep: idleSleep,
    normalizeSleep: normalizeSleep,
    sleepActivity: sleepActivity,
    parseNmcliLine: parseNmcliLine,
    batteryActivity: batteryActivity,
    mediaId: mediaId,
    bluetoothActivity: bluetoothActivity,
    validScreenshotName: validScreenshotName,
    screenshotActivity: screenshotActivity,
    weatherIcon: weatherIcon,
    weatherColor: weatherColor,
    clockMinutes: clockMinutes,
    useImperial: useImperial,
    parseWttr: parseWttr,
    weatherActivity: weatherActivity,
    PRIORITY: PRIORITY,
    idleTimer: idleTimer,
    idleStopwatch: idleStopwatch,
    normalizeTimer: normalizeTimer,
    normalizeStopwatch: normalizeStopwatch,
    startTimer: startTimer,
    timerRemaining: timerRemaining,
    pauseTimer: pauseTimer,
    resumeTimer: resumeTimer,
    extendTimer: extendTimer,
    timerFinished: timerFinished,
    stopwatchElapsed: stopwatchElapsed,
    startStopwatch: startStopwatch,
    pauseStopwatch: pauseStopwatch,
    resumeStopwatch: resumeStopwatch,
    lapStopwatch: lapStopwatch,
    timerActivity: timerActivity,
    stopwatchActivity: stopwatchActivity,
    parseReminders: parseReminders,
    remindersActivity: remindersActivity,
    recordingActivity: recordingActivity,
    parseVoxtype: parseVoxtype,
    dictationActivity: dictationActivity,
    parseVideoUsers: parseVideoUsers,
    cameraAppNames: cameraAppNames,
    privacyActivity: privacyActivity,
    parseModes: parseModes,
    modesActivity: modesActivity,
    chargingActivity: chargingActivity,
    mediaActivity: mediaActivity,
    isPrivateHost: isPrivateHost,
    safeArtUrl: safeArtUrl,
    parseHistogram: parseHistogram,
    accentFromHistogram: accentFromHistogram,
    baseFromHistogram: baseFromHistogram,
    surfaceTint: surfaceTint,
    validPushId: validPushId,
    sanitizePush: sanitizePush,
    upsertPush: upsertPush,
    prunePushes: prunePushes,
    pushActivity: pushActivity,
    sortActivities: sortActivities,
    visibleActivities: visibleActivities,
    pruneDismissed: pruneDismissed,
    indexOfId: indexOfId,
    nextIndex: nextIndex,
    resolveFocus: resolveFocus,
    MODULES: MODULES,
    defaultPrefs: defaultPrefs,
    moduleKey: moduleKey,
    normalizePrefs: normalizePrefs,
    entrySettings: entrySettings,
    tooltipLabel: tooltipLabel,
    QUICK_TOGGLES: QUICK_TOGGLES,
    QUICK_START_EXTRAS: QUICK_START_EXTRAS,
    parseIdList: parseIdList,
    toggleIdList: toggleIdList
  }
}
