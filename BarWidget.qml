import QtQuick
import QtQuick.Controls as QQC
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import qs.Ui
import qs.Commons
import "NowbarModel.js" as Model

// The pill in the bar shows the focused activity; scroll switches between
// activities, left click opens the carousel popup. The list and the focus
// live in Service.qml, so every monitor's pill shows the same thing.
Panel {
  id: root
  moduleName: "vinicgobbi.nowbar"
  // The service owns the "nowbar" IPC target; a per-monitor one would clash.
  manageIpc: false

  readonly property var service: bar && bar.shell ? bar.shell.serviceFor("vinicgobbi.nowbar") : null
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal

  // Options live inline on this widget's entry in shell.json (`settings`).
  // `pendingPrefs` shows a change right away and is dropped once the shell
  // hands back the reloaded settings.
  property var pendingPrefs: null
  readonly property var prefs: pendingPrefs ? pendingPrefs : Model.normalizePrefs(settings)
  onSettingsChanged: pendingPrefs = null

  function setPref(name, value) {
    var next = {}
    var d = Model.defaultPrefs()
    for (var k in d) next[k] = prefs[k]
    next[name] = value
    savePrefs(next)
  }

  function resetPrefs() { savePrefs(Model.defaultPrefs()) }

  function savePrefs(next) {
    var prefsNow = Model.normalizePrefs(next)
    pendingPrefs = prefsNow
    if (bar && bar.shell)
      bar.shell.updateEntryInline(moduleName, Model.entrySettings(prefsNow, settings))
  }

  // The service has no settings of its own: it follows this widget's.
  function syncServicePrefs() { if (service) service.prefs = prefs }
  onPrefsChanged: syncServicePrefs()
  onServiceChanged: syncServicePrefs()
  Component.onCompleted: syncServicePrefs()

  readonly property var activities: service ? service.activities : []
  readonly property int count: activities.length
  readonly property var focused: service ? service.focused : null
  readonly property int focusIndex: service ? service.focusIndex : -1

  // Only ever the local file the service downloaded and checked (see
  // Service.qml's refreshArt), never the player's raw URL.
  readonly property string coverUrl: focused && service && focused.id === service.artActivityId ? service.safeArtPath : ""
  // Screenshot cards show the file itself (a local file in the screenshots
  // folder; decoded at thumbnail size only).
  readonly property string shotUrl: focused && (focused.module === "screenshot" || focused.id === "recorded") && focused.image ? Util.fileUrl(focused.image) : ""
  readonly property string cardImage: coverUrl || shotUrl

  // The weather card is "ambient": it counts in the carousel and in the "2/3"
  // like any activity, but never takes the pill from a live one. Alone, it is
  // the Now Brief, shown only with "When nothing is going on" set to Brief.
  readonly property bool isWeather: focused !== null && focused.module === "weather"
  readonly property int realCount: activities.filter(function(a) { return !a.ambient }).length
  readonly property var pillItem: focused !== null
    && (!focused.ambient || realCount > 0 || prefs.whenEmpty === "brief") ? focused : null

  property bool settingsOpen: false

  // What the bottom of the popup shows (Quick tab of the options).
  readonly property bool quickTogglesShown: prefs.showQuickToggles && prefs.quickToggles.length > 0
  readonly property bool quickStartShown: prefs.showQuickStart && prefs.moduleTimer
    && (presets.length > 0 || prefs.quickStartExtras.length > 0)

  // `nowbar settings` reaches every monitor's widget; only the one whose popup
  // opens right after (or is already open) shows the options.
  property double settingsRequestedAt: 0

  Connections {
    target: root.service
    ignoreUnknownSignals: true
    function onSettingsRequested(tab) {
      if (tab !== "") settingsView.tab = tab
      root.settingsRequestedAt = Date.now()
      if (root.opened) root.settingsOpen = true
    }
  }
  onOpenedChanged: {
    unfold(opened)
    if (!opened) { settingsOpen = false; return }
    if (Date.now() - settingsRequestedAt < 2000) settingsOpen = true
    if (service) service.refreshWeatherIfStale()
  }

  // Back to the popup's own keys (after typing a timer).
  function forceKeyFocus() { keyCatcher.forceActiveFocus() }

  // Runs one of the focused card's actions. One that opens an app (Update,
  // Edit, Open) closes the popup first: the window it opens takes the focus,
  // and a popup left open over it would keep the keyboard (and, while a
  // password prompt is up, could get stuck open until the app is done).
  function runAction(action) {
    if (!service || !focused || !action) return
    var id = focused.id
    if (action.opensApp) close()
    service.act(id, action.id)
  }

  readonly property bool isMedia: focused !== null && focused.module === "media"

  // A media control: the focused card's action with that id, if it has it.
  function mediaAction(id) {
    if (!isMedia) return null
    for (var i = 0; i < focused.actions.length; i++) if (focused.actions[i].id === id) return focused.actions[i]
    return null
  }

  // Which way the track change slides: back for Previous, else forward.
  property int trackDir: 1
  function mediaKey(id) {
    var a = mediaAction(id)
    if (!a) return
    if (id === "previous") trackDir = -1
    else if (id === "next") trackDir = 1
    runAction(a)
  }

  // Another track on the same player. In the popup, the old title slides out
  // and fades while the new one comes in from the side of the change (the
  // cover crossfades by itself once loaded); the pill's text slides too.
  readonly property string trackKey: isMedia ? focused.id + "\n" + focused.title + "\n" + focused.subtitle : ""
  property string lastTrackKey: ""
  property string lastTitle: ""
  property string lastSubtitle: ""
  property string lastAlbum: ""
  property string ghostTitle: ""
  property string ghostSubtitle: ""
  property string ghostAlbum: ""
  onTrackKeyChanged: {
    var before = lastTrackKey.split("\n")[0]
    var now = trackKey.split("\n")[0]
    var sameplayer = now !== "" && now === before
    ghostTitle = lastTitle
    ghostSubtitle = lastSubtitle
    ghostAlbum = lastAlbum
    lastTrackKey = trackKey
    lastTitle = isMedia ? focused.title : ""
    lastSubtitle = isMedia ? focused.subtitle : ""
    lastAlbum = isMedia && focused.album !== focused.title ? focused.album : ""
    if (sameplayer && motion) {
      if (opened) {
        trackSwap.stop()
        ghostSlide.to = -trackDir * Style.space(36)
        trackSlide.from = trackDir * Style.space(40)
        trackShift.x = trackSlide.from
        liveText.opacity = 0
        trackSwap.start()
      }
      if (pillItem !== null && pillItem.id === now) {
        slideFrom = trackDir
        pillSwap.restart()
      }
    }
    trackDir = 1
  }

  ParallelAnimation {
    id: trackSwap
    // The old title leaves quickly; the new one only starts once it is
    // nearly gone, so the two never sit on top of each other.
    NumberAnimation { id: ghostSlide; target: ghostShift; property: "x"; from: 0; duration: 200; easing.type: Easing.InCubic }
    NumberAnimation { target: ghostText; property: "opacity"; from: 1; to: 0; duration: 160; easing.type: Easing.InQuad }
    SequentialAnimation {
      PauseAnimation { duration: 150 }
      ParallelAnimation {
        NumberAnimation { id: trackSlide; target: trackShift; property: "x"; to: 0; duration: 460; easing.type: Easing.OutQuint }
        NumberAnimation { target: liveText; property: "opacity"; to: 1; duration: 340; easing.type: Easing.OutCubic }
      }
    }
    // Whatever happens, end with the new text in place.
    onStopped: { trackShift.x = 0; liveText.opacity = 1; ghostText.opacity = 0 }
  }

  // Title, subtitle and (media) album, as the card shows them.
  component CardText: Column {
    property string title: ""
    property string subtitle: ""
    property string album: ""
    spacing: Style.space(3)

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: parent.title
      color: root.popupFg
      font.family: root.family
      font.pixelSize: Style.font.subtitle
      font.bold: true
      elide: Text.ElideRight
    }

    Text {
      width: parent.width
      visible: text !== ""
      textFormat: Text.PlainText
      text: parent.subtitle
      color: Qt.darker(root.popupFg, 1.35)
      font.family: root.family
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Text {
      width: parent.width
      visible: text !== ""
      textFormat: Text.PlainText
      text: parent.album
      color: Qt.darker(root.popupFg, 1.6)
      font.family: root.family
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }
  }

  // Text on an accent-filled circle: dark on light colors, light on dark.
  function onAccent(c) {
    return (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) > 0.6 ? Qt.rgba(0.07, 0.07, 0.08, 1) : Qt.rgba(1, 1, 1, 1)
  }

  // One round media button; the primary one (play/pause) is filled with the
  // accent. `on` lights shuffle / repeat.
  component MediaKey: Item {
    id: mk
    property string actionId: ""
    property bool primary: false
    property bool on: false
    property string tip: ""
    // Play/pause the biggest, previous/next a size down, the rest smaller.
    readonly property bool transport: actionId === "previous" || actionId === "next"
    readonly property var action: root.mediaAction(actionId)
    visible: action !== null
    width: Style.space(primary ? 50 : (transport ? 38 : 32))
    height: width
    // Keys of different sizes, centered on one line (a Row lines them up by
    // the top otherwise).
    anchors.verticalCenter: parent ? parent.verticalCenter : undefined
    scale: mkArea.pressed ? 0.88 : 1

    Behavior on scale {
      enabled: root.motion
      NumberAnimation { duration: 120; easing.type: Easing.OutCubic }
    }

    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: mk.primary ? root.accentFor(root.focused) : Util.alpha(root.popupFg, mkArea.containsMouse ? 0.12 : 0)
      // Only the hover; the accent animates by itself (coverAccent).
      Behavior on color {
        enabled: root.motion && !mk.primary
        ColorAnimation { duration: 160 }
      }
    }

    Text {
      anchors.centerIn: parent
      // The play triangle looks off to the left when centered by its box.
      anchors.horizontalCenterOffset: mk.action && mk.action.icon === "\u{f040a}" ? Math.round(width * 0.08) : 0
      textFormat: Text.PlainText
      text: mk.action ? mk.action.icon : ""
      color: mk.primary ? root.onAccent(root.accentFor(root.focused)) : (mk.on ? root.accentFor(root.focused) : root.popupFg)
      opacity: mk.primary || mk.on || mk.actionId !== "shuffle" && mk.actionId !== "loop" ? 1 : 0.55
      font.family: root.family
      font.pixelSize: mk.primary ? Style.font.displayLarge : (mk.transport ? Style.font.display : Style.font.iconLarge)
    }

    // A dot under shuffle / repeat while on.
    Rectangle {
      visible: mk.on
      width: Style.space(4)
      height: width
      radius: width / 2
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      color: root.accentFor(root.focused)
    }

    MouseArea {
      id: mkArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.mediaKey(mk.actionId)
    }

    // Same look as the shell's buttons' tooltips.
    QQC.ToolTip {
      visible: mk.tip !== "" && mkArea.containsMouse
      text: mk.tip
      delay: 400
      padding: 0
      background: BorderSurface {
        color: Color.tooltip.background
        borderSpec: Border.localOrSurfaceSpec("tooltip", "border", Color.tooltip.border, Color.tooltip.border, Math.max(1, Style.normalBorderWidth))
        radius: 0
      }
      contentItem: Text {
        textFormat: Text.PlainText
        text: mk.tip
        color: Color.tooltip.text
        font.family: root.family
        font.pixelSize: Style.font.bodySmall
        leftPadding: Style.spacing.controlPaddingX
        rightPadding: Style.spacing.controlPaddingX
        topPadding: Style.spacing.controlPaddingY
        bottomPadding: Style.spacing.controlPaddingY
      }
    }
  }

  // --- motion -------------------------------------------------------------------

  // Off with the "Animations" option, and while the bar repaints for a theme
  // change (like the shell's own widgets).
  readonly property bool motion: prefs.animations && (!bar || bar.foregroundAnimationEnabled)

  // The popup unfolds from the pill: 0 is the pill's size, 1 the full card.
  // Closing folds it back while the shell fades the card out (140 ms), so it
  // has to fit in that time.
  property real reveal: 0
  // Drives the sections coming in one after the other (see stage()).
  property real entrance: 1

  function unfold(open) {
    revealAnim.stop()
    entranceAnim.stop()
    if (!motion) { reveal = open ? 1 : 0; entrance = 1; return }
    revealAnim.to = open ? 1 : 0
    revealAnim.duration = open ? 380 : 140
    revealAnim.easing.type = open ? Easing.OutQuint : Easing.InCubic
    revealAnim.start()
    if (open) { entrance = 0; entranceAnim.start() }
  }

  NumberAnimation { id: revealAnim; target: root; property: "reveal" }
  NumberAnimation { id: entranceAnim; target: root; property: "entrance"; from: 0; to: 1; duration: 520 }

  // How far section `i` of the popup has come in, eased: each one starts
  // 55 ms after the one above it and takes 320 ms.
  function stage(i) {
    var t = Math.max(0, Math.min(1, (entrance * 520 - i * 55) / 320))
    return 1 - Math.pow(1 - t, 3)
  }

  function enterShiftX(i) { return (1 - stage(i)) * enterDX }
  function enterShiftY(i) { return (1 - stage(i)) * enterDY }

  // Sections come in from the bar's side.
  readonly property string barPos: bar ? bar.position : "top"
  readonly property real enterDX: barPos === "left" ? -Style.space(10) : (barPos === "right" ? Style.space(10) : 0)
  readonly property real enterDY: barPos === "top" ? -Style.space(10) : (barPos === "bottom" ? Style.space(10) : 0)

  // Full size of the popup; the height follows the content (another card,
  // the options) smoothly once the popup is open.
  // The options are a bit wider: five tabs in one row.
  property real popupFullWidth: popup.fittedContentWidth(Style.space(settingsOpen ? 420 : 360))
  Behavior on popupFullWidth {
    enabled: root.motion && root.opened && root.reveal === 1
    NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
  }
  property real popupFullHeight: popup.fittedContentHeight(settingsOpen ? settingsView.implicitHeight : column.implicitHeight)
  Behavior on popupFullHeight {
    // Not while the card's own height animates: then it already follows it.
    enabled: root.motion && root.opened && root.reveal === 1 && !cardHeightAnim.running
    NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
  }
  readonly property real popupInsetW: popup.padding * 2 + Border.left(popupBorderSpec) + Border.right(popupBorderSpec)

  // Options <-> carousel: the one coming in slides from its side.
  onSettingsOpenChanged: {
    viewIn.stop()
    columnShift.x = 0
    settingsShift.x = 0
    column.opacity = 1
    settingsFlick.opacity = 1
    if (!motion || !opened) return
    viewSwap.from = (settingsOpen ? 1 : -1) * Style.space(28)
    viewSwap.target = settingsOpen ? settingsShift : columnShift
    viewFade.target = settingsOpen ? settingsFlick : column
    viewIn.start()
  }

  ParallelAnimation {
    id: viewIn
    NumberAnimation { id: viewSwap; property: "x"; to: 0; duration: 280; easing.type: Easing.OutQuint }
    NumberAnimation { id: viewFade; property: "opacity"; from: 0; to: 1; duration: 200; easing.type: Easing.OutCubic }
  }

  readonly property bool shown: realCount > 0 || prefs.whenEmpty !== "hide"
  visible: shown
  implicitWidth: shown ? (vertical ? barSize : pill.width + Style.space(8)) : 0
  implicitHeight: shown ? (vertical ? pill.height + Style.space(8) : barSize) : 0

  readonly property real openPanelIndicatorWidth: pill.width
  readonly property real openPanelIndicatorHeight: pill.height

  readonly property bool tooltipHovered: pillArea.containsMouse && !opened

  readonly property color fg: bar ? bar.barForeground : Color.foreground
  readonly property color popupFg: bar ? bar.foreground : Color.foreground
  readonly property string family: bar ? bar.fontFamily : Style.font.family

  // Media takes its accent from the cover (Service.qml's artAccent) when that
  // option is on and the cover has a real color; everything else uses the theme.
  // Blends into the next cover's color instead of switching at once (the
  // play button, bars, border and pill follow it). Mixed in OKLab, like CSS
  // color-mix: straight RGB goes through a muddy gray between opposite
  // colors (blue -> orange), turning the hue goes through a rainbow.
  readonly property color coverAccentTarget: service && service.artAccent !== "" ? Qt.lighter(service.artAccent, 1.0) : Color.accent
  property color accentFrom: coverAccentTarget
  property color accentTo: coverAccentTarget
  property real accentMix: 1
  readonly property color coverAccent: accentMix >= 1 ? accentTo : Model.mixOklab(accentFrom, accentTo, accentMix)
  onCoverAccentTargetChanged: {
    accentAnim.stop()
    if (!motion) { accentFrom = coverAccentTarget; accentTo = coverAccentTarget; accentMix = 1; return }
    accentFrom = coverAccent
    accentTo = coverAccentTarget
    accentMix = 0
    accentAnim.start()
  }
  NumberAnimation { id: accentAnim; target: root; property: "accentMix"; from: 0; to: 1; duration: 480; easing.type: Easing.InOutQuad }
  readonly property bool hasCoverAccent: prefs.coverAccent && service !== null && service.artAccent !== ""

  // The popup itself also takes the cover's colors on the media card whose
  // cover is shown: the border gets the accent, the background a tint of the
  // cover's main color (kept as dark, or as light, as the theme's so the
  // text stays readable). Same "Cover colors" option.
  readonly property bool darkTheme: {
    var c = Color.popups.background
    return (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) < 0.5
  }
  // The weather card does the same with the color of the sky.
  readonly property bool mediaThemed: prefs.coverAccent && !settingsOpen && focused !== null && service !== null
    && focused.id === service.artActivityId && service.artBase !== "" && service.artAccent !== ""
  readonly property bool weatherThemed: prefs.coverAccent && !settingsOpen && isWeather && !!focused.color
  // Urgent activities (camera/mic in use, recording, low battery, a failed
  // script) turn the popup red like the pill: always, like the pill, not only
  // with "Dynamic colors".
  readonly property bool urgentThemed: !settingsOpen && focused !== null && focused.urgent === true
  // Charging is good news: blue to green, whatever the percentage. Always on,
  // like the urgent red.
  readonly property color chargeBlue: darkTheme ? "#38bdf8" : "#0284c7"
  readonly property color chargeGreen: darkTheme ? "#4ade80" : "#16a34a"
  function isCharging(activity) { return !!activity && activity.id === "charging" }
  readonly property bool pillCharging: isCharging(pillItem)
  readonly property bool chargeThemed: !settingsOpen && isCharging(focused)
  readonly property bool popupThemed: urgentThemed || chargeThemed || mediaThemed || weatherThemed
  readonly property string popupTint: urgentThemed ? Model.surfaceTint(Color.urgent.toString().slice(0, 7), darkTheme)
    : chargeThemed ? Model.surfaceTint("#14b8a6", darkTheme)
    : (mediaThemed ? Model.surfaceTint(service.artBase, darkTheme)
    : (weatherThemed ? Model.surfaceTint(focused.color, darkTheme) : ""))
  readonly property color popupAccent: urgentThemed ? Color.urgent
    : chargeThemed ? chargeGreen
    : (mediaThemed ? coverAccent : (weatherThemed ? Qt.lighter(focused.color, 1.0) : Color.accent))
  readonly property var themeBorderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
  readonly property var popupBorderSpec: chargeThemed
    ? { color: chargeGreen, widths: themeBorderSpec.widths, gradient: { colors: [chargeBlue.toString(), chargeGreen.toString()], angle: 0, enabled: true } }
    : popupThemed
    ? { color: popupAccent, widths: themeBorderSpec.widths, gradient: { colors: [], angle: 0, enabled: false } }
    : themeBorderSpec

  function accentFor(activity) {
    if (activity && activity.urgent) return Color.urgent
    if (isCharging(activity)) return chargeGreen
    if (activity && activity.module === "media" && hasCoverAccent) return coverAccent
    if (activity && activity.module === "weather" && activity.color && prefs.coverAccent) return Qt.lighter(activity.color, 1.0)
    return Color.accent
  }

  // A notch of a mouse wheel is 120; touchpads send many small deltas, so
  // they are added up until they make one notch.
  property real wheelAccum: 0
  function wheelStep(delta) {
    if (!service) return
    wheelAccum += delta
    if (Math.abs(wheelAccum) < 120) return
    service.step(wheelAccum > 0 ? -1 : 1)
    wheelAccum = 0
    lastWheelAt = Date.now()
  }
  // A switch made by scrolling doesn't get the "something new" bump.
  property double lastWheelAt: 0

  // Direction of the last switch, for the slide animation.
  property int slideFrom: 1
  property int lastIndex: -1
  property string lastFocusId: ""
  onFocusIndexChanged: {
    if (focusIndex >= 0 && lastIndex >= 0 && focused && focused.id !== lastFocusId)
      slideFrom = focusIndex > lastIndex ? 1 : -1
    lastIndex = focusIndex
  }
  onFocusedChanged: {
    var id = focused ? focused.id : ""
    if (id === lastFocusId) return
    lastFocusId = id
    if (!motion) { pillSwap.complete(); cardSwap.complete(); return }
    pillSwap.restart()
    cardSwap.restart()
    // An activity that took the pill on its own (closed popup, no scrolling).
    if (id !== "" && !opened && Date.now() - lastWheelAt > 800) pillBump.restart()
  }

  // Something urgent came up (camera on, recording, low battery...): the pill
  // pulses red a few times, then stays red without moving.
  readonly property string urgentKey: pillItem !== null && pillItem.urgent ? pillItem.id : ""
  onUrgentKeyChanged: {
    urgentPulse.stop()
    pulse = 0
    if (urgentKey !== "" && motion) urgentPulse.start()
  }
  property real pulse: 0

  readonly property bool attention: pillItem !== null && (pillItem.ending === true || pillItem.done === true)
  property real glow: 0
  SequentialAnimation {
    running: root.attention && root.motion
    loops: Animation.Infinite
    onRunningChanged: if (!running) root.glow = 0
    NumberAnimation { target: root; property: "glow"; to: 1; duration: 450; easing.type: Easing.InOutSine }
    NumberAnimation { target: root; property: "glow"; to: 0; duration: 550; easing.type: Easing.InOutSine }
  }

  SequentialAnimation {
    id: urgentPulse
    loops: 3
    NumberAnimation { target: root; property: "pulse"; to: 1; duration: 380; easing.type: Easing.InOutSine }
    NumberAnimation { target: root; property: "pulse"; to: 0; duration: 520; easing.type: Easing.InOutSine }
  }

  // A circle filling clockwise from the top: how far a countdown has gone.
  component Ring: Shape {
    id: ring
    property real progress: 0
    property color color: root.fg
    property real thickness: Math.max(2, Style.space(2))
    preferredRendererType: Shape.CurveRenderer
    // Countdowns tick each second: sweep there instead of stepping.
    Behavior on progress {
      enabled: root.motion
      NumberAnimation { duration: 950 }
    }

    ShapePath {
      strokeColor: Util.alpha(ring.color, 0.22)
      strokeWidth: ring.thickness
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      PathAngleArc {
        centerX: ring.width / 2; centerY: ring.height / 2
        radiusX: (ring.width - ring.thickness) / 2; radiusY: radiusX
        startAngle: -90; sweepAngle: 360
      }
    }

    ShapePath {
      strokeColor: ring.color
      strokeWidth: ring.thickness
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap
      PathAngleArc {
        centerX: ring.width / 2; centerY: ring.height / 2
        radiusX: (ring.width - ring.thickness) / 2; radiusY: radiusX
        startAngle: -90; sweepAngle: 360 * Math.max(0, Math.min(1, ring.progress))
      }
    }
  }

  // Three bars bouncing at their own pace: something is playing.
  component Equalizer: Row {
    id: eq
    property color color: root.fg
    property bool running: false
    spacing: Style.space(2)

    Repeater {
      model: [{ rest: 0.55, period: 460 }, { rest: 1.0, period: 340 }, { rest: 0.4, period: 560 }]

      Rectangle {
        required property var modelData
        property real level: modelData.rest
        anchors.bottom: parent.bottom
        width: Math.max(2, Style.space(3))
        height: Math.max(width, eq.height * level)
        radius: width / 2
        color: eq.color

        SequentialAnimation on level {
          running: eq.running
          loops: Animation.Infinite
          NumberAnimation { to: 1.0; duration: modelData.period; easing.type: Easing.InOutSine }
          NumberAnimation { to: 0.25; duration: modelData.period * 1.2; easing.type: Easing.InOutSine }
        }
      }
    }
  }

  // One cover image: sharp, or blurred (cut to `mask`) for the backdrop.
  component CoverLayer: Item {
    id: cl
    property url source: ""
    property bool blurred: false
    property Item mask: null
    readonly property bool ready: img.status === Image.Ready && String(img.source) !== ""
    opacity: 0

    Image {
      id: img
      anchors.fill: parent
      visible: !cl.blurred
      source: cl.source
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      // Blurred, a small one does (and is cheaper to blur).
      sourceSize.width: cl.blurred ? 96 : 256
      sourceSize.height: cl.blurred ? 96 : 256
    }

    MultiEffect {
      anchors.fill: parent
      visible: cl.blurred
      source: img
      autoPaddingEnabled: false
      blurEnabled: true
      blur: 1.0
      blurMax: 48
      saturation: 0.2
      maskEnabled: cl.mask !== null
      maskSource: cl.mask
    }
  }

  // A cover that changes by crossfading: the new image loads behind the one
  // shown and only takes its place once ready (never a blank in between),
  // coming in with a slight zoom. An empty source fades it all out.
  component CoverSwap: Item {
    id: cs
    property url source: ""
    property bool blurred: false
    property Item mask: null
    property real enterScale: 0.94
    property int front: 0
    readonly property bool showing: la.opacity > 0.01 || lb.opacity > 0.01

    function layerAt(i) { return i === 0 ? la : lb }

    function load() {
      if (String(source) === "") {
        swap.stop()
        if (root.motion) { outAll.restart() } else { la.opacity = 0; lb.opacity = 0 }
        return
      }
      var shown = layerAt(front)
      if (String(shown.source) === String(source) && shown.ready) { landed(shown); return }
      var back = layerAt(1 - front)
      back.source = source
      if (back.ready) Qt.callLater(function() { cs.landed(back) })
    }

    function landed(layer) {
      if (!layer.ready || String(layer.source) !== String(source)) return
      var old = layerAt(front)
      front = layer === la ? 0 : 1
      swap.stop()
      outAll.stop()
      if (!root.motion) {
        layer.opacity = 1; layer.scale = 1
        if (old !== layer) old.opacity = 0
        return
      }
      // The new one on top, fading in over the old one, which stays whole
      // underneath (no dip to the background halfway) and goes once covered.
      layer.z = 1
      if (old !== layer) old.z = 0
      fadeIn.target = layer
      zoomIn.target = layer
      fadeOut.target = old !== layer ? old : nobody
      swap.start()
    }

    onSourceChanged: load()
    Component.onCompleted: load()

    // Stand-in target when there is no old cover to fade out.
    Item { id: nobody; visible: false }

    CoverLayer { id: la; anchors.fill: parent; blurred: cs.blurred; mask: cs.mask; onReadyChanged: cs.landed(la) }
    CoverLayer { id: lb; anchors.fill: parent; blurred: cs.blurred; mask: cs.mask; onReadyChanged: cs.landed(lb) }

    ParallelAnimation {
      id: swap
      NumberAnimation { id: fadeIn; property: "opacity"; to: 1; duration: 420; easing.type: Easing.OutCubic }
      NumberAnimation { id: zoomIn; property: "scale"; from: cs.enterScale; to: 1; duration: 520; easing.type: Easing.OutQuint }
      SequentialAnimation {
        PauseAnimation { duration: 420 }
        NumberAnimation { id: fadeOut; property: "opacity"; to: 0; duration: 1 }
      }
    }

    ParallelAnimation {
      id: outAll
      NumberAnimation { target: la; property: "opacity"; to: 0; duration: 260 }
      NumberAnimation { target: lb; property: "opacity"; to: 0; duration: 260 }
    }
  }

  // Charge level, blue to green, with a wave of light running through it.
  component ChargeWave: Item {
    id: wave
    property real level: 0
    property real fillOpacity: 1
    property real shineOpacity: 0.5
    property bool running: false

    Rectangle {
      id: chargeFill
      width: wave.width * Math.max(0, Math.min(1, wave.level))
      height: wave.height
      radius: height / 2
      opacity: wave.fillOpacity
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0.0; color: root.chargeBlue }
        GradientStop { position: 1.0; color: root.chargeGreen }
      }
      Behavior on width {
        enabled: root.motion
        NumberAnimation { duration: 600; easing.type: Easing.OutCubic }
      }
    }

    // Only over the charged part.
    Item {
      width: chargeFill.width
      height: wave.height
      clip: true

      Rectangle {
        id: shine
        width: Math.max(wave.height * 3, wave.width * 0.3)
        height: wave.height
        radius: height / 2
        x: -width
        opacity: wave.shineOpacity
        gradient: Gradient {
          orientation: Gradient.Horizontal
          GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0) }
          GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, 0.9) }
          GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0) }
        }
      }
    }

    SequentialAnimation {
      running: wave.running && wave.visible && root.motion
      loops: Animation.Infinite
      onRunningChanged: if (!running) shine.x = -shine.width
      NumberAnimation { target: shine; property: "x"; from: -shine.width; to: chargeFill.width; duration: 1700; easing.type: Easing.InOutSine }
      PauseAnimation { duration: 1000 }
    }
  }

  // --- the pill ---------------------------------------------------------------

  Rectangle {
    id: pill
    anchors.centerIn: parent

    readonly property bool hasActivity: root.pillItem !== null
    readonly property real textMax: root.prefs.maxWidth
    readonly property real progress: hasActivity && root.prefs.showProgress ? root.pillItem.progress : -1

    height: root.vertical ? pillContent.implicitHeight + Style.space(12) : Math.max(Style.space(18), root.barSize - Style.space(10))
    width: root.vertical ? Math.max(Style.space(18), root.barSize - Style.space(10)) : pillContent.implicitWidth + Style.space(16)
    radius: Math.min(width, height) / 2
    color: root.pillCharging
      ? Util.alpha(root.chargeBlue, pillArea.containsMouse || root.opened ? 0.2 : 0.12)
      : hasActivity
      ? Util.alpha(root.accentFor(root.pillItem), pillArea.containsMouse || root.opened ? 0.28 : 0.18)
      : Util.alpha(root.fg, pillArea.containsMouse || root.opened ? 0.14 : 0.07)
    border.width: hasActivity && root.pillItem.urgent ? Math.max(1, Style.space(1)) : 0
    border.color: Util.alpha(Color.urgent, 0.8)
    clip: true

    // Pressed in a little while held.
    scale: root.motion && pillArea.pressed ? 0.94 : 1
    Behavior on scale {
      enabled: root.motion
      NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
    }

    transform: Scale {
      id: bumpScale
      origin.x: pill.width / 2
      origin.y: pill.height / 2
    }

    Behavior on color {
      enabled: !root.bar || root.bar.foregroundAnimationEnabled
      ColorAnimation { duration: 220; easing.type: Easing.OutCubic }
    }

    // Grows a touch and settles back, springy.
    SequentialAnimation {
      id: pillBump
      ParallelAnimation {
        NumberAnimation { target: bumpScale; property: "xScale"; to: 1.07; duration: 140; easing.type: Easing.OutCubic }
        NumberAnimation { target: bumpScale; property: "yScale"; to: 1.07; duration: 140; easing.type: Easing.OutCubic }
      }
      ParallelAnimation {
        NumberAnimation { target: bumpScale; property: "xScale"; to: 1; duration: 420; easing.type: Easing.OutBack; easing.overshoot: 2.2 }
        NumberAnimation { target: bumpScale; property: "yScale"; to: 1; duration: 420; easing.type: Easing.OutBack; easing.overshoot: 2.2 }
      }
    }

    // Charging: the pill itself fills up to the charge.
    ChargeWave {
      anchors.fill: parent
      visible: root.pillCharging
      level: root.pillCharging ? root.pillItem.progress : 0
      fillOpacity: 0.32
      shineOpacity: 0.28
      running: root.pillCharging
    }

    // A countdown's last seconds, "Time's up", a reminder going off: the pill
    // glows in its color, on and off, while it lasts.
    Rectangle {
      anchors.fill: parent
      radius: pill.radius
      color: root.accentFor(root.pillItem)
      opacity: 0.35 * root.glow
      visible: opacity > 0
    }

    // Red wash for the urgent pulse, under the text.
    Rectangle {
      anchors.fill: parent
      radius: pill.radius
      color: Color.urgent
      opacity: 0.35 * root.pulse
      visible: opacity > 0
    }

    // Horizontal: icon, text, "2/4", each in a fixed slot so the pill keeps
    // the same size whatever it shows. Vertical bars only have room for the icon.
    Row {
      id: pillContent
      anchors.centerIn: parent
      spacing: Style.space(6)

      // Media playing: three little bars dancing; anything else: its icon.
      Item {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(16)
        height: pillIcon.implicitHeight
        readonly property bool playing: pill.hasActivity && root.pillItem.module === "media" && root.pillItem.playing === true
        // Timer, Pomodoro, sleep timer: a little ring that fills up.
        readonly property bool countdown: pill.hasActivity && root.pillItem.module === "timer" && root.pillItem.progress >= 0
        readonly property bool recordingNow: pill.hasActivity && root.pillItem.id === "recording"

        Text {
          id: pillIcon
          anchors.fill: parent
          visible: !parent.playing && !parent.countdown && !parent.recordingNow
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          textFormat: Text.PlainText
          text: pill.hasActivity ? root.pillItem.icon : "\u{f0996}"
          color: pill.hasActivity && root.pillItem.urgent ? Color.urgent : (root.pillCharging ? root.chargeGreen : root.fg)
          opacity: pill.hasActivity ? 1 : 0.6
          font.family: root.family
          font.pixelSize: Style.font.body
        }

        Ring {
          anchors.centerIn: parent
          visible: parent.countdown
          width: Style.space(13)
          height: width
          thickness: Math.max(2, Style.space(2))
          progress: parent.countdown ? root.pillItem.progress : 0
          color: root.accentFor(root.pillItem)
        }

        // Recording: a red dot breathing, like a camera's.
        Rectangle {
          anchors.centerIn: parent
          visible: parent.recordingNow
          width: Style.space(9)
          height: width
          radius: width / 2
          color: Color.urgent

          SequentialAnimation on opacity {
            running: root.motion && parent.visible
            loops: Animation.Infinite
            onRunningChanged: if (!running) parent.opacity = 1
            NumberAnimation { to: 0.3; duration: 700; easing.type: Easing.InOutSine }
            NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutSine }
          }
        }

        Equalizer {
          anchors.centerIn: parent
          visible: parent.playing
          height: Style.space(11)
          color: root.accentFor(root.pillItem)
          running: parent.playing && root.motion
        }
      }

      // Text longer than the slot either scrolls around (two copies side by
      // side, so it loops without a gap) or is cut with "...". Whether it
      // fits is measured on a hidden copy, so it never depends on how the
      // visible text is laid out.
      Item {
        id: textClip
        visible: !root.vertical
        anchors.verticalCenter: parent.verticalCenter
        width: pill.textMax
        height: measure.implicitHeight
        clip: true

        readonly property string label: pill.hasActivity ? root.pillItem.pillText : "Nothing going on"
        readonly property real gap: Style.space(28)
        readonly property real fullWidth: measure.implicitWidth
        readonly property bool overflows: fullWidth > width
        readonly property bool scrolling: root.prefs.textMode === "scroll" && overflows && !root.vertical
        // Briefly off when the text changes, so the marquee starts over
        // (restart() would break the `running` binding).
        property bool holding: false

        Text {
          id: measure
          visible: false
          textFormat: Text.PlainText
          text: textClip.label
          font.family: root.family
          font.pixelSize: Style.font.body
        }

        // Fits, or "Cut" mode: one line, centered, "..." when too long.
        Text {
          visible: !textClip.scrolling
          width: textClip.width
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: textClip.label
          horizontalAlignment: textClip.overflows ? Text.AlignLeft : Text.AlignHCenter
          elide: Text.ElideRight
          color: root.fg
          opacity: pill.hasActivity ? 1 : 0.6
          font.family: root.family
          font.pixelSize: Style.font.body
        }

        Row {
          id: marqueeRow
          visible: textClip.scrolling
          anchors.verticalCenter: parent.verticalCenter
          spacing: textClip.gap

          Repeater {
            model: 2

            Text {
              textFormat: Text.PlainText
              text: textClip.label
              color: root.fg
              font.family: root.family
              font.pixelSize: Style.font.body
            }
          }
        }

        SequentialAnimation {
          id: marquee
          running: textClip.scrolling && !textClip.holding
          loops: Animation.Infinite
          onRunningChanged: if (!running) marqueeRow.x = 0
          PauseAnimation { duration: 1500 }
          NumberAnimation {
            target: marqueeRow
            property: "x"
            from: 0
            to: -(textClip.fullWidth + textClip.gap)
            duration: Math.max(2000, (textClip.fullWidth + textClip.gap) * 30)
          }
        }

        onLabelChanged: {
          holding = true
          Qt.callLater(function() { textClip.holding = false })
        }
      }

      Item {
        visible: !root.vertical && root.prefs.showCount
        anchors.verticalCenter: parent.verticalCenter
        width: countMetrics.width
        height: countText.implicitHeight

        TextMetrics {
          id: countMetrics
          font: countText.font
          text: "8/8"
        }

        Text {
          id: countText
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: root.count > 1 && root.pillItem !== null ? (root.focusIndex + 1) + "/" + root.count : ""
          color: Qt.darker(root.fg, 1.5)
          font.family: root.family
          font.pixelSize: Style.font.caption
        }
      }
    }

    // Thin progress line along the bottom of the pill (charging fills the
    // whole pill instead).
    // Glides like the popup's bar: straight to each new second while media
    // plays, quickly on a jump, at once for another activity.
    Rectangle {
      id: pillLine
      visible: pill.progress >= 0 && !root.vertical && !root.pillCharging
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      anchors.leftMargin: pill.radius / 2
      anchors.bottomMargin: Math.max(1, Style.space(1))
      height: Math.max(2, Style.space(2))
      radius: height / 2
      width: Math.max(0, (pill.width - pill.radius) * value)
      color: root.accentFor(root.pillItem)

      readonly property real target: Math.max(0, Math.min(1, pill.progress))
      property real value: 0
      property string valueOf: ""
      onTargetChanged: {
        var a = root.pillItem
        var id = a ? a.id : ""
        pillGlide.stop()
        if (id !== valueOf || !root.motion) { valueOf = id; value = target; return }
        var media = a.module === "media"
        var ahead = (target - value) * (media ? a.length : 0)
        var flowing = media && a.playing && ahead > 0 && ahead < 2.5
        pillGlide.to = target
        pillGlide.duration = flowing ? 1050 : 320
        pillGlide.easing.type = flowing ? Easing.Linear : Easing.OutCubic
        pillGlide.start()
      }

      NumberAnimation { id: pillGlide; target: pillLine; property: "value" }
    }

    // Slide the content in from the side it came from.
    ParallelAnimation {
      id: pillSwap
      NumberAnimation { target: pillContent; property: "anchors.horizontalCenterOffset"; from: root.slideFrom * Style.space(18); to: 0; duration: 300; easing.type: Easing.OutQuint }
      NumberAnimation { target: pillContent; property: "opacity"; from: 0; to: 1; duration: 220; easing.type: Easing.OutCubic }
    }
  }

  MouseArea {
    id: pillArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton

    onClicked: function(mouse) {
      if (mouse.button === Qt.MiddleButton) {
        if (root.pillItem && root.service) root.service.primary(root.pillItem.id)
      } else if (mouse.button === Qt.RightButton) {
        if (root.pillItem && root.service) root.service.dismiss(root.pillItem.id)
      } else {
        root.toggle()
      }
    }
    onWheel: function(wheel) {
      var d = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : -wheel.angleDelta.x
      root.wheelStep(d)
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, Model.tooltipLabel(root.pillItem, root.focusIndex, root.count))
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  // --- popup --------------------------------------------------------------------

  readonly property var presets: prefs.presetSeconds

  KeyboardPanel {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.opened
    focusTarget: keyCatcher
    borderSpec: root.popupBorderSpec
    // From the pill's size to the full card (see `reveal`).
    contentWidth: Math.round(pill.width + (root.popupFullWidth - pill.width) * root.reveal)
    contentHeight: Math.round(pill.height + (root.popupFullHeight - pill.height) * root.reveal)

    // Cover-tinted background: fills the card inside its border (the content
    // area plus the padding around it), fading from the tint at the top to
    // the theme's background.
    Rectangle {
      id: tintLayer
      anchors.fill: parent
      anchors.margins: -popup.padding
      radius: Math.max(0, Style.cornerRadius - Border.top(root.popupBorderSpec))
      opacity: root.popupThemed ? 1 : 0
      property color tint: root.popupTint !== "" ? root.popupTint : Color.popups.background
      gradient: Gradient {
        GradientStop { position: 0.0; color: tintLayer.tint }
        GradientStop { position: 0.75; color: Qt.tint(Color.popups.background, Util.alpha(tintLayer.tint, 0.35)) }
        GradientStop { position: 1.0; color: Color.popups.background }
      }

      Behavior on opacity {
        enabled: !root.bar || root.bar.foregroundAnimationEnabled
        NumberAnimation { duration: 260 }
      }
      Behavior on tint {
        enabled: !root.bar || root.bar.foregroundAnimationEnabled
        ColorAnimation { duration: 450; easing.type: Easing.InOutQuad }
      }
    }

    // Media: the cover itself, blurred, behind everything (with "Dynamic
    // colors"), fading into the theme's background toward the bottom so the
    // rest of the popup reads as usual. Cut to the card's rounded corners.
    Item {
      id: coverBackdrop
      anchors.fill: tintLayer
      opacity: root.mediaThemed && backdropCovers.showing ? (root.darkTheme ? 0.5 : 0.35) : 0
      visible: opacity > 0

      Behavior on opacity {
        enabled: root.motion
        NumberAnimation { duration: 420; easing.type: Easing.InOutQuad }
      }

      Rectangle {
        id: backdropMask
        anchors.fill: parent
        radius: tintLayer.radius
        visible: false
        layer.enabled: true
      }

      // Crossfades to the next track's cover; no zoom, so nothing pokes out
      // past the rounded corners.
      CoverSwap {
        id: backdropCovers
        anchors.fill: parent
        blurred: true
        mask: backdropMask
        enterScale: 1
        source: root.mediaThemed ? root.coverUrl : ""
      }

      Rectangle {
        anchors.fill: parent
        radius: tintLayer.radius
        gradient: Gradient {
          GradientStop { position: 0.0; color: Util.alpha(Color.popups.background, 0.15) }
          GradientStop { position: 0.55; color: Util.alpha(Color.popups.background, 0.6) }
          GradientStop { position: 1.0; color: Color.popups.background }
        }
      }
    }

    // The content shows only as far as the card has unfolded.
    Item {
      anchors.fill: parent
      clip: true

      PanelKeyCatcher {
        id: keyCatcher
        // Laid out at the full size from the start, so nothing reflows while
        // the card unfolds; centered, and against the bar's side.
        width: root.popupFullWidth - root.popupInsetW
        height: root.popupFullHeight - popup.verticalContentInset
        x: Math.round((parent.width - width) / 2)
        y: root.barPos === "bottom" ? parent.height - height
          : (root.barPos === "left" || root.barPos === "right" ? Math.round((parent.height - height) / 2) : 0)
        blocked: (root.settingsOpen && settingsView.editing) || customTimer.activeFocus

        onMoveRequested: function(dx, dy) {
          if (!root.settingsOpen && dx !== 0 && root.service) root.service.step(dx)
        }
        onTabRequested: function(direction) {
          if (root.settingsOpen) settingsView.cycleTab(direction)
          else if (root.service) root.service.step(direction)
        }
        onActivateRequested: {
          if (!root.settingsOpen && root.focused && root.focused.actions.length > 0) root.runAction(root.focused.actions[0])
        }
        onDeleteRequested: {
          if (!root.settingsOpen && root.focused && root.service) root.service.dismiss(root.focused.id)
        }
        onCloseRequested: { if (root.settingsOpen) root.settingsOpen = false; else root.close() }
        onTextKey: function(t) {
          if (t === "q" || t === "Q") { if (root.settingsOpen) root.settingsOpen = false; else root.close(); return }
          if (t === "c" || t === "C") { root.settingsOpen = !root.settingsOpen; return }
          if (root.settingsOpen || !root.service || !root.quickStartShown) return
          var n = parseInt(t, 10)
          if (n >= 1 && n <= root.presets.length) root.service.startTimer(root.presets[n - 1])
          else if ((t === "s" || t === "S") && root.prefs.quickStartExtras.indexOf("stopwatch") !== -1) root.service.startStopwatch()
          else if ((t === "p" || t === "P") && root.prefs.quickStartExtras.indexOf("pomodoro") !== -1) root.service.startPomodoro()
        }

        Flickable {
          id: settingsFlick
          anchors.fill: parent
          transform: Translate { id: settingsShift }
          visible: root.settingsOpen
          contentWidth: width
          contentHeight: settingsView.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          AdvancedSettings {
            id: settingsView
            width: settingsFlick.width
            prefs: root.prefs
            foreground: root.popupFg
            fontFamily: root.family
            onChanged: function(name, value) { root.setPref(name, value) }
            onResetRequested: root.resetPrefs()
            // Each tab starts at its top.
            onTabChanged: settingsFlick.contentY = 0
            weatherWidgetState: root.service ? root.service.weatherWidgetState : ""
            indicatorsState: root.service ? root.service.indicatorsState : ""
            updateSourcesAvailable: root.service ? root.service.availableUpdateSources : []
            playerNames: root.service ? root.service.playerNames : []
            onIndicatorsRequested: function(replace) { if (root.service) root.service.setIndicators(replace) }
            onWeatherWidgetRequested: function(replace) { if (root.service) root.service.setWeatherWidget(replace) }
            onBackRequested: root.settingsOpen = false
          }
        }

        Column {
          id: column
          visible: !root.settingsOpen
          anchors.fill: parent
          transform: Translate { id: columnShift }
          spacing: Style.space(10)

          // ‹  • • ●  ›                         ⚙
          Item {
            width: parent.width
            opacity: root.stage(0)
            transform: Translate { x: root.enterShiftX(0); y: root.enterShiftY(0) }
            height: Math.max(prevButton.implicitHeight, gearButton.implicitHeight)

            Button {
              id: prevButton
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\u{f0141}"
              foreground: root.popupFg
              enabled: root.count > 1
              opacity: enabled ? 1 : 0.35
              tooltipText: "Previous (←)"
              onClicked: if (root.service) root.service.step(-1)
            }

            Item {
              anchors.left: prevButton.right
              anchors.right: nextButton.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom

              Row {
                id: dots
                anchors.centerIn: parent
                spacing: Style.space(6)

                Repeater {
                  model: root.activities

                  Rectangle {
                    required property var modelData
                    required property int index
                    readonly property bool current: index === root.focusIndex
                    anchors.verticalCenter: parent.verticalCenter
                    width: current ? Style.space(18) : Style.space(7)
                    height: Style.space(7)
                    radius: height / 2
                    color: current ? root.accentFor(modelData) : Util.alpha(root.popupFg, 0.3)

                    Behavior on width {
                      enabled: root.motion
                      NumberAnimation { duration: 260; easing.type: Easing.OutQuint }
                    }


                    MouseArea {
                      anchors.fill: parent
                      anchors.margins: -Style.space(4)
                      cursorShape: Qt.PointingHandCursor
                      onClicked: if (root.service) root.service.focusOn(parent.modelData.id)
                    }
                  }
                }
              }
            }

            Button {
              id: nextButton
              anchors.right: gearButton.left
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\u{f0142}"
              foreground: root.popupFg
              enabled: root.count > 1
              opacity: enabled ? 1 : 0.35
              tooltipText: "Next (→)"
              onClicked: if (root.service) root.service.step(1)
            }

            Button {
              id: gearButton
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\u{f0493}"
              foreground: root.popupFg
              tooltipText: "Options (c)"
              onClicked: root.settingsOpen = true
            }
          }

          // --- the focused activity's card ---
          Item {
            id: cardHolder
            width: parent.width
            height: root.focused ? card.implicitHeight : emptyCard.implicitHeight
            clip: true
            opacity: root.stage(1)
            transform: Translate { x: root.enterShiftX(1); y: root.enterShiftY(1) }

            // Another card, another height: the rest of the popup follows.
            Behavior on height {
              enabled: root.motion && root.opened && root.reveal === 1
              NumberAnimation { id: cardHeightAnim; duration: 300; easing.type: Easing.OutQuint }
            }

            Column {
              id: card
              width: parent.width
              visible: root.focused !== null
              spacing: Style.space(10)

              WeatherCard {
                width: parent.width
                visible: root.isWeather && !!root.focused.weather
                weather: root.isWeather ? root.focused.weather : null
                extraLines: root.isWeather ? root.focused.details : []
                foreground: root.popupFg
                accent: root.accentFor(root.focused)
                fontFamily: root.family
              }

              // One click to take over from Omarchy's weather widget (opt-in).
              Button {
                visible: root.isWeather && !!root.service && root.service.weatherWidgetState === "native"
                iconText: "\u{f0599}"
                text: "Use instead of the weather widget"
                foreground: root.popupFg
                accent: root.accentFor(root.focused)
                tooltipText: "Turns Omarchy's weather widget off and points SUPER+CTRL+ALT+W here (undo in the options)"
                onClicked: root.service.setWeatherWidget(true)
              }

              Row {
                width: parent.width
                spacing: Style.space(12)
                visible: !(root.isWeather && !!root.focused.weather)

                Rectangle {
                  id: cardIcon
                  // Media with cover art gets the cover, like omarchy-plugin-media;
                  // a screenshot gets its thumbnail.
                  readonly property bool hasCover: root.cardImage !== ""
                  readonly property bool raisable: root.isMedia && root.focused.canRaise === true
                  width: Style.space(root.shotUrl !== "" ? 96 : (hasCover ? 72 : 48))
                  height: width

                  Behavior on width {
                    enabled: root.motion && root.opened
                    NumberAnimation { duration: 280; easing.type: Easing.OutCubic }
                  }
                  radius: hasCover ? Style.spacing.labelGap : width / 2
                  color: Util.alpha(root.accentFor(root.focused), 0.2)
                  scale: coverArea.pressed ? 0.95 : 1

                  Behavior on scale {
                    enabled: root.motion
                    NumberAnimation { duration: 120 }
                  }

                  // The next cover crossfades in once loaded, with a slight zoom.
                  CoverSwap {
                    anchors.fill: parent
                    anchors.margins: Style.space(2)
                    visible: cardIcon.hasCover
                    source: root.cardImage
                  }

                  // Timer, Pomodoro, sleep timer: a ring around the icon fills up.
                  Ring {
                    anchors.fill: parent
                    visible: !cardIcon.hasCover && root.focused !== null && root.focused.module === "timer" && root.focused.progress >= 0
                    thickness: Math.max(3, Style.space(3))
                    progress: visible ? root.focused.progress : 0
                    color: root.accentFor(root.focused)
                  }

                  // Click the cover: bring the player's window up.
                  MouseArea {
                    id: coverArea
                    anchors.fill: parent
                    enabled: cardIcon.raisable
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.mediaKey("raise")
                  }

                  Rectangle {
                    anchors.fill: parent
                    radius: parent.radius
                    visible: coverArea.containsMouse
                    color: Util.alpha("black", 0.35)

                    Text {
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: "\u{f03cc}"
                      color: "white"
                      font.family: root.family
                      font.pixelSize: Style.font.iconLarge
                    }
                  }

                  Text {
                    visible: !cardIcon.hasCover
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: root.focused ? root.focused.icon : ""
                    color: root.focused && root.focused.urgent ? Color.urgent : (root.chargeThemed ? root.chargeGreen : root.popupFg)
                    font.family: root.family
                    font.pixelSize: Style.font.display
                  }
                }

                // The card's text; on a track change the old one (ghost) slides
                // out while the new one slides in, both clipped to this box.
                Item {
                  id: cardText
                  width: parent.width - cardIcon.width - parent.spacing - (mediaHide.visible ? mediaHide.width + parent.spacing : 0)
                  height: liveText.implicitHeight
                  anchors.verticalCenter: parent.verticalCenter
                  clip: true

                  CardText {
                    id: liveText
                    width: parent.width
                    title: root.focused ? root.focused.title : ""
                    subtitle: root.focused ? root.focused.subtitle : ""
                    album: root.isMedia && root.focused.album !== root.focused.title ? root.focused.album : ""
                    transform: Translate { id: trackShift }
                  }

                  CardText {
                    id: ghostText
                    width: parent.width
                    opacity: 0
                    visible: opacity > 0
                    title: root.ghostTitle
                    subtitle: root.ghostSubtitle
                    album: root.ghostAlbum
                    transform: Translate { id: ghostShift }
                  }
                }

                // Media cards have their own controls below; hiding sits here.
                Button {
                  id: mediaHide
                  visible: root.isMedia
                  anchors.top: parent.top
                  iconText: "\u{f0209}"
                  foreground: Qt.darker(root.popupFg, 1.2)
                  tooltipText: "Hide until it changes (x / right click)"
                  onClicked: if (root.service && root.focused) root.service.dismiss(root.focused.id)
                }
              }

              // Media you can seek: click or drag along the bar.
              Item {
                id: progressBar
                width: parent.width
                visible: root.focused !== null && root.focused.progress >= 0
                readonly property real trackHeight: Style.space(root.isCharging(root.focused) ? 8 : 4)
                height: seekable ? Style.space(16) : trackHeight

                readonly property bool seekable: root.focused !== null && root.focused.seekable === true
                property bool dragging: false
                property real dragValue: 0
                readonly property real shownValue: dragging ? dragValue : value

                // Where the activity says it is, and what the bar shows. While
                // media plays, the bar glides to each new second in a straight
                // line instead of jumping a step each tick; a jump (another
                // track, a seek) goes there quickly; another card, at once.
                readonly property real target: root.focused ? Math.max(0, Math.min(1, root.focused.progress)) : 0
                property real value: 0
                property string valueOf: ""
                onTargetChanged: {
                  var id = root.focused ? root.focused.id : ""
                  glide.stop()
                  if (id !== valueOf || !root.motion) { valueOf = id; value = target; return }
                  var len = root.isMedia ? root.focused.length : 0
                  var ahead = (target - value) * len
                  var flowing = root.isMedia && root.focused.playing && ahead > 0 && ahead < 2.5
                  glide.to = target
                  glide.duration = flowing ? 1050 : 320
                  glide.easing.type = flowing ? Easing.Linear : Easing.OutCubic
                  glide.start()
                }

                NumberAnimation { id: glide; target: progressBar; property: "value" }

                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width
                  height: progressBar.trackHeight
                  radius: height / 2
                  color: Util.alpha(root.popupFg, 0.15)

                  ChargeWave {
                    anchors.fill: parent
                    visible: root.isCharging(root.focused)
                    level: progressBar.shownValue
                    running: root.opened
                  }

                  Rectangle {
                    visible: !root.isCharging(root.focused)
                    height: parent.height
                    radius: parent.radius
                    width: parent.width * progressBar.shownValue
                    color: root.accentFor(root.focused)
                  }
                }

                Rectangle {
                  visible: progressBar.seekable
                  // Grows under the pointer, more while dragging.
                  property real size: Style.space(progressBar.dragging ? 14 : (seekArea.containsMouse ? 12 : 10))
                  Behavior on size {
                    enabled: root.motion
                    NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
                  }
                  width: size
                  height: size
                  radius: size / 2
                  anchors.verticalCenter: parent.verticalCenter
                  x: Math.max(0, Math.min(progressBar.width - size, progressBar.width * progressBar.shownValue - size / 2))
                  color: root.accentFor(root.focused)
                }

                MouseArea {
                  id: seekArea
                  anchors.fill: parent
                  enabled: progressBar.seekable
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  function valueAt(x) { return Math.max(0, Math.min(1, x / progressBar.width)) }
                  onPressed: function(mouse) { progressBar.dragging = true; progressBar.dragValue = valueAt(mouse.x) }
                  onPositionChanged: function(mouse) { if (progressBar.dragging) progressBar.dragValue = valueAt(mouse.x) }
                  onReleased: {
                    if (progressBar.dragging && root.service && root.focused) root.service.seek(root.focused.id, progressBar.dragValue)
                    progressBar.dragging = false
                  }
                  onCanceled: progressBar.dragging = false
                }
              }

              // 1:51 ................................ -1:20 (follows a drag).
              Item {
                width: parent.width
                height: elapsedText.implicitHeight
                visible: root.isMedia && root.focused.length > 0
                // The real position (or where it is being dragged to): the bar
                // glides, the numbers don't count backwards on a track change.
                readonly property real at: (progressBar.dragging ? progressBar.dragValue : progressBar.target) * (root.focused ? root.focused.length : 0)

                Text {
                  id: elapsedText
                  anchors.left: parent.left
                  textFormat: Text.PlainText
                  text: Model.formatDuration(parent.at * 1000)
                  color: Qt.darker(root.popupFg, 1.3)
                  font.family: root.family
                  font.pixelSize: Style.font.caption
                }

                Text {
                  anchors.right: parent.right
                  textFormat: Text.PlainText
                  text: "-" + Model.formatDuration(Math.max(0, (root.focused ? root.focused.length : 0) - parent.at) * 1000)
                  color: Qt.darker(root.popupFg, 1.3)
                  font.family: root.family
                  font.pixelSize: Style.font.caption
                }
              }

              Column {
                width: parent.width
                spacing: Style.space(2)
                visible: root.focused !== null && root.focused.details.length > 0 && !root.isWeather && !root.isMedia

                Repeater {
                  model: root.focused ? root.focused.details : []

                  Text {
                    required property var modelData
                    width: parent.width
                    textFormat: Text.PlainText
                    text: modelData
                    color: Qt.darker(root.popupFg, 1.2)
                    font.family: root.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
              }

              //   ⤨  ↺10  ⏮  ( ⏯ )  ⏭  10↻  ⟳     (only what the player can do)
              Item {
                width: parent.width
                height: mediaKeys.height
                visible: root.isMedia

                Row {
                  id: mediaKeys
                  anchors.centerIn: parent
                  spacing: Style.space(10)

                  MediaKey { actionId: "shuffle"; on: root.isMedia && root.focused.shuffle === true; tip: "Shuffle" }
                  MediaKey { actionId: "back10"; tip: "Back 10 s" }
                  MediaKey { actionId: "previous"; tip: "Previous" }
                  MediaKey { actionId: "playPause"; primary: true; tip: "Play / pause (Enter, middle click)" }
                  MediaKey { actionId: "next"; tip: "Next" }
                  MediaKey { actionId: "forward10"; tip: "Forward 10 s" }
                  MediaKey {
                    actionId: "loop"
                    on: root.isMedia && root.focused.loop !== "" && root.focused.loop !== "none"
                    tip: root.isMedia && root.focused.loop === "track" ? "Repeat: this track" : (root.isMedia && root.focused.loop === "playlist" ? "Repeat: all" : "Repeat: off")
                  }
                }
              }

              // Player volume (media cards whose player reports one).
              Row {
                id: volumeRow
                width: parent.width
                spacing: Style.space(8)
                visible: root.focused !== null && root.focused.module === "media" && root.focused.volume >= 0

                property bool dragging: false
                property real dragValue: 0
                readonly property real level: dragging ? dragValue : (root.focused && root.focused.volume >= 0 ? root.focused.volume : 0)

                Text {
                  id: volumeIcon
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: volumeRow.level <= 0 ? "\u{f0581}" : (volumeRow.level < 0.5 ? "\u{f0580}" : "\u{f057e}")
                  color: root.popupFg
                  font.family: root.family
                  font.pixelSize: Style.font.body
                }

                Item {
                  id: volumeTrack
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - volumeIcon.width - volumePct.width - parent.spacing * 2
                  height: Style.space(14)

                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width
                    height: Style.space(4)
                    radius: height / 2
                    color: Util.alpha(root.popupFg, 0.15)

                    Rectangle {
                      height: parent.height
                      radius: parent.radius
                      width: parent.width * volumeRow.level
                      color: root.accentFor(root.focused)
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    function set(x) {
                      volumeRow.dragValue = Math.max(0, Math.min(1, x / volumeTrack.width))
                      if (root.service && root.focused) root.service.setVolume(root.focused.id, volumeRow.dragValue)
                    }
                    onPressed: function(mouse) { volumeRow.dragging = true; set(mouse.x) }
                    onPositionChanged: function(mouse) { if (volumeRow.dragging) set(mouse.x) }
                    onReleased: volumeRow.dragging = false
                    onCanceled: volumeRow.dragging = false
                    onWheel: function(wheel) {
                      if (!root.service || !root.focused) return
                      root.service.setVolume(root.focused.id, volumeRow.level + (wheel.angleDelta.y > 0 ? 0.05 : -0.05))
                    }
                  }
                }

                Text {
                  id: volumePct
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(34)
                  horizontalAlignment: Text.AlignRight
                  textFormat: Text.PlainText
                  text: Math.round(volumeRow.level * 100) + "%"
                  color: Qt.darker(root.popupFg, 1.3)
                  font.family: root.family
                  font.pixelSize: Style.font.caption
                }
              }

              Flow {
                width: parent.width
                spacing: Style.space(6)
                visible: !root.isMedia

                Repeater {
                  model: root.focused ? root.focused.actions : []

                  Button {
                    required property var modelData
                    required property int index
                    iconText: modelData.icon
                    text: modelData.label
                    foreground: root.popupFg
                    accent: root.accentFor(root.focused)
                    selected: index === 0
                    tooltipText: index === 0 ? "Enter / middle click" : ""
                    onClicked: root.runAction(modelData)
                  }
                }

                // Pushed activities already have Dismiss as their action.
                Button {
                  visible: root.focused !== null && root.focused.module !== "push" && !root.focused.ambient
                  iconText: "\u{f0209}"
                  foreground: root.popupFg
                  tooltipText: "Hide until it changes (x / right click)"
                  onClicked: if (root.service && root.focused) root.service.dismiss(root.focused.id)
                }
              }

              ParallelAnimation {
                id: cardSwap
                NumberAnimation { target: card; property: "x"; from: root.slideFrom * Style.space(36); to: 0; duration: 340; easing.type: Easing.OutQuint }
                NumberAnimation { target: card; property: "opacity"; from: 0; to: 1; duration: 220; easing.type: Easing.OutCubic }
                NumberAnimation { target: card; property: "scale"; from: 0.96; to: 1; duration: 340; easing.type: Easing.OutQuint }
              }
            }

            Column {
              id: emptyCard
              width: parent.width
              visible: root.focused === null
              spacing: Style.space(4)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "Nothing going on"
                color: root.popupFg
                font.family: root.family
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                text: "Media, timers, reminders, screen recording, camera/mic use and more show up here while they are active."
                color: Qt.darker(root.popupFg, 1.4)
                font.family: root.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          PanelSeparator {
            foreground: root.popupFg
            opacity: root.stage(2)
            transform: Translate { x: root.enterShiftX(2); y: root.enterShiftY(2) }
          }

          // Everything Omarchy's indicators widget does, both ways: lit when on.
          PanelSectionHeader {
            text: "QUICK TOGGLES"
            foreground: root.popupFg
            fontFamily: root.family
            visible: root.quickTogglesShown
            opacity: root.stage(2)
            transform: Translate { x: root.enterShiftX(2); y: root.enterShiftY(2) }
          }

          Flow {
            width: parent.width
            spacing: Style.space(6)
            visible: root.quickTogglesShown
            opacity: root.stage(2)
            transform: Translate { x: root.enterShiftX(2); y: root.enterShiftY(2) }

            Repeater {
              model: [
                { id: "dnd", icon: "\u{f009b}", label: "DND", tip: "Do Not Disturb" },
                { id: "nightlight", icon: "\u{f050e}", label: "Night", tip: "Night light" },
                { id: "stayAwake", icon: "\u{f0176}", label: "Awake", tip: "Stay awake (no idle lock or screensaver)" },
                { id: "record", icon: "\u{f0ec2}", label: "Record", tip: "Screen recording: start (opens the menu) or stop" },
                { id: "reminder", icon: "\u{f088c}", label: "Remind", tip: "Set a reminder" },
                { id: "dictation", icon: "\u{f036c}", label: "Dictate", tip: "Dictation (voxtype) settings" }
              ]

              Button {
                required property var modelData
                readonly property bool on: root.service !== null && root.service.quickStates[modelData.id] === true
                visible: root.prefs.quickToggles.indexOf(modelData.id) !== -1
                  && (modelData.id !== "dictation" || (root.service !== null && root.service.hasVoxtype))
                iconText: modelData.icon
                text: modelData.label
                foreground: root.popupFg
                accent: modelData.id === "record" && on ? Color.urgent : Color.accent
                selected: on
                tooltipText: modelData.tip + (on ? " (on)" : "")
                onClicked: {
                  if (!root.service) return
                  // Recording, reminders and dictation open their own UI.
                  if (root.service.quickToggle(modelData.id)) root.close()
                }
              }
            }
          }

          // One click to take over from Omarchy's indicators widget (opt-in).
          Button {
            visible: root.quickTogglesShown && root.service !== null && root.service.indicatorsState === "native"
            iconText: "\u{f009b}"
            text: "Use instead of Omarchy's indicators"
            foreground: Qt.darker(root.popupFg, 1.2)
            tooltipText: "Turns Omarchy's indicators widget off; these toggles do the same (undo in the options)"
            onClicked: root.service.setIndicators(true)
            opacity: root.stage(2)
            transform: Translate { x: root.enterShiftX(2); y: root.enterShiftY(2) }
          }

          PanelSeparator {
            foreground: root.popupFg
            visible: root.quickTogglesShown && root.quickStartShown
            opacity: root.stage(3)
            transform: Translate { x: root.enterShiftX(3); y: root.enterShiftY(3) }
          }

          PanelSectionHeader {
            text: "QUICK START"
            foreground: root.popupFg
            fontFamily: root.family
            visible: root.quickStartShown
            opacity: root.stage(3)
            transform: Translate { x: root.enterShiftX(3); y: root.enterShiftY(3) }
          }

          Flow {
            width: parent.width
            spacing: Style.space(6)
            visible: root.quickStartShown
            opacity: root.stage(3)
            transform: Translate { x: root.enterShiftX(3); y: root.enterShiftY(3) }

            Repeater {
              model: root.presets

              Button {
                required property var modelData
                required property int index
                iconText: "\u{f13ab}"
                text: Model.presetLabel(modelData)
                foreground: root.popupFg
                tooltipText: "Start a " + Model.presetLabel(modelData) + " timer (" + (index + 1) + ")"
                onClicked: if (root.service) root.service.startTimer(modelData)
              }
            }

            Button {
              visible: root.prefs.quickStartExtras.indexOf("stopwatch") !== -1
              iconText: "\u{f520}"
              text: "Stopwatch"
              foreground: root.popupFg
              tooltipText: "Start the stopwatch (s)"
              onClicked: if (root.service) root.service.startStopwatch()
            }

            Button {
              visible: root.prefs.quickStartExtras.indexOf("pomodoro") !== -1
              iconText: "\u{f04fe}"
              text: "Pomodoro"
              foreground: root.popupFg
              tooltipText: "Focus " + root.prefs.pomodoroFocus + " min, break " + root.prefs.pomodoroBreak + " min (p)"
              onClicked: if (root.service) root.service.startPomodoro()
            }

            Button {
              visible: root.prefs.moduleMedia && root.prefs.quickStartExtras.indexOf("sleep") !== -1
              iconText: "\u{f04b2}"
              text: "Sleep 30 min"
              foreground: root.popupFg
              tooltipText: "Pause the media in 30 minutes"
              onClicked: if (root.service) root.service.startSleep(1800)
            }
          }

          // Any timer: "12m", "1h30m", "90" (seconds), or a time ("14:30").
          Row {
            width: parent.width
            spacing: Style.space(6)
            visible: root.quickStartShown
            opacity: root.stage(3)
            transform: Translate { x: root.enterShiftX(3); y: root.enterShiftY(3) }

            TextField {
              id: customTimer
              width: parent.width - customStart.width - parent.spacing
              foreground: root.popupFg
              font.family: root.family
              placeholderText: "Timer: 12m, 1h30m or 14:30"
              readonly property int seconds: Model.parseTimerArg(text, Date.now())
              onAccepted: start()
              function start() {
                if (seconds <= 0 || !root.service) return
                root.service.startTimer(seconds)
                text = ""
                root.forceKeyFocus()
              }
            }

            Button {
              id: customStart
              anchors.verticalCenter: parent.verticalCenter
              iconText: "\u{f040a}"
              foreground: root.popupFg
              enabled: customTimer.seconds > 0
              opacity: enabled ? 1 : 0.4
              tooltipText: customTimer.seconds > 0 ? "Start a " + Model.formatDuration(customTimer.seconds * 1000) + " timer (Enter)" : "Type a duration or a time"
              onClicked: customTimer.start()
            }
          }
        }
      }
    }
  }
}
