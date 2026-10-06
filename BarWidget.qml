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
  readonly property string coverUrl: focused && focused.module === "media" && service ? service.safeArtPath : ""

  property bool settingsOpen: false
  onOpenedChanged: if (!opened) settingsOpen = false

  readonly property bool shown: count > 0 || prefs.whenEmpty === "icon"
  visible: shown
  implicitWidth: shown ? (vertical ? barSize : pill.width + Style.space(8)) : 0
  implicitHeight: shown ? (vertical ? pill.height + Style.space(8) : barSize) : 0

  readonly property real openPanelIndicatorWidth: pill.width
  readonly property real openPanelIndicatorHeight: pill.height

  readonly property bool tooltipHovered: pillArea.containsMouse && !opened

  readonly property color fg: bar ? bar.barForeground : Color.foreground
  readonly property color popupFg: bar ? bar.foreground : Color.foreground
  readonly property string family: bar ? bar.fontFamily : Style.font.family

  function accentFor(activity) {
    return activity && activity.urgent ? Color.urgent : Color.accent
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

    readonly property bool hasActivity: root.focused !== null
    readonly property real textMax: root.prefs.maxWidth
    readonly property real progress: hasActivity && root.prefs.showProgress ? root.focused.progress : -1

    height: root.vertical ? pillContent.implicitHeight + Style.space(12) : Math.max(Style.space(18), root.barSize - Style.space(10))
    width: root.vertical ? Math.max(Style.space(18), root.barSize - Style.space(10)) : pillContent.implicitWidth + Style.space(16)
    radius: Math.min(width, height) / 2
    color: hasActivity
      ? Util.alpha(root.accentFor(root.focused), pillArea.containsMouse || root.opened ? 0.28 : 0.18)
      : Util.alpha(root.fg, pillArea.containsMouse || root.opened ? 0.14 : 0.07)
    border.width: hasActivity && root.focused.urgent ? Math.max(1, Style.space(1)) : 0
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
        text: pill.hasActivity ? root.focused.icon : "\u{f0996}"
        color: pill.hasActivity && root.focused.urgent ? Color.urgent : root.fg
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

        readonly property string label: pill.hasActivity ? root.focused.pillText : "Nothing going on"
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
          text: root.count > 1 ? (root.focusIndex + 1) + "/" + root.count : ""
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
      color: root.accentFor(root.focused)

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
        if (root.focused && root.service) root.service.primary(root.focused.id)
      } else if (mouse.button === Qt.RightButton) {
        if (root.focused && root.service) root.service.dismiss(root.focused.id)
      } else {
        root.toggle()
      }
    }
    onWheel: function(wheel) {
      var d = wheel.angleDelta.y !== 0 ? wheel.angleDelta.y : -wheel.angleDelta.x
      root.wheelStep(d)
    }
    onEntered: if (root.bar) root.bar.showTooltip(root, Model.tooltipLabel(root.focused, root.focusIndex, root.count))
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  // --- popup --------------------------------------------------------------------

  readonly property var presets: [60, 300, 600, 1500]

  KeyboardPanel {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(360))
    contentHeight: popup.fittedContentHeight(root.settingsOpen ? settingsView.implicitHeight : column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (!root.settingsOpen && dx !== 0 && root.service) root.service.step(dx)
      }
      onTabRequested: function(direction) {
        if (!root.settingsOpen && root.service) root.service.step(direction)
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

            Row {
              width: parent.width
              spacing: Style.space(12)

              Rectangle {
                id: cardIcon
                // Media with cover art gets the cover, like omarchy-plugin-media.
                readonly property bool hasCover: root.coverUrl !== ""
                width: Style.space(hasCover ? 64 : 48)
                height: width
                radius: hasCover ? Style.spacing.labelGap : width / 2
                color: Util.alpha(root.accentFor(root.focused), 0.2)

                Image {
                  anchors.fill: parent
                  anchors.margins: Style.space(2)
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true
                  source: root.coverUrl
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

            Rectangle {
              width: parent.width
              visible: root.focused !== null && root.focused.progress >= 0
              height: Style.space(4)
              radius: height / 2
              color: Util.alpha(root.popupFg, 0.15)

              Rectangle {
                height: parent.height
                radius: parent.radius
                width: root.focused ? parent.width * Math.max(0, Math.min(1, root.focused.progress)) : 0
                color: root.accentFor(root.focused)
                Behavior on width { NumberAnimation { duration: 300 } }
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(2)
              visible: root.focused !== null && root.focused.details.length > 0

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
                  selected: index === 0
                  tooltipText: index === 0 ? "Enter / middle click" : ""
                  onClicked: if (root.service && root.focused) root.service.act(root.focused.id, modelData.id)
                }
              }

              // Pushed activities already have Dismiss as their action.
              Button {
                visible: root.focused !== null && root.focused.module !== "push"
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
        }
      }
    }
  }
}
