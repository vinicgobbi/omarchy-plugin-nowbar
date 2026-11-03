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
      settingsView.page = tab
      root.settingsRequestedAt = Date.now()
      if (root.opened) root.settingsOpen = true
    }
  }
  onOpenedChanged: {
    if (opened) anchorWidth = width
    unfold(opened)
    // The carousel keeps its order while it is on screen.
    if (service) service.holdOrder(opened)
    if (!opened) { settingsOpen = false; pendingStart = null; return }
    if (Date.now() - settingsRequestedAt < 2000) settingsOpen = true
    if (service) service.refreshWeatherIfStale()
  }

  // Back to the popup's own keys (after typing a timer).
  function forceKeyFocus() { keyCatcher.forceActiveFocus() }

  // Starting a timer, the stopwatch or a Pomodoro from the popup while one is
  // already going would throw it away (a stray "1" over a 25 min timer): the
  // first press only asks, the same press again within a few seconds does it.
  // { kind, seconds, warning }
  property var pendingStart: null

  function requestStart(kind, seconds) {
    if (!service) return
    var warning = service.startWarning(kind)
    var again = pendingStart !== null && pendingStart.kind === kind && pendingStart.seconds === seconds
    if (warning !== "" && !again) {
      pendingStart = { kind: kind, seconds: seconds, warning: warning }
      pendingStartTimer.restart()
      return
    }
    pendingStart = null
    if (kind === "timer") service.startTimer(seconds)
    else if (kind === "stopwatch") service.startStopwatch()
    else if (kind === "pomodoro") service.startPomodoro()
  }

  Timer {
    id: pendingStartTimer
    interval: 5000
    onTriggered: root.pendingStart = null
  }

  // Keyboard on a media card: ↑/↓ volume, [ / ] 10 s back / forward.
  function mediaVolumeStep(delta) {
    if (!isMedia || focused.volume < 0 || !service) return
    service.setVolume(focused.id, Math.round((focused.volume + delta) * 100) / 100)
  }

  // Same look as the shell's buttons' tooltips.
  component Tip: QQC.ToolTip {
    id: tipBox
    delay: 400
    padding: 0
    background: BorderSurface {
      color: Color.tooltip.background
      borderSpec: Border.localOrSurfaceSpec("tooltip", "border", Color.tooltip.border, Color.tooltip.border, Math.max(1, Style.normalBorderWidth))
      radius: 0
    }
    contentItem: Text {
      textFormat: Text.PlainText
      text: tipBox.text
      color: Color.tooltip.text
      font.family: root.family
      font.pixelSize: Style.font.bodySmall
      leftPadding: Style.spacing.controlPaddingX
      rightPadding: Style.spacing.controlPaddingX
      topPadding: Style.spacing.controlPaddingY
      bottomPadding: Style.spacing.controlPaddingY
    }
  }

  // Runs one of the focused card's actions. One that opens an app (Update,
  // Edit, Open) closes the popup first: the window it opens takes the focus,
  // and a popup left open over it would keep the keyboard (and, while a
  // password prompt is up, could get stuck open until the app is done).
  //
  // One with `confirm` (Clear all reminders) only asks on the first click; the
  // same button again within a few seconds does it.
  property string armedAction: ""

  function runAction(action) {
    if (!service || !focused || !action) return
    var id = focused.id
    if (action.confirm && armedAction !== id + "/" + action.id) {
      armedAction = id + "/" + action.id
      armedActionTimer.restart()
      return
    }
    armedAction = ""
    if (action.opensApp) close()
    service.act(id, action.id)
  }

  Timer {
    id: armedActionTimer
    interval: 4000
    onTriggered: root.armedAction = ""
  }

  readonly property bool isMedia: focused !== null && focused.module === "media"
  // The card stands on the cover: its text is white whatever the theme.
  readonly property bool mediaHasCover: isMedia && coverUrl !== ""
  readonly property color mediaFg: mediaHasCover ? "white" : popupFg

  // The app behind the focused player: from its desktop entry, or its name when
  // the entry doesn't match (Spotify's Flatpak says "spotify", its app is
  // com.spotify.Client). Looked up only when the player changes.
  readonly property string mediaAppKey: isMedia ? (focused.desktopEntry || "") + "\n" + (focused.playerName || "") : ""
  readonly property var mediaApp: findApp(mediaAppKey)

  function findApp(key) {
    if (key === "") return null
    // The entries load after the shell starts: look again once they're there.
    var loaded = DesktopEntries.applications.values
    var terms = key.split("\n")
    for (var i = 0; i < terms.length; i++) {
      if (terms[i] === "") continue
      var entry = DesktopEntries.byId(terms[i]) || DesktopEntries.heuristicLookup(terms[i])
      if (!entry || !entry.icon) continue
      var icon = String(entry.icon)
      var source = icon.charAt(0) === "/" ? Util.fileUrl(icon) : Quickshell.iconPath(icon, true)
      if (source) return { icon: source }
    }
    return null
  }

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
  readonly property string trackKey: isMedia ? focused.id + "\n" + focused.title + "\n" + focused.artist : ""
  property string lastTrackKey: ""
  property string lastTitle: ""
  property string lastArtist: ""
  property string ghostTitle: ""
  property string ghostArtist: ""
  onTrackKeyChanged: {
    var before = lastTrackKey.split("\n")[0]
    var now = trackKey.split("\n")[0]
    var sameplayer = now !== "" && now === before
    ghostTitle = lastTitle
    ghostArtist = lastArtist
    lastTrackKey = trackKey
    lastTitle = isMedia ? focused.title : ""
    lastArtist = isMedia ? focused.artist : ""
    if (sameplayer && motion) {
      if (opened) {
        trackSwap.stop()
        ghostSlide.to = -trackDir * Style.space(36)
        trackSlide.from = trackDir * Style.space(40)
        trackShift.x = trackSlide.from
        liveLine.opacity = 0
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
    NumberAnimation { target: ghostLine; property: "opacity"; from: 1; to: 0; duration: 160; easing.type: Easing.InQuad }
    SequentialAnimation {
      PauseAnimation { duration: 150 }
      ParallelAnimation {
        NumberAnimation { id: trackSlide; target: trackShift; property: "x"; to: 0; duration: 460; easing.type: Easing.OutQuint }
        NumberAnimation { target: liveLine; property: "opacity"; to: 1; duration: 340; easing.type: Easing.OutCubic }
      }
    }
    // Whatever happens, end with the new text in place.
    onStopped: { trackShift.x = 0; liveLine.opacity = 1; ghostLine.opacity = 0 }
  }

  // Title and subtitle, as a card shows them.
  component CardText: Column {
    property string title: ""
    property string subtitle: ""
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
      color: Util.alpha(root.popupFg, 0.72)
      font.family: root.family
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }

  // "Title  •  artist" on one line, as plain text.
  component MarqueeLine: Row {
    id: line
    property string text: ""
    property string secondary: ""
    property color color: root.fg
    property int pixelSize: Style.font.body
    property bool bold: false

    Text {
      textFormat: Text.PlainText
      text: line.text
      color: line.color
      font.family: root.family
      font.pixelSize: line.pixelSize
      font.bold: line.bold
    }

    Text {
      visible: line.secondary !== ""
      textFormat: Text.PlainText
      text: line.secondary
      color: Util.alpha(line.color, 0.85)
      font.family: root.family
      font.pixelSize: line.pixelSize
    }
  }

  // One line of text that doesn't fit, by `mode`: "once" goes by whole each time
  // `playKey` changes, then rests on its start, faded where it's cut; "scroll"
  // goes round and round (a copy follows it, so a round ends where it began);
  // "ellipsis" is cut with "...". Whether it fits is measured on a hidden copy,
  // so it never depends on how the visible text is laid out.
  component Marquee: Item {
    id: mq
    property string text: ""
    property string secondary: ""
    property color color: root.fg
    property int pixelSize: Style.font.body
    property bool bold: false
    property string mode: "scroll"
    property string playKey: ""
    property bool centered: false
    // Off screen: nothing moves.
    property bool active: true
    // What it has to fit in: the width, unless that's still easing to it.
    property real limit: width

    readonly property real gap: Style.space(28)
    readonly property real fadeWidth: Style.space(20)
    readonly property real fullWidth: measure.implicitWidth
    readonly property real distance: fullWidth + gap
    readonly property bool overflows: fullWidth > limit
    readonly property bool cut: mode === "ellipsis"
    readonly property bool canRoll: overflows && !cut && root.motion && active && visible
    readonly property bool rolling: roll.running
    // Cut text fades out at the right; while it slides, at the left too,
    // growing as it leaves the start and shrinking as its copy gets there.
    readonly property real leftFade: rolling ? Math.max(0, Math.min(fadeWidth, -strip.x, distance + strip.x)) : 0
    // "once": a round is owed.
    property bool wanted: true

    implicitHeight: measure.implicitHeight
    clip: true

    function sync() {
      if (!overflows || cut || !root.motion) wanted = false
      if (!canRoll) { roll.stop(); strip.x = 0; return }
      if (mode !== "once") { if (!roll.running) roll.start(); return }
      if (wanted) { wanted = false; roll.stop(); strip.x = 0; roll.start() }
    }

    onPlayKeyChanged: {
      wanted = true
      roll.stop()
      strip.x = 0
      Qt.callLater(mq.sync)
    }
    onCanRollChanged: Qt.callLater(mq.sync)
    onModeChanged: { roll.stop(); strip.x = 0; Qt.callLater(mq.sync) }
    Component.onCompleted: Qt.callLater(mq.sync)

    layer.enabled: overflows && !cut
    layer.effect: MultiEffect {
      maskEnabled: true
      maskSource: fadeMask
      // Soft: the mask's alpha goes straight through (0 to 1).
      maskThresholdMin: 0.5
      maskSpreadAtMin: 1.0
      autoPaddingEnabled: false
    }

    Rectangle {
      id: fadeMask
      anchors.fill: parent
      visible: false
      layer.enabled: true
      readonly property real span: Math.max(1, mq.width)
      gradient: Gradient {
        orientation: Gradient.Horizontal
        GradientStop { position: 0; color: mq.leftFade > 0 ? Qt.rgba(1, 1, 1, 0) : "white" }
        GradientStop { position: Math.min(0.5, mq.leftFade / fadeMask.span); color: "white" }
        GradientStop { position: Math.max(0.5, 1 - mq.fadeWidth / fadeMask.span); color: "white" }
        GradientStop { position: 1; color: Qt.rgba(1, 1, 1, 0) }
      }
    }

    MarqueeLine {
      id: measure
      opacity: 0
      text: mq.text
      secondary: mq.secondary
      pixelSize: mq.pixelSize
      bold: mq.bold
    }

    // "Cut".
    Text {
      visible: mq.cut
      width: mq.width
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: mq.text + mq.secondary
      horizontalAlignment: mq.overflows || !mq.centered ? Text.AlignLeft : Text.AlignHCenter
      elide: Text.ElideRight
      color: mq.color
      font.family: root.family
      font.pixelSize: mq.pixelSize
      font.bold: mq.bold
    }

    Item {
      visible: !mq.cut
      x: mq.centered && !mq.overflows ? Math.round((mq.width - mq.fullWidth) / 2) : 0
      anchors.top: parent.top
      anchors.bottom: parent.bottom

      Row {
        id: strip
        anchors.verticalCenter: parent.verticalCenter
        spacing: mq.gap

        MarqueeLine {
          text: mq.text
          secondary: mq.secondary
          color: mq.color
          pixelSize: mq.pixelSize
          bold: mq.bold
        }

        MarqueeLine {
          visible: mq.rolling
          text: mq.text
          secondary: mq.secondary
          color: mq.color
          pixelSize: mq.pixelSize
          bold: mq.bold
        }
      }
    }

    SequentialAnimation {
      id: roll
      loops: mq.mode === "once" ? 1 : Animation.Infinite
      PauseAnimation { duration: mq.mode === "once" ? 1000 : 1800 }
      NumberAnimation {
        target: strip
        property: "x"
        from: 0
        to: -mq.distance
        duration: Math.max(2000, mq.distance * 30)
      }
      onFinished: strip.x = 0
    }
  }

  // Text on an accent-filled circle: dark on light colors, light on dark.
  function onAccent(c) {
    return (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) > 0.6 ? Qt.rgba(0.07, 0.07, 0.08, 1) : Qt.rgba(1, 1, 1, 1)
  }

  // One round media button. Over a cover they're translucent circles; without
  // one, play/pause is filled with the accent. `on` lights shuffle / repeat.
  // `keepPlace`: when the player can't do it, it stays there, faded, so the row
  // keeps its shape from one track to the next.
  component MediaKey: Item {
    id: mk
    property string actionId: ""
    property bool primary: false
    property bool on: false
    property bool keepPlace: false
    property string tip: ""
    // Previous, play and next the same size; shuffle and repeat smaller, the
    // ±10 s beside the times smaller still.
    readonly property bool transport: primary || actionId === "previous" || actionId === "next"
    readonly property bool compact: actionId === "back10" || actionId === "forward10"
    readonly property var action: root.mediaAction(actionId)
    readonly property bool filled: primary && !root.mediaHasCover
    readonly property color glyphColor: filled ? root.onAccent(root.accentFor(root.focused))
      : (on && !root.mediaHasCover ? root.accentFor(root.focused) : root.mediaFg)
    visible: action !== null || keepPlace
    enabled: action !== null
    opacity: enabled ? 1 : 0.35
    width: Style.space(transport ? 50 : (compact ? 26 : 36))
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
      color: mk.filled ? root.accentFor(root.focused)
        : Util.alpha(root.mediaFg, mkArea.containsMouse ? 0.2 : (mk.transport || mk.on ? 0.12 : 0))
      // Only the hover; the accent animates by itself (coverAccent).
      Behavior on color {
        enabled: root.motion && !mk.filled
        ColorAnimation { duration: 160 }
      }
    }

    Text {
      anchors.centerIn: parent
      // The play triangle looks off to the left when centered by its box.
      anchors.horizontalCenterOffset: mk.action && mk.action.icon === "\u{f040a}" ? Math.round(width * 0.08) : 0
      textFormat: Text.PlainText
      text: mk.action ? mk.action.icon : (mk.actionId === "previous" ? "\u{f04ae}" : "\u{f04ad}")
      color: mk.glyphColor
      opacity: mk.transport || mk.on ? 1 : 0.7
      font.family: root.family
      font.pixelSize: mk.primary ? Style.font.displayLarge : (mk.transport ? Style.font.display : (mk.compact ? Style.font.body : Style.font.iconLarge))
    }

    // A dot under shuffle / repeat while on.
    Rectangle {
      visible: mk.on
      width: Style.space(4)
      height: width
      radius: width / 2
      anchors.horizontalCenter: parent.horizontalCenter
      anchors.bottom: parent.bottom
      anchors.bottomMargin: Style.space(2)
      color: mk.glyphColor
    }

    MouseArea {
      id: mkArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.mediaKey(mk.actionId)
    }

    Tip {
      visible: mk.tip !== "" && mkArea.containsMouse
      text: mk.tip
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
  // The options are a bit wider: a list with switches and a line under each name.
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
    if (!settingsOpen) settingsView.page = "home"
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

  // Music and the weather fill the pill: the cover's accent, the sky's color,
  // the same hue gone deeper, with text and icon in whichever of black and white
  // reads on it. "" for everything else (urgent red and charging have their own).
  readonly property string pillFillColor: {
    var a = pillItem
    if (!a || a.urgent || !prefs.coverAccent) return ""
    if (a.module === "media" && hasCoverAccent) return Model.pillFill(coverAccent.toString().slice(0, 7))
    if (a.module === "weather" && a.color) return Model.pillFill(a.color)
    return ""
  }
  readonly property color pillFg: pillFillColor !== "" ? Model.readableOn(pillFillColor) : fg

  function accentFor(activity) {
    if (activity && activity.urgent) return Color.urgent
    if (isCharging(activity)) return chargeGreen
    if (activity && activity.module === "media" && hasCoverAccent) return coverAccent
    if (activity && activity.module === "weather" && activity.color && prefs.coverAccent) return Qt.lighter(activity.color, 1.0)
    return Color.accent
  }

  // One step per notch of a mouse wheel or per swipe of a touchpad.
  property var wheelState: null
  function wheelStep(delta) {
    if (!service) return
    var r = Model.wheelStep(wheelState, delta, Date.now())
    wheelState = r.state
    if (r.step === 0) return
    service.step(r.step)
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

  // One cover image: sharp, or blurred (cut to `mask`) for the backdrop.
  component CoverLayer: Item {
    id: cl
    property url source: ""
    property bool blurred: false
    property Item mask: null
    property int decodeSize: 256
    readonly property bool ready: img.status === Image.Ready && String(img.source) !== ""
    readonly property bool effect: blurred || mask !== null
    opacity: 0

    Image {
      id: img
      anchors.fill: parent
      visible: !cl.effect
      source: cl.source
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      // Blurred, a small one does (and is cheaper to blur).
      sourceSize.width: cl.blurred ? 96 : cl.decodeSize
      sourceSize.height: cl.blurred ? 96 : cl.decodeSize
    }

    MultiEffect {
      anchors.fill: parent
      visible: cl.effect
      source: img
      autoPaddingEnabled: false
      blurEnabled: cl.blurred
      blur: 1.0
      blurMax: 48
      saturation: cl.blurred ? 0.2 : 0
      maskEnabled: cl.mask !== null
      maskSource: cl.mask
      // Soft: a hard cut leaves the corners jagged.
      maskThresholdMin: 0.5
      maskSpreadAtMin: 1.0
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
    property int decodeSize: 256
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

    CoverLayer { id: la; anchors.fill: parent; blurred: cs.blurred; mask: cs.mask; decodeSize: cs.decodeSize; onReadyChanged: cs.landed(la) }
    CoverLayer { id: lb; anchors.fill: parent; blurred: cs.blurred; mask: cs.mask; decodeSize: cs.decodeSize; onReadyChanged: cs.landed(lb) }

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
    // The option is for the whole pill: the text gets what's left of it after
    // the padding, the icon and the marker.
    readonly property real textMax: Math.max(Style.space(40), root.prefs.maxWidth - Style.space(16) - iconSlot.width - pillContent.spacing
      - (countSlot.visible ? countSlot.width + pillContent.spacing : 0))
    // Media shows its progress only on the card.
    readonly property real progress: hasActivity && root.prefs.showProgress && root.pillItem.module !== "media" ? root.pillItem.progress : -1

    height: root.vertical ? pillContent.implicitHeight + Style.space(12) : Math.max(Style.space(18), root.barSize - Style.space(10))
    width: root.vertical ? Math.max(Style.space(18), root.barSize - Style.space(10)) : pillContent.implicitWidth + Style.space(16)
    radius: Math.min(width, height) / 2
    color: root.pillFillColor !== ""
      ? (pillArea.containsMouse || root.opened ? Qt.tint(root.pillFillColor, Util.alpha("white", 0.15)) : root.pillFillColor)
      : root.pillCharging
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

    // Horizontal: icon, text, "2/4", each taking the room it needs, so the pill
    // is as wide as what it shows. Vertical bars only have room for the icon.
    Row {
      id: pillContent
      anchors.centerIn: parent
      spacing: Style.space(6)

      // Media: the player's logo, or the note for a player without one; anything
      // else: its icon.
      Item {
        id: iconSlot
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(16)
        height: pillIcon.implicitHeight
        readonly property string logo: pill.hasActivity && root.pillItem.module === "media" ? root.pillItem.appGlyph : ""
        // Timer, Pomodoro, sleep timer: a little ring that fills up.
        readonly property bool countdown: pill.hasActivity && root.pillItem.module === "timer" && root.pillItem.progress >= 0
        readonly property bool recordingNow: pill.hasActivity && root.pillItem.id === "recording"

        Text {
          id: pillIcon
          anchors.fill: parent
          visible: !parent.countdown && !parent.recordingNow
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          textFormat: Text.PlainText
          text: parent.logo !== "" ? parent.logo : (pill.hasActivity ? root.pillItem.icon : "\u{f0996}")
          color: pill.hasActivity && root.pillItem.urgent ? Color.urgent : (root.pillCharging ? root.chargeGreen : root.pillFg)
          // Paused media: the note, dimmed.
          opacity: !pill.hasActivity || root.pillItem.module === "media" && !root.pillItem.playing ? 0.55 : 1
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
      }

      // Text longer than the slot: see Marquee. A song starts its round when it
      // changes (not on play/pause), anything else when its state does.
      Marquee {
        id: textClip
        visible: !root.vertical
        anchors.verticalCenter: parent.verticalCenter
        // As wide as the text, up to what the pill has room for.
        width: Math.min(pill.textMax, Math.ceil(fullWidth))
        Behavior on width {
          enabled: root.motion
          NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
        }
        height: implicitHeight
        // Against the limit, not the width: that is still easing to the text
        // for a moment.
        limit: pill.textMax
        centered: true
        text: pill.hasActivity ? root.pillItem.pillText : "Nothing going on"
        color: root.pillFg
        opacity: pill.hasActivity ? 1 : 0.6
        mode: root.prefs.textMode
        playKey: !pill.hasActivity ? "" : root.pillItem.id + "\n" + (root.pillItem.module === "media" ? root.pillItem.pillText : root.pillItem.signature)
      }

      // Only when there is something to count.
      Text {
        id: countSlot
        visible: !root.vertical && root.prefs.showCount && root.count > 1 && root.pillItem !== null
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: (root.focusIndex + 1) + "/" + root.count
        color: Util.alpha(root.pillFg, 0.62)
        font.family: root.family
        font.pixelSize: Style.font.caption
      }
    }

    // Thin progress line along the bottom of the pill (charging fills the
    // whole pill instead).
    // Goes to a new value quickly; for another activity, at once.
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
      color: root.pillFillColor !== "" ? Util.alpha(root.pillFg, 0.85) : root.accentFor(root.pillItem)

      readonly property real target: Math.max(0, Math.min(1, pill.progress))
      property real value: 0
      property string valueOf: ""
      onTargetChanged: {
        var id = root.pillItem ? root.pillItem.id : ""
        pillGlide.stop()
        if (id !== valueOf || !root.motion) { valueOf = id; value = target; return }
        pillGlide.to = target
        pillGlide.start()
      }

      NumberAnimation { id: pillGlide; target: pillLine; property: "value"; duration: 320; easing.type: Easing.OutCubic }
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

  // The popup stays where it opened: switching cards changes the pill's width,
  // and centered on the pill it would jump sideways under the pointer.
  property real anchorWidth: 0
  Item {
    id: popupAnchor
    width: root.opened ? root.anchorWidth : root.width
    height: root.height
  }

  KeyboardPanel {
    id: popup
    anchorItem: popupAnchor
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
          if (root.settingsOpen) { if (dy !== 0) settingsView.moveCursor(dy); return }
          if (!root.service) return
          if (dx !== 0) root.service.step(dx)
          else if (dy !== 0) root.mediaVolumeStep(dy < 0 ? 0.05 : -0.05)
        }
        onTabRequested: function(direction) {
          if (root.settingsOpen) settingsView.cycleTab(direction)
          else if (root.service) root.service.step(direction)
        }
        onActivateRequested: {
          if (root.settingsOpen) settingsView.activate()
          else if (root.focused && root.focused.actions.length > 0) root.runAction(root.focused.actions[0])
        }
        onDeleteRequested: {
          if (!root.settingsOpen && root.focused && root.service) root.service.dismiss(root.focused.id)
        }
        // Esc first drops a pending "Replace the timer?".
        onCloseRequested: {
          if (root.pendingStart !== null) root.pendingStart = null
          else if (root.settingsOpen) { if (!settingsView.back()) root.settingsOpen = false }
          else root.close()
        }
        onTextKey: function(t) {
          if (t === "q" || t === "Q") { if (!root.settingsOpen) root.close(); else if (!settingsView.back()) root.settingsOpen = false; return }
          if (t === "c" || t === "C") { root.settingsOpen = !root.settingsOpen; return }
          if (root.settingsOpen || !root.service) return
          if (t === "u" || t === "U") { root.service.showHidden(); return }
          if (root.isMedia && (t === "[" || t === "]")) { root.service.nudgeSeek(root.focused.id, t === "[" ? -10 : 10); return }
          if (!root.quickStartShown) return
          var n = parseInt(t, 10)
          if (n >= 1 && n <= root.presets.length) root.requestStart("timer", root.presets[n - 1])
          else if ((t === "s" || t === "S") && root.prefs.quickStartExtras.indexOf("stopwatch") !== -1) root.requestStart("stopwatch", 0)
          else if ((t === "p" || t === "P") && root.prefs.quickStartExtras.indexOf("pomodoro") !== -1) root.requestStart("pomodoro", 0)
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
            motion: root.motion
            // Each page starts at its top.
            onPageChanged: settingsFlick.contentY = 0
            onScrollRequested: function(direction) {
              var most = Math.max(0, settingsFlick.contentHeight - settingsFlick.height)
              settingsFlick.contentY = Math.max(0, Math.min(most, settingsFlick.contentY + direction * Style.space(60)))
            }
            // The row the keyboard moved to stays in sight.
            onEnsureVisible: function(y, h) {
              if (y < settingsFlick.contentY) settingsFlick.contentY = Math.max(0, y)
              else if (y + h > settingsFlick.contentY + settingsFlick.height) settingsFlick.contentY = y + h - settingsFlick.height
            }
            weatherWidgetState: root.service ? root.service.weatherWidgetState : ""
            indicatorsState: root.service ? root.service.indicatorsState : ""
            updateSourcesAvailable: root.service ? root.service.availableUpdateSources : []
            playerNames: root.service ? root.service.playerNames : []
            onIndicatorsRequested: function(replace) { if (root.service) root.service.setIndicators(replace) }
            onWeatherWidgetRequested: function(replace) { if (root.service) root.service.setWeatherWidget(replace) }
            onBackRequested: root.settingsOpen = false
            weatherLocation: root.service ? root.service.weatherLocation : ({ name: "", latitude: null, longitude: null })
            weatherLocationSaving: root.service ? root.service.weatherLocationSaving : null
            detectedPlace: root.service && root.service.weather ? root.service.weather.location : ""
            locationEditable: root.service ? root.service.hasWeatherLocationTool : false
            locationResults: root.service ? root.service.geocodeResults : []
            locationSearching: root.service ? root.service.geocodeBusy : false
            locationSearchFailed: root.service ? root.service.geocodeFailed : false
            onLocationSearch: function(text) { if (root.service) root.service.searchWeatherLocation(text) }
            onLocationPicked: function(place) { if (root.service) root.service.setWeatherLocation(place) }
            onKeysReleased: root.forceKeyFocus()
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
                    // Came in while the popup is open: it waits here, lit,
                    // instead of taking the card being read.
                    readonly property bool fresh: !current && root.service !== null && root.service.heldOrder.length > 0
                      && root.service.heldOrder.indexOf(modelData.id) === -1
                    anchors.verticalCenter: parent.verticalCenter
                    width: current ? Style.space(18) : Style.space(7)
                    height: Style.space(7)
                    radius: height / 2
                    color: current || fresh ? root.accentFor(modelData) : Util.alpha(root.popupFg, 0.3)

                    SequentialAnimation on opacity {
                      running: parent.fresh && root.motion
                      loops: Animation.Infinite
                      onRunningChanged: if (!running) parent.opacity = 1
                      NumberAnimation { to: 0.35; duration: 600; easing.type: Easing.InOutSine }
                      NumberAnimation { to: 1; duration: 600; easing.type: Easing.InOutSine }
                    }

                    Behavior on width {
                      enabled: root.motion
                      NumberAnimation { duration: 260; easing.type: Easing.OutQuint }
                    }


                    MouseArea {
                      id: dotArea
                      anchors.fill: parent
                      anchors.margins: -Style.space(4)
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: if (root.service) root.service.focusOn(parent.modelData.id)
                    }

                    // Which activity each dot is, without clicking through them.
                    Tip {
                      visible: dotArea.containsMouse
                      text: (parent.fresh ? "New: " : "") + parent.modelData.title
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
                rain: root.isWeather && root.focused.rain ? root.focused.rain : null
                ageText: root.service ? root.service.weatherAge.text : ""
                stale: root.service ? root.service.weatherAge.stale : false
                loading: root.service ? root.service.weatherLoading : false
                onRefreshRequested: if (root.service) root.service.refreshWeather()
                // The place: straight to where it is chosen.
                onPlaceClicked: { settingsView.page = "weather"; root.settingsOpen = true }
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
                visible: !root.isMedia && !(root.isWeather && !!root.focused.weather)

                Rectangle {
                  id: cardIcon
                  // A screenshot gets its thumbnail.
                  readonly property bool hasCover: root.shotUrl !== ""
                  width: Style.space(hasCover ? 96 : 48)
                  height: width

                  Behavior on width {
                    enabled: root.motion && root.opened
                    NumberAnimation { duration: 280; easing.type: Easing.OutCubic }
                  }
                  radius: hasCover ? Style.spacing.labelGap : width / 2
                  color: Util.alpha(root.accentFor(root.focused), 0.2)

                  // The next cover crossfades in once loaded, with a slight zoom.
                  CoverSwap {
                    anchors.fill: parent
                    anchors.margins: Style.space(2)
                    visible: cardIcon.hasCover
                    source: root.shotUrl
                  }

                  // Timer, Pomodoro, sleep timer: a ring around the icon fills up.
                  Ring {
                    anchors.fill: parent
                    visible: !cardIcon.hasCover && root.focused !== null && root.focused.module === "timer" && root.focused.progress >= 0
                    thickness: Math.max(3, Style.space(3))
                    progress: visible ? root.focused.progress : 0
                    color: root.accentFor(root.focused)
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

                CardText {
                  width: parent.width - cardIcon.width - parent.spacing
                  anchors.verticalCenter: parent.verticalCenter
                  title: root.focused ? root.focused.title : ""
                  subtitle: root.focused ? root.focused.subtitle : ""
                }
              }

              // What's left to go, or how far along.
              Item {
                id: progressBar
                width: parent.width
                visible: root.focused !== null && !root.isMedia && root.focused.progress >= 0
                readonly property real trackHeight: Style.space(root.isCharging(root.focused) ? 8 : 4)
                height: trackHeight

                // Where the activity says it is, and what the bar shows: a jump
                // goes there quickly; another card, at once.
                readonly property real target: root.focused ? Math.max(0, Math.min(1, root.focused.progress)) : 0
                property real value: 0
                property string valueOf: ""
                onTargetChanged: {
                  var id = root.focused ? root.focused.id : ""
                  glide.stop()
                  if (id !== valueOf || !root.motion) { valueOf = id; value = target; return }
                  glide.to = target
                  glide.start()
                }

                NumberAnimation { id: glide; target: progressBar; property: "value"; duration: 320; easing.type: Easing.OutCubic }

                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width
                  height: progressBar.trackHeight
                  radius: height / 2
                  color: Util.alpha(root.popupFg, 0.15)

                  ChargeWave {
                    anchors.fill: parent
                    visible: root.isCharging(root.focused)
                    level: progressBar.value
                    running: root.opened
                  }

                  Rectangle {
                    visible: !root.isCharging(root.focused)
                    height: parent.height
                    radius: parent.radius
                    width: parent.width * progressBar.value
                    color: root.accentFor(root.focused)
                  }
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
                    color: Util.alpha(root.popupFg, 0.85)
                    font.family: root.family
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
              }

              // --- media: laid out like One UI's. The cover fills the card, dimmed
              // under the rest; the app on top, "title • artist" on one line that
              // scrolls when it doesn't fit, the seek bar (hills while it plays),
              // the controls and the volume.
              Item {
                id: mediaCard
                width: parent.width
                height: mediaBody.implicitHeight
                visible: root.isMedia

                readonly property real radius: Math.max(Style.space(12), Style.cornerRadius)

                // No cover: a quiet card of its own.
                Rectangle {
                  anchors.fill: parent
                  radius: mediaCard.radius
                  visible: !root.mediaHasCover
                  color: Util.alpha(root.popupFg, 0.06)
                }

                Rectangle {
                  id: mediaMask
                  anchors.fill: parent
                  radius: mediaCard.radius
                  visible: false
                  layer.enabled: true
                }

                // The cover and its veil are cut as one, with a soft edge: cut
                // apart, the cover shows as a bright line around the veil's corners.
                Item {
                  anchors.fill: parent
                  layer.enabled: root.isMedia
                  layer.smooth: true
                  layer.effect: MultiEffect {
                    maskEnabled: true
                    maskSource: mediaMask
                    maskThresholdMin: 0.5
                    maskSpreadAtMin: 1.0
                    autoPaddingEnabled: false
                  }

                  // Rests a little while paused. The next one crossfades in once
                  // loaded; no zoom, so nothing pokes out past the corners.
                  CoverSwap {
                    anchors.fill: parent
                    enterScale: 1
                    decodeSize: 512
                    source: root.isMedia ? root.coverUrl : ""
                    opacity: root.isMedia && !root.focused.playing ? 0.6 : 1
                    Behavior on opacity {
                      enabled: root.motion
                      NumberAnimation { duration: 250; easing.type: Easing.OutQuad }
                    }
                  }

                  Rectangle {
                    anchors.fill: parent
                    opacity: root.mediaHasCover ? 1 : 0
                    gradient: Gradient {
                      GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, 0.35) }
                      GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.72) }
                    }
                    Behavior on opacity {
                      enabled: root.motion
                      NumberAnimation { duration: 250 }
                    }
                  }
                }

                Column {
                  id: mediaBody
                  width: parent.width
                  readonly property real inner: width - leftPadding - rightPadding
                  leftPadding: Style.space(14)
                  rightPadding: Style.space(14)
                  topPadding: Style.space(10)
                  bottomPadding: Style.space(12)
                  spacing: Style.space(8)

                  // Where the sound comes from; a click opens the player.
                  Item {
                    width: mediaBody.inner
                    height: Math.max(mediaSource.height, mediaHide.implicitHeight)

                    Rectangle {
                      id: mediaSource
                      readonly property bool raisable: root.isMedia && root.focused.canRaise === true
                      anchors.left: parent.left
                      anchors.leftMargin: -Style.space(4)
                      anchors.verticalCenter: parent.verticalCenter
                      width: Math.min(parent.width - mediaHide.implicitWidth, sourceRow.implicitWidth + Style.space(12))
                      height: sourceRow.implicitHeight + Style.space(6)
                      radius: height / 2
                      color: Util.alpha(root.mediaFg, sourceArea.containsMouse ? 0.14 : 0)

                      Row {
                        id: sourceRow
                        anchors.left: parent.left
                        anchors.leftMargin: Style.space(4)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(6)

                        Image {
                          anchors.verticalCenter: parent.verticalCenter
                          visible: root.mediaApp !== null
                          width: Style.space(16)
                          height: width
                          source: root.mediaApp ? root.mediaApp.icon : ""
                          fillMode: Image.PreserveAspectFit
                          asynchronous: true
                          sourceSize.width: width * 2
                          sourceSize.height: height * 2
                        }

                        Text {
                          id: sourceName
                          anchors.verticalCenter: parent.verticalCenter
                          width: Math.min(implicitWidth, mediaSource.parent.width - mediaHide.implicitWidth - Style.space(52))
                          textFormat: Text.PlainText
                          // The album too, when there's room and it says something.
                          text: !root.isMedia ? "" : (root.focused.playerName || "Media")
                            + (root.focused.album && root.focused.album !== root.focused.title ? " \u00b7 " + root.focused.album : "")
                          color: Util.alpha(root.mediaFg, 0.78)
                          font.family: root.family
                          font.pixelSize: Style.font.caption
                          font.bold: true
                          elide: Text.ElideRight
                        }

                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          visible: mediaSource.raisable
                          textFormat: Text.PlainText
                          text: "\u{f0142}"
                          color: Util.alpha(root.mediaFg, 0.55)
                          font.family: root.family
                          font.pixelSize: Style.font.caption
                        }
                      }

                      MouseArea {
                        id: sourceArea
                        anchors.fill: parent
                        enabled: mediaSource.raisable
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.mediaKey("raise")
                      }

                      Tip {
                        visible: sourceArea.containsMouse
                        text: "Open the player"
                      }
                    }

                    Button {
                      id: mediaHide
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      iconText: "\u{f0209}"
                      foreground: Util.alpha(root.mediaFg, 0.85)
                      tooltipText: "Hide until it changes (x / right click)"
                      onClicked: if (root.service && root.focused) root.service.dismiss(root.focused.id)
                    }
                  }

                  // On a track change the old line (ghost) slides out while the
                  // new one slides in, both clipped to this box.
                  Item {
                    width: mediaBody.inner
                    height: liveLine.implicitHeight
                    clip: true

                    Marquee {
                      id: liveLine
                      width: parent.width
                      height: implicitHeight
                      text: root.isMedia ? root.focused.title : ""
                      secondary: root.isMedia && root.focused.artist ? "  \u2022  " + root.focused.artist : ""
                      color: root.mediaFg
                      pixelSize: Style.font.subtitle
                      bold: true
                      mode: "scroll"
                      playKey: text + secondary
                      active: root.opened
                      transform: Translate { id: trackShift }
                    }

                    MarqueeLine {
                      id: ghostLine
                      opacity: 0
                      visible: opacity > 0
                      text: root.ghostTitle
                      secondary: root.ghostArtist ? "  \u2022  " + root.ghostArtist : ""
                      color: root.mediaFg
                      pixelSize: Style.font.subtitle
                      bold: true
                      transform: Translate { id: ghostShift }
                    }
                  }

                  // Click or drag along the bar. The hills stand on the played part.
                  Item {
                    id: mediaSeek
                    width: mediaBody.inner
                    visible: root.isMedia && root.focused.progress >= 0
                    readonly property real peak: Style.space(16)
                    readonly property real handleRadius: Style.space(seekArea.containsMouse || dragging ? 8 : 7)
                    readonly property real barHeight: Style.space(4)
                    height: Math.ceil(peak * Model.HILLS_START) + Style.space(8)
                    readonly property real barY: height - Style.space(8)
                    readonly property bool seekable: root.isMedia && root.focused.seekable === true
                    property bool dragging: false
                    property real dragValue: 0
                    readonly property real shownValue: dragging ? dragValue : value
                    readonly property real handleX: handleRadius + (width - 2 * handleRadius) * shownValue

                    // Where the track is, and what the bar shows. While it plays,
                    // the bar glides to each new second in a straight line instead
                    // of jumping a step each tick; a jump (another track, a seek)
                    // goes there quickly; another card, at once.
                    readonly property real target: root.isMedia ? Math.max(0, Math.min(1, root.focused.progress)) : 0
                    property real value: 0
                    property string valueOf: ""
                    onTargetChanged: {
                      var id = root.isMedia ? root.focused.id : ""
                      seekGlide.stop()
                      if (id !== valueOf || !root.motion) { valueOf = id; value = target; return }
                      var ahead = (target - value) * root.focused.length
                      var flowing = root.focused.playing && ahead > 0 && ahead < 2.5
                      seekGlide.to = target
                      seekGlide.duration = flowing ? 1050 : 320
                      seekGlide.easing.type = flowing ? Easing.Linear : Easing.OutCubic
                      seekGlide.start()
                    }

                    NumberAnimation { id: seekGlide; target: mediaSeek; property: "value" }

                    MediaHills {
                      x: 0
                      y: 0
                      width: parent.width
                      height: parent.barY
                      value: mediaSeek.shownValue
                      end: mediaSeek.handleX
                      peak: mediaSeek.peak
                      unit: Style.space(10) / 10
                      color: root.accentFor(root.focused)
                      waving: root.isMedia && root.focused.playing === true
                      animate: root.motion
                      active: root.opened
                    }

                    // Still to play.
                    Rectangle {
                      readonly property real from: mediaSeek.handleX + mediaSeek.handleRadius + Style.space(4)
                      x: from
                      y: mediaSeek.barY - height / 2
                      width: Math.max(0, parent.width - from)
                      height: mediaSeek.barHeight
                      radius: height / 2
                      color: Util.alpha(root.mediaFg, 0.28)
                    }

                    // Played.
                    Rectangle {
                      x: 0
                      y: mediaSeek.barY - height / 2
                      width: mediaSeek.handleX
                      height: mediaSeek.barHeight
                      radius: height / 2
                      color: root.accentFor(root.focused)
                    }

                    // The bar's color in a white ring.
                    Rectangle {
                      visible: mediaSeek.seekable
                      width: mediaSeek.handleRadius * 2
                      height: width
                      radius: width / 2
                      x: mediaSeek.handleX - mediaSeek.handleRadius
                      y: mediaSeek.barY - mediaSeek.handleRadius
                      color: root.accentFor(root.focused)
                      border.color: "white"
                      border.width: Math.max(2, Style.space(2))
                    }

                    MouseArea {
                      id: seekArea
                      anchors.fill: parent
                      enabled: mediaSeek.seekable
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      function valueAt(x) { return Math.max(0, Math.min(1, x / mediaSeek.width)) }
                      onPressed: function(mouse) { mediaSeek.dragging = true; mediaSeek.dragValue = valueAt(mouse.x) }
                      onPositionChanged: function(mouse) { if (mediaSeek.dragging) mediaSeek.dragValue = valueAt(mouse.x) }
                      onReleased: {
                        if (mediaSeek.dragging && root.service && root.focused) root.service.seek(root.focused.id, mediaSeek.dragValue)
                        mediaSeek.dragging = false
                      }
                      onCanceled: mediaSeek.dragging = false
                    }

                    // The time under the pointer, before clicking (while dragging,
                    // the elapsed time below follows instead).
                    Rectangle {
                      readonly property real at: seekArea.valueAt(seekArea.mouseX) * (root.focused ? root.focused.length || 0 : 0)
                      visible: mediaSeek.seekable && seekArea.containsMouse && !mediaSeek.dragging && root.focused.length > 0
                      width: hoverTime.implicitWidth + Style.space(10)
                      height: hoverTime.implicitHeight + Style.space(4)
                      radius: height / 2
                      x: Math.max(0, Math.min(mediaSeek.width - width, seekArea.mouseX - width / 2))
                      y: mediaSeek.barY - mediaSeek.handleRadius - height - Style.space(2)
                      color: Color.tooltip.background

                      Text {
                        id: hoverTime
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: Model.formatDuration(parent.at * 1000)
                        color: Color.tooltip.text
                        font.family: root.family
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }

                  // 1:51 ......... ↺10 10↻ ......... -1:20 (follows a drag).
                  Item {
                    width: mediaBody.inner
                    height: Math.max(elapsedText.implicitHeight, seekKeys.height)
                    visible: root.isMedia && root.focused.length > 0
                    // The real position (or where it is being dragged to): the bar
                    // glides, the numbers don't count backwards on a track change.
                    readonly property real at: (mediaSeek.dragging ? mediaSeek.dragValue : mediaSeek.target) * (root.focused ? root.focused.length || 0 : 0)

                    Text {
                      id: elapsedText
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: Model.formatDuration(parent.at * 1000)
                      color: Util.alpha(root.mediaFg, 0.78)
                      font.family: root.family
                      font.pixelSize: Style.font.caption
                    }

                    // Long podcasts and videos.
                    Row {
                      id: seekKeys
                      anchors.centerIn: parent
                      spacing: Style.space(10)
                      MediaKey { actionId: "back10"; tip: "Back 10 s ([)" }
                      MediaKey { actionId: "forward10"; tip: "Forward 10 s (])" }
                    }

                    Text {
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: "-" + Model.formatDuration(Math.max(0, (root.focused ? root.focused.length || 0 : 0) - parent.at) * 1000)
                      color: Util.alpha(root.mediaFg, 0.78)
                      font.family: root.family
                      font.pixelSize: Style.font.caption
                    }
                  }

                  //   ⤨  ⏮  ( ⏯ )  ⏭  ⟳     (shuffle and repeat only if the player can)
                  Item {
                    width: mediaBody.inner
                    height: mediaKeys.height

                    Row {
                      id: mediaKeys
                      anchors.centerIn: parent
                      spacing: Style.space(10)

                      MediaKey { actionId: "shuffle"; on: root.isMedia && root.focused.shuffle === true; tip: "Shuffle" }
                      MediaKey { actionId: "previous"; keepPlace: true; tip: "Previous" }
                      MediaKey { actionId: "playPause"; primary: true; keepPlace: true; tip: "Play / pause (Enter, middle click)" }
                      MediaKey { actionId: "next"; keepPlace: true; tip: "Next" }
                      MediaKey {
                        actionId: "loop"
                        on: root.isMedia && root.focused.loop !== "" && root.focused.loop !== "none"
                        tip: root.isMedia && root.focused.loop === "track" ? "Repeat: this track" : (root.isMedia && root.focused.loop === "playlist" ? "Repeat: all" : "Repeat: off")
                      }
                    }
                  }

                  // Player volume (when the player reports one).
                  Row {
                    id: volumeRow
                    width: mediaBody.inner
                    spacing: Style.space(8)
                    visible: root.isMedia && root.focused.volume >= 0

                    property bool dragging: false
                    property real dragValue: 0
                    readonly property real level: dragging ? dragValue : (root.isMedia && root.focused.volume >= 0 ? root.focused.volume : 0)

                    Text {
                      id: volumeIcon
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: volumeRow.level <= 0 ? "\u{f0581}" : (volumeRow.level < 0.5 ? "\u{f0580}" : "\u{f057e}")
                      color: root.mediaFg
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
                        color: Util.alpha(root.mediaFg, 0.28)

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
                        // 5% per mouse wheel notch (120); a touchpad's many small
                        // deltas add up to the same, instead of 5% each. Quick
                        // steps build on the last one, not on the volume the
                        // player hasn't reported back yet.
                        property real wheelLevel: 0
                        property double wheelAt: 0
                        onWheel: function(wheel) {
                          if (!root.service || !root.focused || wheel.angleDelta.y === 0) return
                          var base = Date.now() - wheelAt < 800 ? wheelLevel : volumeRow.level
                          wheelLevel = Math.max(0, Math.min(1, base + wheel.angleDelta.y / 120 * 0.05))
                          wheelAt = Date.now()
                          root.service.setVolume(root.focused.id, wheelLevel)
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
                      color: Util.alpha(root.mediaFg, 0.78)
                      font.family: root.family
                      font.pixelSize: Style.font.caption
                    }
                  }
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
                    readonly property bool armed: root.focused !== null && root.armedAction === root.focused.id + "/" + modelData.id
                    iconText: modelData.icon
                    text: armed ? modelData.confirm : modelData.label
                    foreground: armed ? Color.urgent : root.popupFg
                    accent: root.accentFor(root.focused)
                    selected: index === 0
                    tooltipText: armed ? "Click again to do it" : (index === 0 ? "Enter / middle click" : "")
                    onClicked: root.runAction(modelData)
                  }
                }

                // Pushed activities already have Dismiss as their action.
                Button {
                  visible: Model.canDismiss(root.focused) && root.focused.module !== "push"
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
                color: Util.alpha(root.popupFg, 0.7)
                font.family: root.family
                font.pixelSize: Style.font.caption
              }
            }
          }

          // Hidden by hand (x, right click): never gone for good.
          Button {
            readonly property int hiddenCount: root.service ? root.service.hiddenList.length : 0
            visible: hiddenCount > 0
            iconText: "\u{f0208}"
            text: "Show " + hiddenCount + " hidden"
            foreground: Util.alpha(root.popupFg, 0.75)
            tooltipText: (root.service ? root.service.hiddenList.map(function(a) { return a.title }).join(", ") : "") + " (u)"
            onClicked: if (root.service) root.service.showHidden()
            opacity: root.stage(1)
            transform: Translate { x: root.enterShiftX(1); y: root.enterShiftY(1) }
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
                // "↗": opens something else (and closes the popup) instead of
                // switching on and off right here.
                { id: "record", icon: "\u{f0ec2}", label: "Record ↗", onLabel: "Stop rec", tip: "Screen recording: opens the recording menu", onTip: "Stop the screen recording" },
                { id: "reminder", icon: "\u{f088c}", label: "Remind ↗", tip: "Set a reminder: opens Omarchy's reminder panel" },
                { id: "dictation", icon: "\u{f036c}", label: "Dictate ↗", tip: "Dictation: opens voxtype's settings" }
              ]

              Button {
                required property var modelData
                readonly property bool on: root.service !== null && root.service.quickStates[modelData.id] === true
                visible: root.prefs.quickToggles.indexOf(modelData.id) !== -1
                  && (modelData.id !== "dictation" || (root.service !== null && root.service.hasVoxtype))
                iconText: modelData.icon
                text: on && modelData.onLabel ? modelData.onLabel : modelData.label
                foreground: root.popupFg
                accent: modelData.id === "record" && on ? Color.urgent : Color.accent
                selected: on
                tooltipText: on && modelData.onTip ? modelData.onTip : modelData.tip + (on ? " (on)" : "")
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
            foreground: Util.alpha(root.popupFg, 0.85)
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
                onClicked: root.requestStart("timer", modelData)
              }
            }

            Button {
              visible: root.prefs.quickStartExtras.indexOf("stopwatch") !== -1
              iconText: "\u{f520}"
              text: "Stopwatch"
              foreground: root.popupFg
              tooltipText: "Start the stopwatch (s)"
              onClicked: root.requestStart("stopwatch", 0)
            }

            Button {
              visible: root.prefs.quickStartExtras.indexOf("pomodoro") !== -1
              iconText: "\u{f04fe}"
              text: "Pomodoro"
              foreground: root.popupFg
              tooltipText: "Focus " + root.prefs.pomodoroFocus + " min, break " + root.prefs.pomodoroBreak + " min (p)"
              onClicked: root.requestStart("pomodoro", 0)
            }

            Button {
              visible: root.prefs.moduleMedia && root.prefs.quickStartExtras.indexOf("sleep") !== -1
              iconText: "\u{f04b2}"
              text: "Sleep " + Model.presetLabel(root.prefs.sleepMinutes * 60)
              foreground: root.popupFg
              tooltipText: "Pause the media in " + Model.presetLabel(root.prefs.sleepMinutes * 60) + " (length in the options)"
              onClicked: if (root.service) root.service.startSleep(root.prefs.sleepMinutes * 60)
            }
          }

          // "Replace the timer (18:32 left)?": the same press again does it.
          Text {
            width: parent.width
            visible: root.quickStartShown && root.pendingStart !== null
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: root.pendingStart ? root.pendingStart.warning + "  Press again to replace, Esc to keep it." : ""
            color: Color.urgent
            font.family: root.family
            font.pixelSize: Style.font.caption
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
              // Read `now` so "ends at" follows the clock while it sits there.
              readonly property var parsed: Model.timerArgHint(text, root.service ? root.service.now : Date.now())
              readonly property int seconds: parsed.seconds
              onAccepted: start()
              function start() {
                if (seconds <= 0 || !root.service) return
                root.requestStart("timer", seconds)
                // While it asks, the text and the keyboard stay here, so the
                // same Enter again replaces (and doesn't reach the card).
                if (root.pendingStart !== null) return
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
              tooltipText: customTimer.seconds > 0 ? "Start a " + Model.presetLabel(customTimer.seconds) + " timer (Enter)" : "Type a duration or a time"
              onClicked: customTimer.start()
            }
          }

          // What the field will do: "12 min · ends at 14:42", or how to write it.
          Text {
            width: parent.width
            visible: root.quickStartShown && customTimer.parsed.hint !== ""
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: customTimer.parsed.hint
            color: customTimer.seconds > 0 ? Util.alpha(root.popupFg, 0.65) : Color.urgent
            font.family: root.family
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
