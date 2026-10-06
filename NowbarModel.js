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
  var t = String(value === undefined || value === null ? "" : value)
  t = t.replace(/[\u0000-\u001f\u007f-\u009f‎‏‪-‮⁦-⁩]/g, " ")
  t = t.replace(/\s+/g, " ").trim()
  var limit = max || MAX_FIELD_CHARS
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

// --- priorities --------------------------------------------------------------
// Lower comes first. Privacy and recording win because they're things the
// user must not miss; paused media is the least interesting thing to show.

var PRIORITY = {
  privacy: 10,
  recording: 20,
  dictation: 30,
  pushHigh: 35,
  timer: 40,
  reminderSoon: 45,
  stopwatch: 50,
  mediaPlaying: 60,
  push: 65,
  reminder: 75,
  charging: 80,
  pushLow: 85,
  modes: 90,
  mediaPaused: 95
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

// Output of the modes probe, three lines: DND state ("on"/"off"), idle status
// JSON, night light status JSON. Missing or broken lines count as "off".
function parseModes(text) {
  var lines = String(text || "").split("\n")
  function json(line) {
    try { var v = JSON.parse(line || ""); return v && typeof v === "object" ? v : {} } catch (e) { return {} }
  }
  var idle = json(lines[1])
  var night = json(lines[2])
  return {
    dnd: String(lines[0] || "").trim() === "on",
    stayAwake: idle.stayAwake === true,
    nightlight: night.enabled === true
  }
}

function modesActivity(m) {
  if (!m || !(m.dnd || m.stayAwake || m.nightlight)) return null
  var on = []
  var actions = []
  if (m.dnd) { on.push("Do Not Disturb"); actions.push({ id: "dnd", label: "DND off", icon: "\u{f009b}" }) }
  if (m.stayAwake) { on.push("Stay awake"); actions.push({ id: "stayAwake", label: "Stay awake off", icon: "\u{f0176}" }) }
  if (m.nightlight) { on.push("Night light"); actions.push({ id: "nightlight", label: "Night light off", icon: "\u{f0594}" }) }
  return {
    id: "modes",
    module: "modes",
    priority: PRIORITY.modes,
    icon: m.dnd ? "\u{f009b}" : (m.stayAwake ? "\u{f0176}" : "\u{f0594}"),
    urgent: false,
    title: on.length === 1 ? on[0] : on.length + " modes on",
    subtitle: on.length === 1 ? "On" : on.join(" · "),
    pillText: on.length === 1 ? on[0] : on.length + " modes",
    progress: -1,
    details: [],
    actions: actions,
    signature: (m.dnd ? "d" : "") + (m.stayAwake ? "s" : "") + (m.nightlight ? "n" : "")
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

// --- media (MPRIS) --------------------------------------------------------------
// m = { key, title, artist, player, playing, canPrevious, canNext, canToggle,
//       position (s), length (s) }

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
  return {
    id: "media",
    module: "media",
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
      urgent: data.urgent === true,
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

function pushActivity(item) {
  return {
    id: "push:" + item.id,
    module: "push",
    priority: item.priority === "high" ? PRIORITY.pushHigh : (item.priority === "low" ? PRIORITY.pushLow : PRIORITY.push),
    icon: item.icon || "\u{f0996}",
    urgent: item.urgent,
    title: item.title,
    subtitle: item.subtitle,
    pillText: item.pillText,
    progress: item.progress,
    details: [],
    actions: [{ id: "remove", label: "Dismiss", icon: "\u{f0156}" }],
    signature: String(item.updatedAt)
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

var MODULES = ["media", "timer", "reminders", "recording", "dictation", "privacy", "modes", "charging", "push"]

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
    autoFocus: true,        // a new activity takes the pill
    whenEmpty: "icon",      // "icon" keeps a small pill to open the popup; "hide" hides it
    showProgress: true,     // thin progress line under the pill text
    showCount: true,        // "2/4" when there is more than one activity
    textMode: "scroll",     // text longer than the pill: "scroll" (marquee) or "ellipsis" (cut with ...)
    maxWidth: 220           // width of the text area: the pill always has this size
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
  out.whenEmpty = src.whenEmpty === "hide" ? "hide" : "icon"
  out.textMode = src.textMode === "ellipsis" ? "ellipsis" : "scroll"
  out.maxWidth = clampInt(src.maxWidth, 80, 600, d.maxWidth)
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
    tooltipLabel: tooltipLabel
  }
}
