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
  const base = { list, focusId: "timer", knownIds: { timer: true, media: true }, autoFocus: true, manualUntil: 0, now: 100 }
  assert.equal(M.resolveFocus(base), "privacy")
  assert.equal(M.resolveFocus({ ...base, autoFocus: false }), "timer")
  assert.equal(M.resolveFocus({ ...base, manualUntil: 200 }), "timer")
  assert.equal(M.resolveFocus({ ...base, focusId: "privacy", knownIds: { privacy: true, timer: true } }), "privacy")
  assert.equal(M.resolveFocus({ ...base, focusId: "gone", knownIds: { privacy: true, timer: true, media: true } }), "privacy")
  assert.equal(M.resolveFocus({ ...base, list: [] }), "")
})

test("prefs normalize and store only non-defaults", () => {
  const p = M.normalizePrefs({ moduleCharging: false, whenEmpty: "weird", maxWidth: 5000, autoFocus: "yes" })
  assert.equal(p.modules.charging, false)
  assert.equal(p.modules.media, true)
  assert.equal(p.whenEmpty, "brief")
  assert.equal(M.normalizePrefs({ whenEmpty: "icon" }).whenEmpty, "icon")
  assert.equal(p.textMode, "scroll")
  assert.equal(p.coverAccent, true)
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

test("Now Brief", () => {
  assert.deepEqual(M.parseWeather("\u{f0599}\n+22°C|Sunny"), { icon: "\u{f0599}", temp: "22°C", condition: "Sunny" })
  assert.equal(M.parseWeather("\nUnknown location; please try ~-23,-46").temp, "")
  assert.equal(M.briefInfo({ weather: {}, reminders: [], updates: false, now: 0 }), null)
  const now = new Date(2026, 9, 6, 9, 0).getTime()
  const b = M.briefInfo({
    weather: { icon: "\u{f0599}", temp: "22°C", condition: "Sunny" },
    reminders: [{ label: "Tea", at: new Date(2026, 9, 6, 9, 30).getTime() }],
    updates: true,
    now
  })
  assert.equal(b.pillText, "22°C  ·  \u{f088c} 9:30  ·  \u{f06b0} Update")
  assert.equal(b.lines.length, 3)
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
