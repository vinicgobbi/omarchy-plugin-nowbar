import QtQuick
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
  readonly property string shotUrl: focused && focused.module === "screenshot" && focused.image ? Util.fileUrl(focused.image) : ""
  readonly property string cardImage: coverUrl || shotUrl

  // The weather card is "ambient": it counts in the carousel and in the "2/3"
  // like any activity, but never takes the pill from a live one. Alone, it is
  // the Now Brief, shown only with "When nothing is going on" set to Brief.
  readonly property bool isWeather: focused !== null && focused.module === "weather"
  readonly property int realCount: activities.filter(function(a) { return !a.ambient }).length
  readonly property var pillItem: focused !== null
    && (!focused.ambient || realCount > 0 || prefs.whenEmpty === "brief") ? focused : null

  property bool settingsOpen: false

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
    if (!opened) { settingsOpen = false; return }
    if (Date.now() - settingsRequestedAt < 2000) settingsOpen = true
    if (service) service.refreshWeatherIfStale()
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
  readonly property color coverAccent: service && service.artAccent !== "" ? Qt.lighter(service.artAccent, 1.0) : Color.accent
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
  readonly property bool popupThemed: urgentThemed || mediaThemed || weatherThemed
  readonly property string popupTint: urgentThemed ? Model.surfaceTint(Color.urgent.toString().slice(0, 7), darkTheme)
    : (mediaThemed ? Model.surfaceTint(service.artBase, darkTheme)
    : (weatherThemed ? Model.surfaceTint(focused.color, darkTheme) : ""))
  readonly property color popupAccent: urgentThemed ? Color.urgent
    : (mediaThemed ? coverAccent : (weatherThemed ? Qt.lighter(focused.color, 1.0) : Color.accent))
  readonly property var themeBorderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
  readonly property var popupBorderSpec: popupThemed
    ? { color: popupAccent, widths: themeBorderSpec.widths, gradient: { colors: [], angle: 0, enabled: false } }
    : themeBorderSpec

  function accentFor(activity) {
    if (activity && activity.urgent) return Color.urgent
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
  }

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
    pillSwap.restart()
    cardSwap.restart()
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
    color: hasActivity
      ? Util.alpha(root.accentFor(root.pillItem), pillArea.containsMouse || root.opened ? 0.28 : 0.18)
      : Util.alpha(root.fg, pillArea.containsMouse || root.opened ? 0.14 : 0.07)
    border.width: hasActivity && root.pillItem.urgent ? Math.max(1, Style.space(1)) : 0
    border.color: Util.alpha(Color.urgent, 0.8)
    clip: true

    Behavior on color {
      enabled: !root.bar || root.bar.foregroundAnimationEnabled
      ColorAnimation { duration: 180 }
    }

    // Horizontal: icon, text, "2/4", each in a fixed slot so the pill keeps
    // the same size whatever it shows. Vertical bars only have room for the icon.
    Row {
      id: pillContent
      anchors.centerIn: parent
      spacing: Style.space(6)

      Text {
        id: pillIcon
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(16)
        horizontalAlignment: Text.AlignHCenter
        textFormat: Text.PlainText
        text: pill.hasActivity ? root.pillItem.icon : "\u{f0996}"
        color: pill.hasActivity && root.pillItem.urgent ? Color.urgent : root.fg
        opacity: pill.hasActivity ? 1 : 0.6
        font.family: root.family
        font.pixelSize: Style.font.body
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

    // Thin progress line along the bottom of the pill.
    Rectangle {
      visible: pill.progress >= 0 && !root.vertical
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      anchors.leftMargin: pill.radius / 2
      anchors.bottomMargin: Math.max(1, Style.space(1))
      height: Math.max(2, Style.space(2))
      radius: height / 2
      width: Math.max(0, (pill.width - pill.radius) * Math.max(0, Math.min(1, pill.progress)))
      color: root.accentFor(root.pillItem)

      Behavior on width {
        enabled: !root.bar || root.bar.foregroundAnimationEnabled
        NumberAnimation { duration: 300 }
      }
    }

    // Slide the content in from the side it came from.
    ParallelAnimation {
      id: pillSwap
      NumberAnimation { target: pillContent; property: "anchors.horizontalCenterOffset"; from: root.slideFrom * Style.space(14); to: 0; duration: 200; easing.type: Easing.OutCubic }
      NumberAnimation { target: pillContent; property: "opacity"; from: 0; to: 1; duration: 200 }
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
    contentWidth: popup.fittedContentWidth(Style.space(360))
    contentHeight: popup.fittedContentHeight(root.settingsOpen ? settingsView.implicitHeight : column.implicitHeight)

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
        ColorAnimation { duration: 260 }
      }
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.settingsOpen && settingsView.editing

      onMoveRequested: function(dx, dy) {
        if (!root.settingsOpen && dx !== 0 && root.service) root.service.step(dx)
      }
      onTabRequested: function(direction) {
        if (root.settingsOpen) settingsView.cycleTab(direction)
        else if (root.service) root.service.step(direction)
      }
      onActivateRequested: {
        if (!root.settingsOpen && root.focused && root.service) root.service.primary(root.focused.id)
      }
      onDeleteRequested: {
        if (!root.settingsOpen && root.focused && root.service) root.service.dismiss(root.focused.id)
      }
      onCloseRequested: { if (root.settingsOpen) root.settingsOpen = false; else root.close() }
      onTextKey: function(t) {
        if (t === "q" || t === "Q") { if (root.settingsOpen) root.settingsOpen = false; else root.close(); return }
        if (t === "c" || t === "C") { root.settingsOpen = !root.settingsOpen; return }
        if (root.settingsOpen || !root.service) return
        var n = parseInt(t, 10)
        if (n >= 1 && n <= root.presets.length) root.service.startTimer(root.presets[n - 1])
        else if (t === "s" || t === "S") root.service.startStopwatch()
        else if (t === "p" || t === "P") root.service.startPomodoro()
      }

      Flickable {
        id: settingsFlick
        anchors.fill: parent
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
          onIndicatorsRequested: function(replace) { if (root.service) root.service.setIndicators(replace) }
          onWeatherWidgetRequested: function(replace) { if (root.service) root.service.setWeatherWidget(replace) }
          onBackRequested: root.settingsOpen = false
        }
      }

      Column {
        id: column
        visible: !root.settingsOpen
        anchors.fill: parent
        spacing: Style.space(10)

        // ‹  • • ●  ›                         ⚙
        Item {
          width: parent.width
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

                  Behavior on width { NumberAnimation { duration: 160 } }

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
                width: Style.space(root.shotUrl !== "" ? 96 : (hasCover ? 64 : 48))
                height: width
                radius: hasCover ? Style.spacing.labelGap : width / 2
                color: Util.alpha(root.accentFor(root.focused), 0.2)

                Image {
                  anchors.fill: parent
                  anchors.margins: Style.space(2)
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  sourceSize.width: 256
                  sourceSize.height: 256
                  source: root.cardImage
                  visible: cardIcon.hasCover && status === Image.Ready
                }

                Text {
                  visible: !cardIcon.hasCover
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: root.focused ? root.focused.icon : ""
                  color: root.focused && root.focused.urgent ? Color.urgent : root.popupFg
                  font.family: root.family
                  font.pixelSize: Style.font.display
                }
              }

              Column {
                width: parent.width - cardIcon.width - parent.spacing
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(3)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.focused ? root.focused.title : ""
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
                  text: root.focused ? root.focused.subtitle : ""
                  color: Qt.darker(root.popupFg, 1.35)
                  font.family: root.family
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }
              }
            }

            // Media you can seek: click or drag along the bar.
            Item {
              id: progressBar
              width: parent.width
              visible: root.focused !== null && root.focused.progress >= 0
              height: seekable ? Style.space(16) : Style.space(4)

              readonly property bool seekable: root.focused !== null && root.focused.seekable === true
              property bool dragging: false
              property real dragValue: 0
              readonly property real shownValue: dragging ? dragValue
                : (root.focused ? Math.max(0, Math.min(1, root.focused.progress)) : 0)

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                height: Style.space(4)
                radius: height / 2
                color: Util.alpha(root.popupFg, 0.15)

                Rectangle {
                  height: parent.height
                  radius: parent.radius
                  width: parent.width * progressBar.shownValue
                  color: root.accentFor(root.focused)
                  Behavior on width {
                    enabled: !progressBar.dragging
                    NumberAnimation { duration: 300 }
                  }
                }
              }

              Rectangle {
                visible: progressBar.seekable
                readonly property real size: Style.space(progressBar.dragging ? 14 : 10)
                width: size
                height: size
                radius: size / 2
                anchors.verticalCenter: parent.verticalCenter
                x: Math.max(0, Math.min(progressBar.width - size, progressBar.width * progressBar.shownValue - size / 2))
                color: root.accentFor(root.focused)
              }

              MouseArea {
                anchors.fill: parent
                enabled: progressBar.seekable
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

            Column {
              width: parent.width
              spacing: Style.space(2)
              visible: root.focused !== null && root.focused.details.length > 0 && !root.isWeather

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

            Flow {
              width: parent.width
              spacing: Style.space(6)

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
                  onClicked: if (root.service && root.focused) root.service.act(root.focused.id, modelData.id)
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
              NumberAnimation { target: card; property: "x"; from: root.slideFrom * Style.space(28); to: 0; duration: 220; easing.type: Easing.OutCubic }
              NumberAnimation { target: card; property: "opacity"; from: 0; to: 1; duration: 220 }
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

        PanelSeparator { foreground: root.popupFg }

        // Everything Omarchy's indicators widget does, both ways: lit when on.
        PanelSectionHeader {
          text: "QUICK TOGGLES"
          foreground: root.popupFg
          fontFamily: root.family
          visible: root.prefs.showQuickToggles
        }

        Flow {
          width: parent.width
          spacing: Style.space(6)
          visible: root.prefs.showQuickToggles

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
              visible: modelData.id !== "dictation" || (root.service !== null && root.service.hasVoxtype)
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
          visible: root.prefs.showQuickToggles && root.service !== null && root.service.indicatorsState === "native"
          iconText: "\u{f009b}"
          text: "Use instead of Omarchy's indicators"
          foreground: Qt.darker(root.popupFg, 1.2)
          tooltipText: "Turns Omarchy's indicators widget off; these toggles do the same (undo in the options)"
          onClicked: root.service.setIndicators(true)
        }

        PanelSeparator {
          foreground: root.popupFg
          visible: root.prefs.showQuickToggles
        }

        PanelSectionHeader {
          text: "QUICK START"
          foreground: root.popupFg
          fontFamily: root.family
          visible: root.prefs.moduleTimer
        }

        Flow {
          width: parent.width
          spacing: Style.space(6)
          visible: root.prefs.moduleTimer

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
            iconText: "\u{f520}"
            text: "Stopwatch"
            foreground: root.popupFg
            tooltipText: "Start the stopwatch (s)"
            onClicked: if (root.service) root.service.startStopwatch()
          }

          Button {
            iconText: "\u{f04fe}"
            text: "Pomodoro"
            foreground: root.popupFg
            tooltipText: "Focus " + root.prefs.pomodoroFocus + " min, break " + root.prefs.pomodoroBreak + " min (p)"
            onClicked: if (root.service) root.service.startPomodoro()
          }

          Button {
            visible: root.prefs.moduleMedia
            iconText: "\u{f04b2}"
            text: "Sleep 30 min"
            foreground: root.popupFg
            tooltipText: "Pause the media in 30 minutes"
            onClicked: if (root.service) root.service.startSleep(1800)
          }
        }
      }
    }
  }
}
