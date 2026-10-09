const test = require("node:test")
const assert = require("node:assert/strict")
const M = require("../NowbarModel.js")

test("clean strips control characters and caps length", () => {
  assert.equal(M.clean("a\nb\u001b[31mc‮d"), "a b [31mc d")
  assert.equal(M.clean(null), "")
  assert.equal(M.clean("x".repeat(500)).length, 120)
  assert.equal(M.clean("abcdef", 4), "abc…")
})

test("formatDuration / formatCountdown / formatEta", () => {
  assert.equal(M.formatDuration(0), "0:00")
  assert.equal(M.formatDuration(65000), "1:05")
  assert.equal(M.formatDuration(3723000), "1:02:03")
  assert.equal(M.formatDuration(-5), "0:00")
  assert.equal(M.formatCountdown(400), "0:01")
  assert.equal(M.formatEta(40), "<1m")
  assert.equal(M.formatEta(5400), "1h 30m")
  assert.equal(M.formatEta(300), "5m")
  assert.equal(M.presetLabel(300), "5 min")
  assert.equal(M.presetLabel(5400), "1 h 30 min")
  assert.equal(M.presetLabel(90), "1 min 30 s")
  assert.equal(M.presetLabel(45), "45 s")
})

test("timer lifecycle", () => {
  let t = M.startTimer(60, 1000)
  assert.equal(t.state, "running")
  assert.equal(M.timerRemaining(t, 31000), 30000)
  t = M.pauseTimer(t, 31000)
  assert.equal(t.state, "paused")
  assert.equal(M.timerRemaining(t, 999999), 30000)
  t = M.resumeTimer(t, 100000)
  assert.equal(t.endsAt, 130000)
  t = M.extendTimer(t, 60, 100000)
  assert.equal(M.timerRemaining(t, 100000), 90000)
  assert.equal(t.durationMs, 90000)
  assert.equal(M.timerFinished(t, 189999), false)
  assert.equal(M.timerFinished(t, 190000), true)
  assert.equal(M.startTimer(0, 0).state, "idle")
  assert.equal(M.startTimer("abc", 0).state, "idle")
  assert.equal(M.startTimer(1e9, 0).durationMs, 24 * 3600 * 1000)
})

test("timer activity reflects running and paused", () => {
  const running = M.timerActivity(M.startTimer(300, 0), 60000)
  assert.equal(running.pillText, "4:00")
  assert.equal(running.actions[0].id, "pause")
  assert.ok(Math.abs(running.progress - 0.2) < 1e-9)
  const paused = M.timerActivity(M.pauseTimer(M.startTimer(300, 0), 60000), 60000)
  assert.equal(paused.actions[0].id, "resume")
  assert.notEqual(running.signature, paused.signature)
  assert.equal(M.timerActivity(M.idleTimer(), 0), null)
})

test("normalizeTimer / normalizeStopwatch reject garbage", () => {
  assert.equal(M.normalizeTimer({ state: "running", durationMs: "x" }).state, "idle")
  assert.equal(M.normalizeTimer("nope").state, "idle")
  const t = M.normalizeTimer({ state: "paused", durationMs: 1000, remainingMs: 5000 })
  assert.equal(t.remainingMs, 1000)
  const s = M.normalizeStopwatch({ state: "running", startedAt: 5, accumulatedMs: 10, laps: [1, "x", -3, 4] })
  assert.deepEqual(s.laps, [1, 4])
  assert.equal(M.normalizeStopwatch({ state: "weird" }).state, "idle")
})

test("stopwatch with laps", () => {
  let s = M.startStopwatch(0)
  s = M.lapStopwatch(s, 10000)
  s = M.lapStopwatch(s, 25000)
  assert.deepEqual(s.laps, [10000, 25000])
  s = M.pauseStopwatch(s, 30000)
  assert.equal(M.stopwatchElapsed(s, 99999), 30000)
  s = M.resumeStopwatch(s, 40000)
  assert.equal(M.stopwatchElapsed(s, 45000), 35000)
  const a = M.stopwatchActivity(s, 45000)
  assert.equal(a.pillText, "0:35")
  assert.equal(a.details[0], "Lap 2  0:15  (0:25)")
  assert.equal(a.details[1], "Lap 1  0:10  (0:10)")
})

test("parseReminders tolerates junk and sorts by time", () => {
  assert.deepEqual(M.parseReminders("not json"), [])
  assert.deepEqual(M.parseReminders('{"reminders": 3}'), [])
  const list = M.parseReminders(JSON.stringify({
    reminders: [
      { unit: "b", label: "Later", at: 2000, minutes: 10 },
      { unit: "a", label: "Soon\nfake line", at: 1000, minutes: 5 },
      { unit: "c", label: "Broken", at: "x" }
    ]
  }))
  assert.equal(list.length, 2)
  assert.equal(list[0].unit, "a")
  assert.equal(list[0].label, "Soon fake line")
  assert.equal(list[0].at, 1000000)
})

test("reminders activity: soon ones get a higher priority", () => {
  const now = 0
  const reminders = [{ unit: "a", label: "Tea", at: 4 * 60000, minutes: 5 }, { unit: "b", label: "Call", at: 30 * 60000, minutes: 30 }]
  const a = M.remindersActivity(reminders, now)
  assert.equal(a.priority, M.PRIORITY.reminderSoon)
  assert.equal(a.title, "Tea")
  assert.match(a.subtitle, /\+1 more/)
  assert.equal(a.details.length, 1)
  const later = M.remindersActivity([reminders[1]], now)
  assert.equal(later.priority, M.PRIORITY.reminder)
  assert.equal(M.remindersActivity([{ unit: "x", label: "Past", at: -1, minutes: 1 }], now), null)
})

test("parseVoxtype", () => {
  assert.equal(M.parseVoxtype('{"alt":"recording"}'), "recording")
  assert.equal(M.parseVoxtype('{"class":"transcribing"}'), "transcribing")
  assert.equal(M.parseVoxtype('{"alt":"","class":"idle"}'), "idle")
  assert.equal(M.parseVoxtype('{"alt":"rm -rf"}'), "idle")
  assert.equal(M.parseVoxtype("garbage"), "idle")
  assert.equal(M.dictationActivity("idle"), null)
  assert.equal(M.dictationActivity("recording").urgent, true)
})

test("camera users: unique, cleaned, daemons hidden from names", () => {
  const users = M.parseVideoUsers("pipewire\nfirefox\nfirefox\n\nbad\u001bname\n")
  assert.deepEqual(users, ["pipewire", "firefox", "bad name"])
  assert.deepEqual(M.cameraAppNames(users), ["firefox", "bad name"])
})

test("privacy activity combines camera and microphone", () => {
  assert.equal(M.privacyActivity({ micApps: [], cameraActive: false }), null)
  assert.equal(M.privacyActivity({ micApps: ["Zoom"], micMuted: true, cameraActive: false }), null)
  const mic = M.privacyActivity({ micApps: ["Zoom", "Zoom"], micMuted: false, cameraActive: false, cameraApps: [] })
  assert.equal(mic.title, "Microphone in use")
  assert.equal(mic.subtitle, "Zoom")
  assert.equal(mic.actions[0].id, "muteMic")
  const both = M.privacyActivity({ micApps: ["Zoom"], micMuted: false, cameraActive: true, cameraApps: ["zoom", "obs"] })
  assert.equal(both.title, "Camera and microphone in use")
  assert.equal(both.subtitle, "zoom, obs")
  assert.equal(both.details.length, 2)
  const cam = M.privacyActivity({ micApps: [], cameraActive: true, cameraApps: [] })
  assert.equal(cam.title, "Camera in use")
  assert.deepEqual(cam.actions, [])
  assert.match(cam.details[0], /unknown app/)
})

test("modes", () => {
  assert.deepEqual(M.parseModes('on\n{"stayAwake":true}\n{"enabled":false}'), { dnd: true, stayAwake: true, nightlight: false, vpns: [] })
  assert.deepEqual(M.parseModes(""), { dnd: false, stayAwake: false, nightlight: false, vpns: [] })
  assert.deepEqual(M.parseModes("off\nnot json\n[1]"), { dnd: false, stayAwake: false, nightlight: false, vpns: [] })
  assert.equal(M.modesActivity({ dnd: false, stayAwake: false, nightlight: false }), null)
  const one = M.modesActivity({ dnd: true, stayAwake: false, nightlight: false })
  assert.equal(one.title, "Do Not Disturb")
  const two = M.modesActivity({ dnd: true, stayAwake: true, nightlight: false })
  assert.equal(two.title, "2 modes on")
  assert.deepEqual(two.actions.map((a) => a.id), ["dnd", "stayAwake"])
})

test("charging only while plugged in and charging", () => {
  assert.equal(M.chargingActivity({ present: true, charging: false, onBattery: false }), null)
  assert.equal(M.chargingActivity({ present: true, charging: true, onBattery: true }), null)
  const a = M.chargingActivity({ present: true, charging: true, onBattery: false, percentage: 0.634, timeToFull: 4800 })
  assert.equal(a.title, "Charging · 63%")
  assert.equal(a.subtitle, "Full in 1h 20m")
})

test("media activity", () => {
  assert.equal(M.mediaActivity({ title: "", artist: "" }), null)
  const a = M.mediaActivity({ key: "spotify", title: "Song", artist: "Band", player: "Spotify", playing: true, canToggle: true, canNext: true, canPrevious: true, position: 30, length: 120 })
  assert.equal(a.priority, M.PRIORITY.mediaPlaying)
  assert.equal(a.pillText, "Song · Band")
  assert.equal(a.progress, 0.25)
  assert.deepEqual(a.actions.map((x) => x.id), ["playPause", "previous", "next"])
  const live = M.mediaActivity({ title: "Radio", playing: false, length: 9.2e12 })
  assert.equal(live.progress, -1)
  assert.equal(live.priority, M.PRIORITY.mediaPaused)
})

test("sanitizePush validates id and payload", () => {
  assert.equal(M.sanitizePush("bad id", "{}", 0).ok, false)
  assert.equal(M.sanitizePush("../x", '{"title":"a"}', 0).ok, false)
  assert.equal(M.sanitizePush("build", "nope", 0).ok, false)
  assert.equal(M.sanitizePush("build", "[1]", 0).ok, false)
  assert.equal(M.sanitizePush("build", '{"subtitle":"no title"}', 0).ok, false)
  assert.equal(M.sanitizePush("build", JSON.stringify({ title: "x".repeat(5000) }), 0).ok, false)
  const r = M.sanitizePush("build", JSON.stringify({ title: "Build\u001b[2J\nok", progress: 7, ttl: 1e9, priority: "high", icon: "\u{f0996}", command: "rm -rf ~" }), 1000)
  assert.equal(r.ok, true)
  assert.equal(r.item.title, "Build [2J ok")
  assert.equal(r.item.progress, 1)
  assert.equal(r.item.expiresAt, 1000 + 24 * 3600 * 1000)
  assert.equal(r.item.priority, "high")
  assert.equal(r.item.icon, "\u{f0996}")
  assert.equal("command" in r.item, false)
  const longIcon = M.sanitizePush("x", JSON.stringify({ title: "t", icon: "abcdef" }), 0)
  assert.equal(longIcon.item.icon, "")
  const act = M.pushActivity(r.item)
  assert.equal(act.id, "push:build")
  assert.equal(act.priority, M.PRIORITY.pushHigh)
})

test("upsertPush caps the list and prunePushes drops expired ones", () => {
  let items = {}
  for (let i = 0; i < 10; i++) items = M.upsertPush(items, { id: "p" + i, updatedAt: i, expiresAt: i === 9 ? 50 : 0 })
  assert.equal(Object.keys(items).length, 8)
  assert.equal("p0" in items, false)
  assert.equal("p1" in items, false)
  const pruned = M.prunePushes(items, 100)
  assert.equal("p9" in pruned, false)
  assert.equal(M.prunePushes(pruned, 100), pruned)
})

test("visibleActivities filters modules and dismissed, sorted by priority", () => {
  const list = [
    { id: "media", module: "media", priority: 60, signature: "a" },
    { id: "privacy", module: "privacy", priority: 10, signature: "m" },
    { id: "timer", module: "timer", priority: 40, signature: "running" }
  ]
  const prefs = M.normalizePrefs({ moduleMedia: false })
  assert.deepEqual(M.visibleActivities(list, prefs, {}).map((a) => a.id), ["privacy", "timer"])
  assert.deepEqual(M.visibleActivities(list, M.normalizePrefs({}), { timer: "running" }).map((a) => a.id), ["privacy", "media"])
  assert.deepEqual(M.visibleActivities(list, M.normalizePrefs({}), { timer: "paused" }).map((a) => a.id), ["privacy", "timer", "media"])
  const dismissed = { timer: "paused", gone: "x", media: "a" }
  assert.deepEqual(M.pruneDismissed(dismissed, list), { media: "a" })
})

test("nextIndex wraps both ways", () => {
  assert.equal(M.nextIndex(3, 2, 1), 0)
  assert.equal(M.nextIndex(3, 0, -1), 2)
  assert.equal(M.nextIndex(0, 0, 1), -1)
  assert.equal(M.nextIndex(3, 9, 1), 1)
})

test("resolveFocus: newcomers take focus unless less important or manual hold", () => {
  const list = [{ id: "privacy", priority: 10 }, { id: "timer", priority: 40 }, { id: "media", priority: 60 }]
  const base = { list, focusId: "timer", knownIds: { timer: 40, media: 60 }, autoFocus: true, manualUntil: 0, now: 100 }
  assert.equal(M.resolveFocus(base), "privacy")
  assert.equal(M.resolveFocus({ ...base, autoFocus: false }), "timer")
  assert.equal(M.resolveFocus({ ...base, manualUntil: 200 }), "timer")
  assert.equal(M.resolveFocus({ ...base, focusId: "privacy", knownIds: { privacy: 10, timer: 40 } }), "privacy")
  assert.equal(M.resolveFocus({ ...base, focusId: "gone", knownIds: { privacy: 10, timer: 40, media: 60 } }), "privacy")
  assert.equal(M.resolveFocus({ ...base, list: [] }), "")
})

test("resolveFocus: an activity that got more important counts as new", () => {
  // Paused media (95) starts playing (60) while charging (80) has the pill.
  const list = [{ id: "media", priority: 60 }, { id: "charging", priority: 80 }]
  const base = { list, focusId: "charging", knownIds: { media: 95, charging: 80 }, autoFocus: true, manualUntil: 0, now: 100 }
  assert.equal(M.resolveFocus(base), "media")
  assert.equal(M.resolveFocus({ ...base, manualUntil: 200 }), "charging")
  // Same importance as before, or less: no change.
  assert.equal(M.resolveFocus({ ...base, knownIds: { media: 60, charging: 80 } }), "charging")
  assert.equal(M.resolveFocus({ ...base, list: [{ id: "media", priority: 95 }, { id: "charging", priority: 80 }], knownIds: { media: 60, charging: 80 } }), "charging")
})

test("prefs normalize and store only non-defaults", () => {
  const p = M.normalizePrefs({ moduleCharging: false, whenEmpty: "weird", maxWidth: 5000, autoFocus: "yes" })
  assert.equal(p.modules.charging, false)
  assert.equal(p.modules.media, true)
  assert.equal(p.whenEmpty, "brief")
  assert.equal(p.weatherUnit, "auto")
  assert.equal(p.showQuickToggles, true)
  assert.equal(M.normalizePrefs({ showQuickToggles: false }).showQuickToggles, false)
  assert.equal(p.modules.weather, true)
  assert.equal(M.normalizePrefs({ whenEmpty: "icon" }).whenEmpty, "icon")
  assert.equal(p.textMode, "scroll")
  assert.equal(p.coverAccent, true)
  assert.equal(p.animations, true)
  assert.equal(M.normalizePrefs({ animations: false }).animations, false)
  assert.equal(M.normalizePrefs({ textMode: "ellipsis" }).textMode, "ellipsis")
  assert.equal(p.maxWidth, 600)
  assert.equal(p.autoFocus, true)
  assert.deepEqual(M.entrySettings(p, { other: 1, id: "x" }), { other: 1, moduleCharging: false, maxWidth: 600 })
})

test("tooltipLabel", () => {
  assert.equal(M.tooltipLabel(null, 0, 0), "Now Bar · nothing going on")
  assert.equal(M.tooltipLabel({ title: "A", subtitle: "B" }, 1, 3), "A\nB\n2/3 · scroll to switch")
})

test("safeArtUrl only allows https to public hosts and local files", () => {
  assert.equal(M.safeArtUrl("https://i.scdn.co/image/abc"), "https://i.scdn.co/image/abc")
  assert.equal(M.safeArtUrl("file:///tmp/cover.jpg"), "file:///tmp/cover.jpg")
  assert.equal(M.safeArtUrl("http://example.com/a.jpg"), "")
  assert.equal(M.safeArtUrl("https://127.1/a.jpg"), "")
  assert.equal(M.safeArtUrl("https://0x7f.1/a.jpg"), "")
  assert.equal(M.safeArtUrl("https://192.168.0.1/a.jpg"), "")
  assert.equal(M.safeArtUrl("https://router.lan/a.jpg"), "")
  assert.equal(M.safeArtUrl("data:image/png;base64,AAAA"), "")
})

test("accentFromHistogram picks the vivid color and keeps it readable", () => {
  const hist = [
    "  5000: (10,10,12) #0A0A0C srgb(4%,4%,5%)",
    "  3000: (240,240,240) #F0F0F0 srgb(94%,94%,94%)",
    "   800: (200,30,60) #C81E3C srgb(78%,12%,24%)",
    "   900: (120,120,125) #78787D srgb(47%,47%,49%)"
  ].join("\n")
  const c = M.accentFromHistogram(hist)
  assert.match(c, /^#[0-9a-f]{6}$/)
  const r = parseInt(c.slice(1, 3), 16), g = parseInt(c.slice(3, 5), 16), b = parseInt(c.slice(5, 7), 16)
  assert.ok(r > g && r > b, "should stay red: " + c)
  // Gray, black and white only: no accent, the theme's stays.
  assert.equal(M.accentFromHistogram("  10: (0,0,0) #000000 black\n  10: (128,128,128) #808080 gray\n  9: (255,255,255) #FFFFFF white"), "")
  assert.equal(M.accentFromHistogram("garbage"), "")
  // 16-bit images: #RRRRGGGGBBBBAAAA, high bytes kept.
  const deep = M.parseHistogram("  860: (59705.5,27385.3,29691.9,65535) #E9396AF973FCFFFF srgba(91%,41%,45%,1)")
  assert.equal(deep.length, 1)
  assert.equal(Math.round(deep[0].r * 255), 0xE9)
  assert.equal(Math.round(deep[0].g * 255), 0x6A)
  assert.equal(Math.round(deep[0].b * 255), 0x73)
  // Alpha suffix (#RRGGBBAA) is accepted.
  assert.equal(M.parseHistogram("  4: (0,0,255,255) #0000FFFF srgba(0,0,255,1)").length, 1)
  // A dark navy is lifted to a readable lightness.
  const navy = M.accentFromHistogram("  50: (10,20,70) #0A1446 x")
  const l = (Math.max(...[1, 3, 5].map((i) => parseInt(navy.slice(i, i + 2), 16))) + Math.min(...[1, 3, 5].map((i) => parseInt(navy.slice(i, i + 2), 16)))) / 2 / 255
  assert.ok(l >= 0.49, navy)
})

test("parseTimerArg: seconds, units and clock times", () => {
  const now = new Date(2026, 9, 6, 14, 0, 0).getTime()
  assert.equal(M.parseTimerArg("90", now), 90)
  assert.equal(M.parseTimerArg("25m", now), 1500)
  assert.equal(M.parseTimerArg("1h30m", now), 5400)
  assert.equal(M.parseTimerArg("45s", now), 45)
  assert.equal(M.parseTimerArg("14:30", now), 1800)
  assert.equal(M.parseTimerArg("13:00", now), 23 * 3600)
  assert.equal(M.parseTimerArg("25:00", now), 0)
  assert.equal(M.parseTimerArg("abc", now), 0)
  assert.equal(M.parseTimerArg("", now), 0)
})

test("parsePresets", () => {
  assert.deepEqual(M.parsePresets("1, 5,10,25"), [60, 300, 600, 1500])
  assert.deepEqual(M.parsePresets("3,3,x,0,99999,7"), [180, 420])
  assert.deepEqual(M.parsePresets("junk"), [60, 300, 600, 1500])
  assert.deepEqual(M.parsePresets(""), [])
  assert.equal(M.normalizePrefs({ timerPresets: "" }).timerPresets, "")
  assert.equal(M.parsePresets("1,2,3,4,5,6,7,8").length, 6)
  assert.equal(M.normalizePrefs({ timerPresets: "2,4" }).timerPresets, "2,4")
})

test("pomodoro cycles focus and breaks, long break every 4", () => {
  const cfg = M.pomodoroConfig({ pomodoroFocus: 25, pomodoroBreak: 5, pomodoroLongBreak: 15 })
  let p = M.startPomodoro(cfg, 0)
  assert.equal(p.phase, "focus")
  assert.equal(p.durationMs, 25 * 60000)
  const phases = []
  for (let i = 0; i < 8; i++) { p = M.nextPomodoro(p, cfg, 0); phases.push(p.phase) }
  assert.deepEqual(phases, ["break", "focus", "break", "focus", "break", "focus", "longBreak", "focus"])
  p = M.pausePomodoro(M.startPomodoro(cfg, 0), 60000)
  assert.equal(p.state, "paused")
  assert.equal(p.remainingMs, 24 * 60000)
  p = M.resumePomodoro(p, 100000)
  assert.equal(p.endsAt, 100000 + 24 * 60000)
  const a = M.pomodoroActivity(p, cfg, 100000)
  assert.equal(a.subtitle, "Pomodoro · round 1/4")
  assert.deepEqual(a.actions.map((x) => x.id), ["pause", "skip", "stop"])
  assert.equal(M.normalizePomodoro({ state: "running", phase: "weird", durationMs: 1000 }).phase, "focus")
  assert.equal(M.normalizePomodoro(null).state, "idle")
})

test("sleep timer", () => {
  assert.equal(M.sleepActivity(M.idleSleep(), 0), null)
  const s = M.normalizeSleep(M.startTimer(1800, 0))
  const a = M.sleepActivity(s, 600000)
  assert.equal(a.pillText, "Sleep 20:00")
  assert.equal(M.normalizeSleep({ state: "paused", durationMs: 5 }).state, "idle")
})

test("modes with VPNs from tailscale and nmcli", () => {
  const m = M.parseModes("off\n{}\n{}\nRunning\nHome\\:Office:vpn\nWi-Fi:802-11-wireless\nwg0:wireguard")
  assert.deepEqual(m.vpns.map((v) => v.name), ["Tailscale", "Home:Office", "wg0"])
  const a = M.modesActivity(m)
  assert.equal(a.title, "3 modes on")
  assert.deepEqual(a.actions.map((x) => x.id), ["vpnDown:1", "vpnDown:2"])
  assert.equal(M.parseNmcliLine("a\\\\b:vpn").rawName, "a\\b")
  assert.equal(M.parseNmcliLine(""), null)
})

test("low battery", () => {
  assert.equal(M.batteryActivity({ present: true, onBattery: true, percentage: 0.5 }), null)
  assert.equal(M.batteryActivity({ present: true, onBattery: false, percentage: 0.05 }), null)
  const a = M.batteryActivity({ present: true, onBattery: true, percentage: 0.12, timeToEmpty: 2400 })
  assert.equal(a.urgent, true)
  assert.equal(a.subtitle, "40m left")
  assert.notEqual(a.signature, M.batteryActivity({ present: true, onBattery: true, percentage: 0.07 }).signature)
})

test("one media activity per player, with seek and volume data", () => {
  const a = M.mediaActivity({ key: "org.mpris.MediaPlayer2.spotify", title: "A", playing: true, canSeek: true, length: 200, position: 50, volumeSupported: true, volume: 0.7 })
  const b = M.mediaActivity({ key: "org.mpris.MediaPlayer2.firefox.instance_1_2", title: "B", playing: false })
  assert.notEqual(a.id, b.id)
  assert.match(a.id, /^media:[A-Za-z0-9._-]+$/)
  assert.equal(a.target, "org.mpris.MediaPlayer2.spotify")
  assert.equal(a.seekable, true)
  assert.equal(a.length, 200)
  assert.equal(a.volume, 0.7)
  assert.equal(b.volume, -1)
  assert.equal(b.seekable, false)
})

test("push with elapsed time and state", () => {
  const r1 = M.sanitizePush("run-1", JSON.stringify({ title: "make", elapsed: true, state: "running" }), 1000)
  let items = M.upsertPush({}, r1.item)
  const r2 = M.sanitizePush("run-1", JSON.stringify({ title: "make", elapsed: true, state: "running", subtitle: "still" }), 5000)
  items = M.upsertPush(items, r2.item)
  assert.equal(items["run-1"].startedAt, 1000)
  const a = M.pushActivity(items["run-1"], 66000)
  assert.equal(a.pillText, "make · 1:05")
  assert.equal(a.subtitle, "still · 1:05")
  const err = M.sanitizePush("run-1", JSON.stringify({ title: "make", state: "error" }), 0)
  assert.equal(err.item.urgent, true)
  assert.equal(M.pushActivity(err.item, 0).icon, "\u{f0028}")
  assert.equal(M.sanitizePush("x", JSON.stringify({ title: "t", state: "weird" }), 0).item.state, "")
})

test("bluetooth and screenshot activities", () => {
  const bt = M.bluetoothActivity({ address: "AA:BB:CC:DD:EE:FF", name: "WH-1000XM4\n", battery: 0.8 })
  assert.equal(bt.id, "bt:AA:BB:CC:DD:EE:FF")
  assert.equal(bt.pillText, "WH-1000XM4 · 80%")
  assert.equal(M.bluetoothActivity({ address: "x", name: "", battery: -1 }).subtitle, "Connected")
  assert.equal(M.validScreenshotName("screenshot-2026-10-06_10-00-00.png"), true)
  assert.equal(M.validScreenshotName("a.JPG"), true)
  assert.equal(M.validScreenshotName("../x.png"), false)
  assert.equal(M.validScreenshotName(".hidden.png"), false)
  assert.equal(M.validScreenshotName("evil\n.png"), false)
  assert.equal(M.validScreenshotName("notes.txt"), false)
  const s = M.screenshotActivity({ path: "/home/u/Pictures/s.png", name: "s.png" })
  assert.equal(s.image, "/home/u/Pictures/s.png")
  assert.deepEqual(s.actions.map((x) => x.id), ["edit", "copy", "open"])
})

test("weather from wttr.in j1", () => {
  const fs = require("node:fs")
  const path = require("node:path")
  const raw = fs.readFileSync(path.join(__dirname, "fixtures", "wttr-j1.json"), "utf8")
  const noon = new Date(2026, 9, 6, 12, 10).getTime()
  const w = M.parseWttr(raw, noon, { unit: "auto", locale: "en_US" })
  // Country (Brazil) wins over an en_US locale: Celsius.
  assert.equal(w.unit, "°C")
  assert.equal(w.temp, 23)
  assert.equal(w.feels, 25)
  assert.equal(w.desc, "Sunny")
  assert.equal(w.location, "Testville")
  assert.equal(w.night, false)
  assert.equal(w.icon, "\u{e30d}")
  assert.equal(w.color, "#f2a33a")
  assert.equal(w.humidity, 70)
  assert.equal(w.wind, "4 km/h NNW")
  assert.equal(w.sunrise, "5:19")
  assert.equal(w.sunset, "17:41")
  // The 12h slot is the one we are in: it comes first, as "Now".
  assert.equal(w.hours.length, 8)
  assert.equal(w.hours[0].label, "Now")
  assert.equal(w.hours[0].temp, 23)
  assert.equal(w.hours[1].label, "15h")
  assert.equal(w.hours[4].label, "00h")
  assert.deepEqual(w.days.map((d) => d.name), ["Today", "Tomorrow", "Thu"])
  assert.equal(w.days[1].rain, 85)
  assert.equal(w.days[0].max, 32)

  const night = M.parseWttr(raw, new Date(2026, 9, 6, 21, 0).getTime(), { unit: "imperial" })
  assert.equal(night.night, true)
  assert.equal(night.unit, "°F")
  assert.equal(night.temp, 73)
  assert.equal(night.wind, "2 mph NNW")
  assert.equal(night.icon, "\u{e32b}")
  assert.equal(night.hours[0].label, "Now")

  assert.equal(M.parseWttr("nope", noon, {}), null)
  assert.equal(M.parseWttr('{"current_condition":[{}],"weather":[{}]}', noon, {}), null)
})

test("weather units, clock and colors", () => {
  assert.equal(M.useImperial("auto", "en_US.UTF-8", ""), true)
  assert.equal(M.useImperial("auto", "pt_BR", ""), false)
  assert.equal(M.useImperial("auto", "pt_BR", "United States"), true)
  assert.equal(M.useImperial("metric", "en_US", "USA"), false)
  assert.equal(M.clockMinutes("05:41 PM"), 17 * 60 + 41)
  assert.equal(M.clockMinutes("12:05 AM"), 5)
  assert.equal(M.clockMinutes("bad"), -1)
  assert.equal(M.weatherColor(389, false), "#7b5cd6")
  assert.equal(M.weatherColor(113, true), "#4a56c8")
})

test("weather card is ambient and lowest priority", () => {
  const fs = require("node:fs")
  const path = require("node:path")
  const w = M.parseWttr(fs.readFileSync(path.join(__dirname, "fixtures", "wttr-j1.json"), "utf8"), new Date(2026, 9, 6, 12).getTime(), {})
  const a = M.weatherActivity(w, false)
  assert.equal(a.ambient, true)
  assert.equal(a.priority, M.PRIORITY.brief)
  assert.equal(a.pillText, "23° · Sunny")
  assert.equal(a.subtitle, "Testville · H 32° L 17°")
  assert.match(M.weatherActivity(w, true).pillText, /Update$/)
  assert.equal(M.weatherActivity(null, false), null)
  assert.equal(M.weatherActivity(null, true).title, "Update available")
  // A live activity always takes the focus from it.
  const list = M.sortActivities([a, { id: "timer", priority: 40 }])
  assert.equal(M.resolveFocus({ list, focusId: "brief", knownIds: { brief: 99 }, autoFocus: true, manualUntil: 0, now: 1 }), "timer")
})

test("cover base color and popup surface tint", () => {
  const hist = [
    "  6000: (20,40,120) #142878 x",
    "   500: (230,40,60) #E6283C x",
    "  3000: (128,128,128) #808080 x"
  ].join("\n")
  assert.equal(M.baseFromHistogram(hist), "#142878")
  assert.equal(M.baseFromHistogram("junk"), "")
  const dark = M.surfaceTint("#142878", true)
  const light = M.surfaceTint("#142878", false)
  const lum = (h) => (Math.max(...[1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16))) + Math.min(...[1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16)))) / 2 / 255
  assert.ok(Math.abs(lum(dark) - 0.17) < 0.01, dark)
  assert.ok(Math.abs(lum(light) - 0.91) < 0.01, light)
  const b = parseInt(dark.slice(5, 7), 16), r = parseInt(dark.slice(1, 3), 16)
  assert.ok(b > r, "keeps the blue hue: " + dark)
  assert.equal(M.surfaceTint("nope", true), "")
})

test("clean cuts huge text before working on it", () => {
  const big = "a".repeat(5e6) + "\u001b[31m"
  const t = Date.now()
  for (let i = 0; i < 20; i++) M.clean(big)
  assert.ok(Date.now() - t < 500, "too slow on a 5 MB title")
  assert.equal(M.clean(big).length, 120)
  assert.equal(M.clean(big, 10), "aaaaaaaaa…")
})

test("Quick toggles / Quick start item lists", () => {
  assert.deepEqual(M.parseIdList(undefined, M.QUICK_TOGGLES), M.QUICK_TOGGLES)
  assert.deepEqual(M.parseIdList("", M.QUICK_TOGGLES), [])
  assert.deepEqual(M.parseIdList("record, dnd,bogus", M.QUICK_TOGGLES), ["dnd", "record"])
  assert.equal(M.toggleIdList(["dnd", "record"], M.QUICK_TOGGLES, "nightlight", true), "dnd,nightlight,record")
  assert.equal(M.toggleIdList(["dnd", "record"], M.QUICK_TOGGLES, "dnd", false), "record")
  const p = M.normalizePrefs({ quickToggleItems: "stayAwake,dnd", quickStartItems: "", showQuickStart: false })
  assert.deepEqual(p.quickToggles, ["dnd", "stayAwake"])
  assert.equal(p.quickToggleItems, "dnd,stayAwake")
  assert.deepEqual(p.quickStartExtras, [])
  assert.equal(p.showQuickStart, false)
  const d = M.normalizePrefs({})
  assert.deepEqual(d.quickStartExtras, ["stopwatch", "pomodoro", "sleep"])
  assert.deepEqual(M.entrySettings(d, {}), {})
})

test("parseUpdates reads the script's lines and skips junk", () => {
  const text = [
    "pacman\taether\t4.32.0-1\t4.32.0-2",
    "pacman\tomarchy\t3.1-1\t3.2-1",
    "omarchy\tOmarchy\t\tomarchy 3.1-1 -> 3.2-1",
    "flatpak\torg.gaphor.Gaphor\t3.3.2\t3.3.2",
    "aur\tyay-bin\t12.1\t12.2",
    "error\taur\tyay -Qua failed",
    "error\tbogus\tx",
    "weird\tline",
    "pacman\t\t1\t2",
    "pacman\tbad\u0007name\t1\t2"
  ].join("\n")
  const r = M.parseUpdates(text)
  assert.deepEqual(r.items.map(u => u.source + ":" + u.name), ["pacman:aether", "omarchy:Omarchy", "flatpak:org.gaphor.Gaphor", "aur:yay-bin", "pacman:bad name"])
  assert.deepEqual(r.errors, ["aur"])
  // Without the omarchy source, Omarchy's package stays among the official ones.
  assert.equal(M.parseUpdates("pacman\tomarchy\t1\t2").items.length, 1)
  assert.deepEqual(M.parseUpdates(""), { items: [], errors: [] })
})

test("updatesActivity sums up by source", () => {
  const state = M.normalizeUpdates({
    items: [
      { source: "pacman", name: "a", from: "1", to: "2" },
      { source: "pacman", name: "b", from: "1", to: "2" },
      { source: "flatpak", name: "org.x.Y", from: "3", to: "3" },
      { source: "omarchy", name: "Omarchy", from: "", to: "omarchy 1 -> 2" }
    ],
    errors: ["aur"],
    checkedAt: new Date(2026, 9, 8, 14, 5).getTime()
  })
  const a = M.updatesActivity(state, false)
  assert.equal(a.title, "4 updates")
  assert.equal(a.subtitle, "Omarchy · 2 Official · 1 Flatpak")
  assert.equal(a.module, "updates")
  assert.equal(a.urgent, false)
  assert.ok(a.details[0].includes("omarchy 1 -> 2"))
  assert.ok(a.details.includes("a  ·  1 → 2"))
  assert.ok(a.details.includes("org.x.Y  ·  3 (new build)"))
  assert.ok(a.details.some(d => d.includes("Couldn't check AUR")))
  assert.ok(a.details.includes("Checked at 14:05"))
  assert.deepEqual(a.actions.map(x => x.id), ["update", "check"])
  assert.equal(M.updatesActivity(state, true).subtitle, "Checking…")
  assert.equal(M.updatesActivity(M.normalizeUpdates({}), false), null)
  // Same list, same signature; another list, another one.
  assert.equal(M.updatesActivity(state, true).signature, a.signature)
  assert.notEqual(M.updatesActivity(M.normalizeUpdates({ items: [{ source: "pacman", name: "a", to: "3" }] }), false).signature, a.signature)
})

test("updates prefs, schedule and interval labels", () => {
  const p = M.normalizePrefs({})
  assert.equal(p.modules.updates, true)
  assert.deepEqual(p.updateSourceList, ["omarchy", "pacman", "aur", "flatpak"])
  assert.equal(p.updateInterval, 180)
  assert.equal(p.updateOnStartup, true)
  assert.deepEqual(M.normalizePrefs({ updateSources: "flatpak,nope,pacman" }).updateSourceList, ["pacman", "flatpak"])
  assert.equal(M.normalizePrefs({ updateInterval: 1 }).updateInterval, 5)
  assert.equal(M.normalizePrefs({ updateInterval: 99999 }).updateInterval, 10080)
  assert.equal(M.updatesDue(0, 180, 1000), true)
  assert.equal(M.updatesDue(1000, 180, 1000 + 179 * 60000), false)
  assert.equal(M.updatesDue(1000, 180, 1000 + 180 * 60000), true)
  assert.equal(M.intervalLabel(30), "30 min")
  assert.equal(M.intervalLabel(180), "3 h")
  assert.equal(M.intervalLabel(90), "1 h 30 min")
  assert.equal(M.intervalLabel(1440), "1 d")
  assert.deepEqual(M.normalizeUpdates({ items: [{ source: "x", name: "a" }, { source: "aur", name: "" }], errors: ["aur", "x"], checkedAt: "5" }),
    { items: [], errors: ["aur"], checkedAt: 5 })
})

test("mergeUpdates keeps what a failed source listed; updateCommand", () => {
  const prev = { items: [{ source: "aur", name: "x", from: "1", to: "2" }, { source: "pacman", name: "old", from: "1", to: "2" }], errors: [], checkedAt: 1 }
  const m = M.mergeUpdates(prev, { items: [{ source: "pacman", name: "new", from: "1", to: "2" }], errors: ["aur"] }, 50)
  assert.deepEqual(m.items.map(u => u.name), ["new", "x"])
  assert.deepEqual(m.errors, ["aur"])
  assert.equal(m.checkedAt, 50)
  assert.deepEqual(M.updatesFor(m, ["pacman"]).items.map(u => u.name), ["new"])
  assert.deepEqual(M.updatesFor(m, ["pacman"]).errors, [])
  assert.equal(M.updateCommand([{ source: "pacman" }]), "omarchy-update")
  assert.equal(M.updateCommand([{ source: "flatpak" }]), "flatpak update")
  assert.equal(M.updateCommand([{ source: "aur" }, { source: "flatpak" }]), "omarchy-update && flatpak update")
  assert.equal(M.updateCommand([]), "omarchy-update")
})

test("newUpdates counts what a check found that wasn't waiting before", () => {
  const prev = { items: [{ source: "pacman", name: "a", to: "2" }, { source: "aur", name: "b", to: "1" }] }
  assert.equal(M.newUpdates(prev, prev), 0)
  assert.equal(M.newUpdates(prev, { items: [{ source: "pacman", name: "a", to: "2" }] }), 0)
  assert.equal(M.newUpdates(prev, { items: [{ source: "pacman", name: "a", to: "3" }, { source: "flatpak", name: "c", to: "1" }] }), 2)
  assert.equal(M.newUpdates({ items: [] }, prev), 2)
})

test("the updates card has a normal priority", () => {
  const a = M.updatesActivity(M.normalizeUpdates({ items: [{ source: "pacman", name: "a", from: "1", to: "2" }] }), false)
  const list = M.sortActivities([a, M.chargingActivity({ present: true, charging: true, percentage: 0.5 }), M.timerActivity(M.startTimer(60, 0), 0)])
  assert.deepEqual(list.map(x => x.id), ["timer", "updates", "charging"])
})

test("only the update sources this system has are offered and checked", () => {
  // A fresh Omarchy install: no flatpak.
  const fresh = M.parseAvailableSources("omarchy\npacman\naur\n")
  assert.deepEqual(fresh, ["omarchy", "pacman", "aur"])
  assert.deepEqual(M.parseAvailableSources("flatpak\nparu\n\npacman"), ["pacman", "flatpak"])
  assert.deepEqual(M.activeSources(["omarchy", "pacman", "aur", "flatpak"], fresh), ["omarchy", "pacman", "aur"])
  assert.deepEqual(M.activeSources(["flatpak"], fresh), [])
  assert.deepEqual(M.activeSources(["aur", "flatpak"], []), [])
})

test("actions that open an app are marked, so the popup closes first", () => {
  const u = M.updatesActivity(M.normalizeUpdates({ items: [{ source: "pacman", name: "a", from: "1", to: "2" }] }), false)
  assert.deepEqual(u.actions.filter(a => a.opensApp).map(a => a.id), ["update"])
  const s = M.screenshotActivity({ path: "/tmp/x.png", name: "x.png", at: 0 })
  assert.deepEqual(s.actions.filter(a => a.opensApp).map(a => a.id), ["edit", "open"])
})

test("media card: playing, album, long-form skips, shuffle, repeat, open player", () => {
  const base = { key: "spotify", title: "Song", artist: "Band", album: "Record", player: "Spotify", playing: true,
    canToggle: true, canPrevious: true, canNext: true, canSeek: true, position: 30, length: 200 }
  const a = M.mediaActivity(base)
  assert.equal(a.playing, true)
  assert.equal(a.album, "Record")
  assert.deepEqual(a.details, ["Record"])
  assert.equal(a.position, 30)
  assert.equal(a.long, false)
  assert.equal(a.shuffle, null)
  assert.equal(a.loop, "")
  assert.deepEqual(a.actions.map(x => x.id), ["playPause", "previous", "next"])
  const full = M.mediaActivity({ ...base, length: 3600, shuffleSupported: true, shuffle: true, loopSupported: true, loop: "track", canRaise: true })
  assert.equal(full.long, true)
  assert.equal(full.shuffle, true)
  assert.equal(full.loop, "track")
  assert.deepEqual(full.actions.map(x => x.id), ["playPause", "previous", "next", "back10", "forward10", "shuffle", "loop", "raise"])
  assert.equal(full.actions.find(x => x.id === "raise").opensApp, true)
  // Not seekable: no skips, however long.
  assert.equal(M.mediaActivity({ ...base, length: 3600, canSeek: false }).long, false)
  // An album named like the track isn't repeated.
  assert.deepEqual(M.mediaActivity({ ...base, album: "Song" }).details, [])
  assert.equal(M.nextLoop("none"), "playlist")
  assert.equal(M.nextLoop("playlist"), "track")
  assert.equal(M.nextLoop("track"), "none")
})

test("ignored players and paused media leaving the pill", () => {
  const ig = M.parseIgnoredPlayers(" Chromium, firefox,chromium,, ")
  assert.deepEqual(ig, ["chromium", "firefox"])
  assert.equal(M.isIgnoredPlayer(ig, ["Chromium"]), true)
  assert.equal(M.isIgnoredPlayer(ig, ["", "", "org.mpris.MediaPlayer2.firefox.instance_1_45"]), true)
  assert.equal(M.isIgnoredPlayer(ig, ["Spotify", "spotify", "org.mpris.MediaPlayer2.spotify"]), false)
  assert.equal(M.isIgnoredPlayer([], ["Chromium"]), false)
  assert.equal(M.toggleIgnoredPlayer("chromium", "Firefox", true), "chromium,firefox")
  assert.equal(M.toggleIgnoredPlayer("chromium,firefox", "Chromium", false), "firefox")
  const paused = { module: "media", playing: false }
  assert.equal(M.staleMedia(paused, 1000, 1000 + 15 * 60000, 15), true)
  assert.equal(M.staleMedia(paused, 1000, 1000 + 14 * 60000, 15), false)
  assert.equal(M.staleMedia(paused, 1000, 1000 + 99 * 60000, 0), false)
  assert.equal(M.staleMedia({ module: "media", playing: true }, 1000, 1e12, 15), false)
  assert.equal(M.staleMedia({ module: "timer" }, 1000, 1e12, 15), false)
  const p = M.normalizePrefs({ mediaIgnore: "Chromium", mediaPausedMinutes: 5000 })
  assert.deepEqual(p.ignoredPlayers, ["chromium"])
  assert.equal(p.mediaPausedMinutes, 1440)
  assert.equal(M.normalizePrefs({}).mediaPausedMinutes, 15)
})

test("mixOklab: ends exact, a clean middle between opposite colors", () => {
  const blue = { r: 0.22, g: 0.55, b: 0.95, a: 1 }
  const orange = { r: 0.98, g: 0.45, b: 0.09, a: 1 }
  const near = (x, y) => Math.abs(x - y) < 1e-3
  const s = M.mixOklab(blue, orange, 0), e = M.mixOklab(blue, orange, 1)
  assert.ok(near(s.r, blue.r) && near(s.g, blue.g) && near(s.b, blue.b))
  assert.ok(near(e.r, orange.r) && near(e.g, orange.g) && near(e.b, orange.b))
  // Halfway: lighter than the straight RGB average (no muddy dip), and no
  // green showing up (no rainbow).
  const m = M.mixOklab(blue, orange, 0.5)
  const lum = c => 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
  const rgbMid = { r: (blue.r + orange.r) / 2, g: (blue.g + orange.g) / 2, b: (blue.b + orange.b) / 2 }
  assert.ok(lum(m) > lum(rgbMid))
  assert.ok(m.g <= Math.max(m.r, m.b) + 0.05)
})

test("timer: time's up card, ending flag", () => {
  const t = M.startTimer(300, 0)
  assert.equal(M.timerActivity(t, 280000).ending, false)
  assert.equal(M.timerActivity(t, 295000).ending, true)
  const d = M.doneTimer(t, 300000)
  const a = M.timerActivity(d, 300500)
  assert.equal(a.title, "Time's up")
  assert.equal(a.done, true)
  assert.deepEqual(a.actions.map(x => x.id), ["repeat", "add", "ok"])
  assert.equal(M.doneExpired(d, 300000 + M.TIMER_DONE_MS - 1), false)
  assert.equal(M.doneExpired(d, 300000 + M.TIMER_DONE_MS), true)
  assert.equal(M.normalizeTimer(d).state, "idle")
})

test("pomodoro: focus blocks counted per day", () => {
  const day1 = new Date(2026, 9, 8, 10, 0).getTime()
  const day2 = new Date(2026, 9, 9, 9, 0).getTime()
  let s = M.countFocusDone(null, day1)
  s = M.countFocusDone(s, day1)
  assert.equal(s.count, 2)
  assert.equal(M.normalizePomodoroStats(s, day2).count, 0)
  const cfg = M.pomodoroConfig({})
  const a = M.pomodoroActivity(M.startPomodoro(cfg, day1), cfg, day1, s)
  assert.ok(a.subtitle.endsWith("· 2 today"))
  assert.ok(!M.pomodoroActivity(M.startPomodoro(cfg, day1), cfg, day1, { day: "x", count: 0 }).subtitle.includes("today"))
})

test("reminders: postpone, fired, unit check", () => {
  assert.equal(M.validReminderUnit("omarchy-reminder-5m-1791507560"), true)
  assert.equal(M.validReminderUnit("omarchy-reminder-5m-1; rm -rf ~"), false)
  assert.equal(M.validReminderUnit("other.timer"), false)
  assert.equal(M.postponeMinutes(10 * 60000, 0, 5), 15)
  assert.equal(M.postponeMinutes(90000, 0, 5), 7)
  const before = [{ unit: "a", at: 1000 }, { unit: "b", at: 999999 }]
  assert.deepEqual(M.firedReminders(before, [{ unit: "b", at: 999999 }], 1500).map(r => r.unit), ["a"])
  // Cleared early (not due yet): not "fired".
  assert.deepEqual(M.firedReminders(before, [], 1500).map(r => r.unit), ["a"])
  const f = M.firedReminderActivity({ label: "Oven", at: 1000 })
  assert.equal(f.title, "Oven")
  assert.deepEqual(f.actions.map(x => x.id), ["snooze5", "snooze15", "ok"])
  const r = M.remindersActivity([{ unit: "u", label: "Call", message: "Call", at: 600000, minutes: 10 }], 0)
  assert.deepEqual(r.actions.map(x => x.id), ["postpone", "clear"])
})

test("recorded video: only Omarchy's recordings in the folder", () => {
  const dir = "/home/u/Videos"
  assert.equal(M.validRecordingPath(dir + "/screenrecording-2026-10-08_22-10-01.mp4", dir), true)
  assert.equal(M.validRecordingPath(dir + "/screenrecording-2026-10-08_22-10-01.mp4", dir + "/"), true)
  assert.equal(M.validRecordingPath(dir + "/../x/screenrecording-1.mp4", dir), false)
  assert.equal(M.validRecordingPath("/etc/passwd", dir), false)
  assert.equal(M.validRecordingPath(dir + "/notes.mp4", dir), false)
  const a = M.recordedActivity({ path: dir + "/screenrecording-1.mp4", name: "screenrecording-1.mp4", thumb: "/c/t.png" })
  assert.equal(a.image, "/c/t.png")
  assert.deepEqual(a.actions.filter(x => x.opensApp).map(x => x.id), ["open", "folder"])
})

test("bluetooth: audio action, low battery card", () => {
  assert.deepEqual(M.bluetoothActivity({ address: "AA:BB", name: "Buds", battery: 0.8, audio: true }).actions.map(x => x.id), ["audio"])
  assert.deepEqual(M.bluetoothActivity({ address: "AA:BB", name: "Mouse", battery: 0.8 }).actions, [])
  assert.equal(M.btLowActivity({ address: "AA:BB", name: "Mouse", battery: 0.5 }), null)
  assert.equal(M.btLowActivity({ address: "AA:BB", name: "Mouse", battery: -1 }), null)
  const low = M.btLowActivity({ address: "AA:BB", name: "Mouse", battery: 0.12 })
  assert.equal(low.id, "btlow:AA:BB")
  assert.equal(low.title, "Mouse battery low")
  assert.equal(low.signature, "low:3")
})

test("rain alert: likely soon or in the next slot, not while raining", () => {
  const w = (rain0, rain1, raining) => ({ raining, location: "Here", hours: [{ hour: 12, rain: rain0 }, { hour: 15, rain: rain1 }] })
  assert.equal(M.rainActivity(w(10, 20, false)), null)
  assert.equal(M.rainActivity(w(80, 90, true)), null)
  assert.equal(M.rainActivity(w(70, 0, false)).title, "Rain likely soon")
  const a = M.rainActivity(w(20, 75, false))
  assert.equal(a.title, "Rain likely around 15:00")
  assert.equal(a.subtitle, "75% chance · Here")
  assert.equal(a.signature, "rain:15")
  assert.equal(M.rainActivity(null), null)
})
