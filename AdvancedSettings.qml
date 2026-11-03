import QtQuick
import QtQuick.Controls as QQC
import qs.Ui
import qs.Commons
import "NowbarModel.js" as Model

// Options view shown inside the popup (gear button or "c"). It only reads the
// preferences it is given and reports changes upward; BarWidget.qml stores
// them on the widget's shell.json entry. Built from the shell's own controls
// so it looks like the other Omarchy panels.
//
// A list and its details, like a phone's settings: the first page says what can
// show up and where each thing stands, and whatever has more to set opens a page
// of its own. What is rarely changed waits under "More" there.
//   home       the activities, and the way into the rest
//   media      paused players, players shown
//   timers     when a timer ends, Pomodoro
//   weather    place, temperature unit
//   updates    what is checked, and how often
//   look       what the pill looks like
//   shortcuts  the popup's Quick toggles and Quick start
//   omarchy    taking over Omarchy's own widgets
Column {
  id: root

  property var prefs: ({})
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property bool motion: true

  // One of Model.SETTINGS_PAGES.
  property string page: "home"

  readonly property var pageInfo: ({
    home: { title: "Now Bar options" },
    media: { title: "Music & video", key: "moduleMedia" },
    timers: { title: "Timers & Pomodoro", key: "moduleTimer" },
    weather: { title: "Weather", key: "moduleWeather" },
    updates: { title: "Updates", key: "moduleUpdates" },
    look: { title: "Appearance" },
    shortcuts: { title: "Popup shortcuts" },
    omarchy: { title: "Omarchy integration" }
  })
  readonly property var current: pageInfo[page] || pageInfo.home
  // The page's own activity, when it has one, is on.
  readonly property bool pageOn: !current.key || prefs[current.key] === true

  // A page comes in from the right; back to the list, from the left.
  onPageChanged: {
    var back = page === "home"
    cursor = -1
    moreOpen = false
    pageIn.stop()
    pageShift.x = 0
    pageBody.opacity = 1
    if (!motion) return
    pageSlide.from = (back ? -1 : 1) * Style.space(28)
    pageIn.start()
  }

  // True while typing in a text field: the popup's key shortcuts step aside.
  readonly property bool editing: presetsField.activeFocus || locationField.activeFocus

  // "replaced" / "native" / "" (unknown) — see bin/nowbar-weather-widget and
  // Service.qml's setIndicators.
  property string weatherWidgetState: ""
  property string indicatorsState: ""
  // The update sources this system can check (Flatpak only when installed).
  property var updateSourcesAvailable: []
  // Media players around now; with the ignored ones, the "Show" list.
  property var playerNames: []
  readonly property var playerList: {
    var out = []
    var seen = {}
    var names = (playerNames || []).concat(root.prefs.ignoredPlayers || [])
    for (var i = 0; i < names.length; i++) {
      var key = String(names[i]).toLowerCase()
      if (key && !seen[key]) { seen[key] = true; out.push(names[i]) }
    }
    return out
  }

  signal changed(string name, var value)
  signal weatherWidgetRequested(bool replace)
  signal indicatorsRequested(bool replace)
  signal resetRequested()
  signal backRequested()
  // Keep this part of the view on screen (y and height in the view).
  signal ensureVisible(real y, real h)
  // ↑/↓ on a page: scroll that way (-1, 1).
  signal scrollRequested(int direction)
  // Weather location (Service.qml): search by name, pick one (null:
  // automatic), and hand the keyboard back to the popup when done.
  signal locationSearch(string text)
  signal locationPicked(var place)
  signal keysReleased()

  // Omarchy's saved place ({ name, latitude, longitude }; no name: automatic),
  // the one being saved, and what wttr.in placed the IP in.
  property var weatherLocation: ({ name: "", latitude: null, longitude: null })
  property var weatherLocationSaving: null
  property string detectedPlace: ""
  property bool locationEditable: false
  property var locationResults: []
  property bool locationSearching: false
  property bool locationSearchFailed: false
  property int locationIndex: 0
  onLocationResultsChanged: locationIndex = 0

  function pickLocation(place) {
    root.locationPicked(place)
    locationField.text = ""
    root.keysReleased()
  }

  // What the list's lines say about the pages.
  readonly property var summaryInfo: ({
    place: weatherLocation.name !== "" ? weatherLocation.name : (detectedPlace !== "" ? detectedPlace + " (automatic)" : ""),
    indicators: indicatorsState,
    weatherWidget: weatherWidgetState
  })
  function summary(p) { return Model.settingsSummary(p, prefs, summaryInfo) }

  // --- keyboard ------------------------------------------------------------------

  // The first page, top to bottom: ↑/↓ walk it, Enter opens or switches.
  // { id, page } opens a page; { id, key } flips a preference.
  readonly property var homeItems: [
    { id: "media", page: "media" },
    { id: "timers", page: "timers" },
    { id: "weather", page: "weather" },
    { id: "updates", page: "updates" },
    { id: "moduleReminders", key: "moduleReminders" },
    { id: "moduleRecording", key: "moduleRecording" },
    { id: "moduleDictation", key: "moduleDictation" },
    { id: "modulePrivacy", key: "modulePrivacy" },
    { id: "moduleModes", key: "moduleModes" },
    { id: "moduleCharging", key: "moduleCharging" },
    { id: "moduleBluetooth", key: "moduleBluetooth" },
    { id: "moduleScreenshot", key: "moduleScreenshot" },
    { id: "modulePush", key: "modulePush" },
    { id: "autoFocus", key: "autoFocus" },
    { id: "look", page: "look" },
    { id: "shortcuts", page: "shortcuts" },
    { id: "omarchy", page: "omarchy" }
  ]
  property int cursor: -1
  readonly property string cursorId: page === "home" && cursor >= 0 ? homeItems[cursor].id : ""

  function moveCursor(delta) {
    if (page !== "home") {
      // A page has no list to walk: the arrows scroll it.
      scrollRequested(delta)
      return
    }
    cursor = Math.max(0, Math.min(homeItems.length - 1, cursor + delta))
  }

  function activate() {
    if (page !== "home" || cursor < 0) return
    var item = homeItems[cursor]
    if (item.page) page = item.page
    else changed(item.key, prefs[item.key] !== true)
  }

  // A row the cursor reached says where it is.
  function reveal(item) {
    var at = item.mapToItem(root, 0, 0)
    ensureVisible(at.y, item.height)
  }

  // Tab / Shift+Tab: the pages, in order.
  function cycleTab(direction) {
    var pages = Model.SETTINGS_PAGES
    var i = pages.indexOf(page)
    page = pages[((i + direction) % pages.length + pages.length) % pages.length]
  }

  // Esc, q, the arrow: one level up. False when already on the first page.
  function back() {
    if (page === "home") return false
    page = "home"
    return true
  }

  spacing: Style.space(10)

  // "Name ........ control" line, optionally with a small explanation.
  component Option: Item {
    id: opt
    property string label: ""
    property string hint: ""
    default property alias control: controlHolder.children

    width: parent ? parent.width : 0
    height: Math.max(textCol.implicitHeight, controlHolder.implicitHeight)

    Column {
      id: textCol
      anchors.left: parent.left
      anchors.right: controlHolder.left
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: opt.label
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        visible: opt.hint !== ""
        text: opt.hint
        color: Util.alpha(root.foreground, 0.62)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    Row {
      id: controlHolder
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)
    }
  }

  // Boolean option with a switch.
  component SwitchOption: Option {
    id: so
    property string key: ""
    ToggleSwitch {
      foreground: root.foreground
      checked: root.prefs[so.key] === true
      onToggled: root.changed(so.key, !checked)
    }
  }

  // Same look as the shell's buttons' tooltips.
  component Tip: QQC.ToolTip {
    id: tipBox
    delay: 500
    padding: 0
    background: BorderSurface {
      color: Color.tooltip.background
      borderSpec: Border.localOrSurfaceSpec("tooltip", "border", Color.tooltip.border, Color.tooltip.border, Math.max(1, Style.normalBorderWidth))
      radius: 0
    }
    contentItem: Text {
      textFormat: Text.PlainText
      text: tipBox.text
      wrapMode: Text.WordWrap
      width: Math.min(implicitWidth, Style.space(280))
      color: Color.tooltip.text
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      leftPadding: Style.spacing.controlPaddingX
      rightPadding: Style.spacing.controlPaddingX
      topPadding: Style.spacing.controlPaddingY
      bottomPadding: Style.spacing.controlPaddingY
    }
  }

  // A line of the first page: name and where it stands, its switch if it is an
  // activity, and a way into its page.
  component NavRow: Rectangle {
    id: nav
    property string target: ""
    property string glyph: ""
    property string label: ""
    property string key: ""
    readonly property bool lit: root.cursorId === target
    readonly property bool dimmed: key !== "" && root.prefs[key] !== true

    width: parent ? parent.width : 0
    height: navText.implicitHeight + Style.space(12)
    radius: Style.spacing.labelGap
    color: Util.alpha(root.foreground, lit ? 0.14 : (navArea.containsMouse ? 0.08 : 0))
    onLitChanged: if (lit) root.reveal(nav)

    MouseArea {
      id: navArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.page = nav.target
    }

    Text {
      id: navGlyph
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(22)
      textFormat: Text.PlainText
      text: nav.glyph
      color: nav.dimmed ? Util.alpha(root.foreground, 0.5) : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Column {
      id: navText
      anchors.left: navGlyph.right
      anchors.right: navSwitch.visible ? navSwitch.left : navChevron.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(1)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: nav.label
        color: nav.dimmed ? Util.alpha(root.foreground, 0.62) : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: root.summary(nav.target)
        color: Util.alpha(root.foreground, 0.62)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }

    ToggleSwitch {
      id: navSwitch
      visible: nav.key !== ""
      anchors.right: navChevron.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      foreground: root.foreground
      checked: root.prefs[nav.key] === true
      onToggled: root.changed(nav.key, !checked)
    }

    Text {
      id: navChevron
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: "\u{f0142}"
      color: Util.alpha(root.foreground, 0.55)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
  }

  // Half-width "glyph Name [switch]" cell for an activity with nothing else to
  // set. `tip`: what it is, on hover over the name.
  component Cell: Rectangle {
    id: cell
    property string label: ""
    property string glyph: ""
    property string key: ""
    property string tip: ""
    readonly property bool lit: root.cursorId === key

    width: parent ? (parent.width - parent.columnSpacing) / 2 : 0
    height: Math.max(cellLabel.implicitHeight, cellSwitch.implicitHeight) + Style.space(4)
    radius: Style.spacing.labelGap
    color: Util.alpha(root.foreground, lit ? 0.14 : 0)
    onLitChanged: if (lit) root.reveal(cell)

    Text {
      id: cellGlyph
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(22)
      textFormat: Text.PlainText
      text: cell.glyph
      color: root.prefs[cell.key] === true ? root.foreground : Util.alpha(root.foreground, 0.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      id: cellLabel
      textFormat: Text.PlainText
      anchors.left: cellGlyph.right
      anchors.right: cellSwitch.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: cell.label
      color: root.prefs[cell.key] === true ? root.foreground : Util.alpha(root.foreground, 0.62)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    ToggleSwitch {
      id: cellSwitch
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      foreground: root.foreground
      checked: root.prefs[cell.key] === true
      onToggled: root.changed(cell.key, !checked)
    }

    MouseArea {
      id: cellHover
      anchors.left: parent.left
      anchors.right: cellSwitch.left
      height: parent.height
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    Tip {
      visible: cell.tip !== "" && cellHover.containsMouse
      text: cell.tip
    }
  }

  // Half-width "glyph Name [switch]" cell for one item of a list preference
  // ("a,b,c" in settings, like quickToggleItems).
  component ListCell: Item {
    id: lc
    property string label: ""
    property string glyph: ""
    property string listKey: ""       // the setting, e.g. "quickToggleItems"
    property var list: []             // its parsed value (prefs.quickToggles...)
    property var allowed: []          // every id, in order
    property string itemId: ""
    property bool active: true        // the section itself is shown
    readonly property bool on: list.indexOf(itemId) !== -1

    width: parent ? (parent.width - parent.columnSpacing) / 2 : 0
    height: Math.max(lcLabel.implicitHeight, lcSwitch.implicitHeight)
    opacity: active ? 1 : 0.45

    Text {
      id: lcGlyph
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(20)
      textFormat: Text.PlainText
      text: lc.glyph
      color: lc.on ? root.foreground : Util.alpha(root.foreground, 0.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    Text {
      id: lcLabel
      textFormat: Text.PlainText
      anchors.left: lcGlyph.right
      anchors.right: lcSwitch.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: lc.label
      color: lc.on ? root.foreground : Util.alpha(root.foreground, 0.62)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    ToggleSwitch {
      id: lcSwitch
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      foreground: root.foreground
      interactive: lc.active
      checked: lc.on
      onToggled: root.changed(lc.listKey, Model.toggleIdList(lc.list, lc.allowed, lc.itemId, !checked))
    }
  }

  // A line saying what a page, or a part of it, is about.
  component Intro: Text {
    width: parent ? parent.width : 0
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Util.alpha(root.foreground, 0.7)
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }

  // "Replace / Restore one of Omarchy's widgets" block: the state, what the
  // button does, an optional warning, and the button, each on its own line.
  component WidgetSwap: Rectangle {
    id: swap
    property string swapState: ""      // "replaced" | "native" | ""
    property string glyph: ""
    property string replacedTitle: ""
    property string nativeTitle: ""
    property string replacedText: ""
    property string nativeText: ""
    property string warning: ""
    property string replaceLabel: "Replace"
    property string restoreLabel: "Restore"
    signal requested(bool replace)

    width: parent ? parent.width : 0
    height: swapCol.implicitHeight + Style.space(20)
    radius: Style.spacing.labelGap
    color: Util.alpha(root.foreground, 0.06)

    Column {
      id: swapCol
      anchors.centerIn: parent
      width: parent.width - Style.space(20)
      spacing: Style.space(8)

      Row {
        spacing: Style.space(8)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: swap.swapState === "replaced" ? "\u{f012c}" : swap.glyph
          color: swap.swapState === "replaced" ? Color.accent : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: swap.swapState === "replaced" ? swap.replacedTitle : (swap.swapState === "native" ? swap.nativeTitle : "Checking\u2026")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
        }
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: swap.swapState === "replaced" ? swap.replacedText : swap.nativeText
        color: Util.alpha(root.foreground, 0.75)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        width: parent.width
        visible: swap.warning !== ""
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: "\u{f0026}  " + swap.warning
        color: Util.alpha(root.foreground, 0.62)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Button {
        text: swap.swapState === "replaced" ? swap.restoreLabel : swap.replaceLabel
        iconText: swap.swapState === "replaced" ? "\u{f099b}" : swap.glyph
        foreground: root.foreground
        bordered: true
        enabled: swap.swapState !== ""
        opacity: enabled ? 1 : 0.5
        onClicked: swap.requested(swap.swapState !== "replaced")
      }
    }
  }

  component Section: PanelSectionHeader {
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  // What is rarely changed stays out of the way until asked for (one "More" per
  // page; it closes when the page changes).
  property bool moreOpen: false

  component More: Column {
    default property alias content: moreBody.children
    width: parent ? parent.width : 0
    spacing: Style.space(10)

    Rectangle {
      width: parent.width
      height: moreLine.implicitHeight + Style.space(10)
      radius: Style.spacing.labelGap
      color: Util.alpha(root.foreground, moreArea.containsMouse ? 0.08 : 0)

      Text {
        id: moreLine
        anchors.left: parent.left
        anchors.leftMargin: Style.space(2)
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: (root.moreOpen ? "\u{f0140}" : "\u{f0142}") + "  More"
        color: Util.alpha(root.foreground, 0.75)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
      }

      MouseArea {
        id: moreArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.moreOpen = !root.moreOpen
      }
    }

    Column {
      id: moreBody
      width: parent.width
      spacing: Style.space(10)
      visible: root.moreOpen
    }
  }

  // --- header (always shown) -------------------------------------------------------

  Item {
    width: parent.width
    height: backButton.implicitHeight

    Button {
      id: backButton
      iconText: "\u{f004d}"
      foreground: root.foreground
      tooltipText: "Back (Esc)"
      onClicked: if (!root.back()) root.backRequested()
    }

    Text {
      textFormat: Text.PlainText
      anchors.left: backButton.right
      anchors.leftMargin: Style.space(8)
      anchors.right: headerSwitch.visible ? headerSwitch.left : parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: root.current.title
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
      elide: Text.ElideRight
    }

    // The same switch as in the list, for a page that belongs to an activity.
    ToggleSwitch {
      id: headerSwitch
      visible: !!root.current.key
      anchors.right: parent.right
      anchors.rightMargin: Style.space(4)
      anchors.verticalCenter: parent.verticalCenter
      foreground: root.foreground
      checked: root.pageOn
      onToggled: root.changed(root.current.key, !checked)
    }
  }

  // --- the page --------------------------------------------------------------------

  ParallelAnimation {
    id: pageIn
    NumberAnimation { id: pageSlide; target: pageShift; property: "x"; to: 0; duration: 260; easing.type: Easing.OutQuint }
    NumberAnimation { target: pageBody; property: "opacity"; from: 0; to: 1; duration: 180; easing.type: Easing.OutCubic }
  }

  Column {
    id: pageBody
    width: parent.width
    spacing: Style.space(10)
    transform: Translate { id: pageShift }

    // --- first page ----------------------------------------------------------------

    Column {
      width: parent.width
      spacing: Style.space(8)
      visible: root.page === "home"

      Section { text: "WHAT CAN SHOW UP" }

      Column {
        width: parent.width
        spacing: Style.space(2)

        NavRow { target: "media"; glyph: "\u{f075a}"; label: "Music & video"; key: "moduleMedia" }
        NavRow { target: "timers"; glyph: "\u{f13ab}"; label: "Timers & Pomodoro"; key: "moduleTimer" }
        NavRow { target: "weather"; glyph: "\u{f0599}"; label: "Weather"; key: "moduleWeather" }
        NavRow { target: "updates"; glyph: "\u{f06b0}"; label: "Updates"; key: "moduleUpdates" }
      }

      Grid {
        width: parent.width
        columns: 2
        columnSpacing: Style.space(10)
        rowSpacing: Style.space(4)

        Cell { glyph: "\u{f088c}"; label: "Reminders"; key: "moduleReminders"; tip: "Reminders set with omarchy-reminder: the next one, and when one goes off" }
        Cell { glyph: "\u{f044a}"; label: "Recording"; key: "moduleRecording"; tip: "Screen recording: elapsed time, Stop, and the saved video" }
        Cell { glyph: "\u{f036c}"; label: "Dictation"; key: "moduleDictation"; tip: "Voxtype dictation: listening / transcribing" }
        Cell { glyph: "\u{f0100}"; label: "Camera & mic"; key: "modulePrivacy"; tip: "An app using the camera or the microphone, and which one" }
        Cell { glyph: "\u{f009b}"; label: "Modes & VPN"; key: "moduleModes"; tip: "Do Not Disturb, stay awake, night light and VPN connections while they're on" }
        Cell { glyph: "\u{f0084}"; label: "Battery"; key: "moduleCharging"; tip: "Charging (with time until full) and low battery" }
        Cell { glyph: "\u{f00b1}"; label: "Bluetooth"; key: "moduleBluetooth"; tip: "A device that just connected, and one with low battery" }
        Cell { glyph: "\u{f0e51}"; label: "Screenshots"; key: "moduleScreenshot"; tip: "A screenshot just taken: Edit / Copy / Open" }
        Cell { glyph: "\u{f0996}"; label: "Scripts"; key: "modulePush"; tip: "Activities sent by your scripts with nowbar push or nowbar-run" }
      }

      Rectangle {
        id: focusRow
        readonly property bool lit: root.cursorId === "autoFocus"
        width: parent.width
        height: focusOption.height + Style.space(8)
        radius: Style.spacing.labelGap
        color: Util.alpha(root.foreground, lit ? 0.14 : 0)
        onLitChanged: if (lit) root.reveal(focusRow)

        SwitchOption {
          id: focusOption
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: Style.space(6)
          anchors.rightMargin: Style.space(4)
          anchors.verticalCenter: parent.verticalCenter
          key: "autoFocus"
          label: "New activities take the pill"
          hint: "Unless you switched by hand a moment ago."
        }
      }

      Section { text: "GENERAL" }

      Column {
        width: parent.width
        spacing: Style.space(2)

        NavRow { target: "look"; glyph: "\u{f03d8}"; label: "Appearance" }
        NavRow { target: "shortcuts"; glyph: "\u{f0431}"; label: "Popup shortcuts" }
        NavRow { target: "omarchy"; glyph: "\u{f08c7}"; label: "Omarchy integration" }
      }

      // Every option at once (hidden players, timers...): a second click within
      // a few seconds does it.
      Button {
        id: resetButton
        property bool armed: false
        text: armed ? "Click again to restore everything" : "Restore defaults"
        foreground: armed ? Color.urgent : Util.alpha(root.foreground, 0.7)
        tooltipText: armed ? "Every option goes back to its default" : "Every option goes back to its default (asks first)"
        onClicked: {
          if (!armed) { armed = true; resetDisarm.restart(); return }
          armed = false
          root.resetRequested()
        }

        Timer {
          id: resetDisarm
          interval: 4000
          onTriggered: resetButton.armed = false
        }
      }
    }

    // --- Music & video -------------------------------------------------------------

    Column {
      width: parent.width
      spacing: Style.space(10)
      visible: root.page === "media"
      enabled: root.pageOn
      opacity: root.pageOn ? 1 : 0.45

      Option {
        label: "Paused player"
        hint: "Gives up the pill after this long, and stays in the carousel."
        ButtonGroup {
          foreground: root.foreground
          fontFamily: root.fontFamily
          options: [
            { value: "0", label: "Never" },
            { value: "5", label: "5m" },
            { value: "15", label: "15m" },
            { value: "60", label: "1h" }
          ]
          value: String(root.prefs.mediaPausedMinutes)
          onChanged: function(v) { root.changed("mediaPausedMinutes", parseInt(v, 10)) }
        }
      }

      Section { text: "PLAYERS SHOWN" }

      Intro {
        text: root.playerList.length > 0
          ? "A hidden player still answers the media keys."
          : "Players show up here while they are open, to hide the ones you don't want."
      }

      Grid {
        width: parent.width
        columns: 2
        columnSpacing: Style.space(16)
        rowSpacing: Style.space(8)
        visible: root.playerList.length > 0

        Repeater {
          model: root.playerList

          Item {
            id: pc
            required property var modelData
            readonly property bool shown: !Model.isIgnoredPlayer(root.prefs.ignoredPlayers || [], [modelData])
            width: (parent.width - parent.columnSpacing) / 2
            height: Math.max(pcLabel.implicitHeight, pcSwitch.implicitHeight)

            Text {
              id: pcGlyph
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(20)
              textFormat: Text.PlainText
              text: "\u{f075a}"
              color: pc.shown ? root.foreground : Util.alpha(root.foreground, 0.5)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              id: pcLabel
              textFormat: Text.PlainText
              anchors.left: pcGlyph.right
              anchors.right: pcSwitch.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              text: pc.modelData
              color: pc.shown ? root.foreground : Util.alpha(root.foreground, 0.62)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            ToggleSwitch {
              id: pcSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              foreground: root.foreground
              checked: pc.shown
              onToggled: root.changed("mediaIgnore", Model.toggleIgnoredPlayer(root.prefs.mediaIgnore, pc.modelData, checked))
            }
          }
        }
      }
    }

    // --- Timers & Pomodoro ---------------------------------------------------------

    Column {
      width: parent.width
      spacing: Style.space(10)
      visible: root.page === "timers"
      enabled: root.pageOn
      opacity: root.pageOn ? 1 : 0.45

      Section { text: "WHEN A TIMER ENDS" }

      SwitchOption {
        key: "timerSound"
        label: "Play a sound"
        hint: "Not with Do Not Disturb on."
      }

      Option {
        label: "\"Time's up\" stays"
        hint: "With Repeat / +1 min / OK."
        ButtonGroup {
          foreground: root.foreground
          fontFamily: root.fontFamily
          options: [
            { value: "0", label: "Until OK" },
            { value: "1", label: "1m" },
            { value: "5", label: "5m" },
            { value: "30", label: "30m" }
          ]
          value: String(root.prefs.timerDoneMinutes)
          onChanged: function(v) { root.changed("timerDoneMinutes", parseInt(v, 10)) }
        }
      }

      Section { text: "POMODORO" }

      Option {
        label: "Focus (min)"
        NumberField {
          foreground: root.foreground
          fontFamily: root.fontFamily
          value: root.prefs.pomodoroFocus
          from: 1
          to: 180
          stepSize: 5
          onModified: function(v) { root.changed("pomodoroFocus", v) }
        }
      }

      Option {
        label: "Break (min)"
        NumberField {
          foreground: root.foreground
          fontFamily: root.fontFamily
          value: root.prefs.pomodoroBreak
          from: 1
          to: 60
          stepSize: 1
          onModified: function(v) { root.changed("pomodoroBreak", v) }
        }
      }

      Option {
        label: "Long break (min)"
        hint: "Every 4th break."
        NumberField {
          foreground: root.foreground
          fontFamily: root.fontFamily
          value: root.prefs.pomodoroLongBreak
          from: 1
          to: 120
          stepSize: 5
          onModified: function(v) { root.changed("pomodoroLongBreak", v) }
        }
      }

      SwitchOption {
        key: "pomodoroDnd"
        label: "Do Not Disturb while focusing"
        hint: "Off again for the breaks (left alone if it was already on)."
      }

      Intro { text: "The buttons that start timers are in Popup shortcuts." }
    }

    // --- Weather ---------------------------------------------------------------------

    Column {
      width: parent.width
      spacing: Style.space(10)
      visible: root.page === "weather"
      enabled: root.pageOn
      opacity: root.pageOn ? 1 : 0.45

      Section { text: "PLACE" }

      // What it uses now: the saved place, or automatic and where the IP is.
      Text {
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        readonly property var shown: root.weatherLocationSaving !== null ? root.weatherLocationSaving : root.weatherLocation
        text: root.weatherLocationSaving !== null
          ? "\u{f034e}  Saving " + (shown.name !== "" ? shown.name : "automatic") + "…"
          : (shown.name !== ""
            ? "\u{f034e}  " + shown.name + (shown.latitude !== null ? "  (" + shown.latitude + ", " + shown.longitude + ")" : "")
            : "\u{f034e}  Automatic: " + (root.detectedPlace !== "" ? root.detectedPlace + ", a guess from your IP" : "a guess from your IP"))
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }

      TextField {
        id: locationField
        width: parent.width
        visible: root.locationEditable
        foreground: root.foreground
        font.family: root.fontFamily
        placeholderText: "Search a city to use instead"
        onTextChanged: root.locationSearch(text)
        // ↑/↓ choose among the places found, Enter takes it, Esc gives up.
        Keys.onDownPressed: root.locationIndex = Math.min(root.locationResults.length - 1, root.locationIndex + 1)
        Keys.onUpPressed: root.locationIndex = Math.max(0, root.locationIndex - 1)
        Keys.onEscapePressed: { text = ""; root.keysReleased() }
        onAccepted: if (root.locationResults.length > 0) root.pickLocation(root.locationResults[root.locationIndex])
      }

      Text {
        width: parent.width
        visible: root.locationEditable && locationField.text.trim().length >= 2
          && (root.locationSearching || root.locationSearchFailed || root.locationResults.length === 0)
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: root.locationSearching ? "Searching…"
          : (root.locationSearchFailed ? "Couldn't search (offline?)" : "No place found with that name")
        color: root.locationSearchFailed ? Color.urgent : Util.alpha(root.foreground, 0.62)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: root.locationEditable && locationField.text.trim().length >= 2 && root.locationResults.length > 0

        Repeater {
          model: root.locationResults

          Button {
            required property var modelData
            required property int index
            width: parent.width
            leftAlign: true
            iconText: "\u{f034e}"
            text: modelData.name + (modelData.region ? "  ·  " + modelData.region : "")
            foreground: root.foreground
            selected: index === root.locationIndex
            tooltipText: modelData.latitude + ", " + modelData.longitude
            onClicked: root.pickLocation(modelData)
          }
        }
      }

      Button {
        visible: root.locationEditable && root.weatherLocation.name !== "" && root.weatherLocationSaving === null
        iconText: "\u{f01a4}"
        text: "Use automatic location"
        foreground: root.foreground
        bordered: true
        tooltipText: "Forget the saved place and let wttr.in guess from your IP"
        onClicked: root.pickLocation(null)
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: root.locationEditable
          ? "\u{f0026}  Shared with Omarchy's weather panel: changing it here changes it there too."
          : "Changing the place needs omarchy-weather-location (a newer Omarchy)."
        color: Util.alpha(root.foreground, 0.62)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Section { text: "TEMPERATURE" }

      Option {
        label: "Unit"
        hint: "Auto: °F in the US (and Liberia, Myanmar), else °C."
        ButtonGroup {
          foreground: root.foreground
          fontFamily: root.fontFamily
          options: [
            { value: "auto", label: "Auto" },
            { value: "metric", label: "°C" },
            { value: "imperial", label: "°F" }
          ]
          value: root.prefs.weatherUnit
          onChanged: function(v) { root.changed("weatherUnit", v) }
        }
      }
    }

    // --- Updates ----------------------------------------------------------------------

    Column {
      width: parent.width
      spacing: Style.space(10)
      visible: root.page === "updates"
      enabled: root.pageOn
      opacity: root.pageOn ? 1 : 0.45

      Intro { text: "Checking only reads and never asks for a password. The card's Update button opens a terminal, which asks there." }

      Section { text: "CHECK" }

      Grid {
        width: parent.width
        columns: 2
        columnSpacing: Style.space(16)
        rowSpacing: Style.space(8)

        ListCell { glyph: "\u{f06b0}"; label: "Omarchy"; listKey: "updateSources"; list: root.prefs.updateSourceList || []; allowed: Model.UPDATE_SOURCES; itemId: "omarchy"; active: root.prefs.moduleUpdates === true; visible: root.updateSourcesAvailable.indexOf("omarchy") !== -1 }
        ListCell { glyph: "\u{f08c7}"; label: "Official"; listKey: "updateSources"; list: root.prefs.updateSourceList || []; allowed: Model.UPDATE_SOURCES; itemId: "pacman"; active: root.prefs.moduleUpdates === true; visible: root.updateSourcesAvailable.indexOf("pacman") !== -1 }
        ListCell { glyph: "\u{f0487}"; label: "AUR"; listKey: "updateSources"; list: root.prefs.updateSourceList || []; allowed: Model.UPDATE_SOURCES; itemId: "aur"; active: root.prefs.moduleUpdates === true; visible: root.updateSourcesAvailable.indexOf("aur") !== -1 }
        ListCell { glyph: "\u{f01a7}"; label: "Flatpak"; listKey: "updateSources"; list: root.prefs.updateSourceList || []; allowed: Model.UPDATE_SOURCES; itemId: "flatpak"; active: root.prefs.moduleUpdates === true; visible: root.updateSourcesAvailable.indexOf("flatpak") !== -1 }
        ListCell { glyph: "\u{f0431}"; label: "Plugins"; listKey: "updateSources"; list: root.prefs.updateSourceList || []; allowed: Model.UPDATE_SOURCES; itemId: "plugins"; active: root.prefs.moduleUpdates === true; visible: root.updateSourcesAvailable.indexOf("plugins") !== -1 }
        ListCell { glyph: "\u{f03d8}"; label: "Themes"; listKey: "updateSources"; list: root.prefs.updateSourceList || []; allowed: Model.UPDATE_SOURCES; itemId: "themes"; active: root.prefs.moduleUpdates === true; visible: root.updateSourcesAvailable.indexOf("themes") !== -1 }
      }

      Option {
        label: "How often"
        ButtonGroup {
          foreground: root.foreground
          fontFamily: root.fontFamily
          options: Model.UPDATE_INTERVALS.map(function(m) { return { value: String(m), label: Model.intervalLabel(m).replace(" min", "m").replace(" h", "h").replace(" d", "d") } })
          value: String(root.prefs.updateInterval)
          onChanged: function(v) { root.changed("updateInterval", parseInt(v, 10)) }
        }
      }

      More {
        Option {
          label: "Custom interval (minutes)"
          hint: "From 5 minutes to 7 days. Now: " + Model.intervalLabel(root.prefs.updateInterval || 180) + "."
          NumberField {
            foreground: root.foreground
            fontFamily: root.fontFamily
            value: root.prefs.updateInterval || 180
            from: 5
            to: 10080
            stepSize: 15
            onModified: function(v) { root.changed("updateInterval", v) }
          }
        }

        SwitchOption {
          key: "updateOnStartup"
          label: "Also check at startup"
          hint: "About a minute after you log in."
        }
      }
    }

    // --- Appearance ------------------------------------------------------------------

    Column {
      width: parent.width
      spacing: Style.space(10)
      visible: root.page === "look"

      Option {
        label: "Maximum width (px)"
        hint: "The pill takes only the room each thing needs, up to this."
        NumberField {
          foreground: root.foreground
          fontFamily: root.fontFamily
          value: root.prefs.maxWidth
          from: 80
          to: 600
          stepSize: 20
          onModified: function(v) { root.changed("maxWidth", v) }
        }
      }

      Option {
        label: "Long text"
        hint: root.prefs.textMode === "once" ? "Goes by once when it changes, then rests faded."
          : (root.prefs.textMode === "scroll" ? "Keeps going round and round." : "Cut with …")
        ButtonGroup {
          foreground: root.foreground
          fontFamily: root.fontFamily
          options: [
            { value: "once", label: "Once" },
            { value: "scroll", label: "Loop" },
            { value: "ellipsis", label: "Cut" }
          ]
          value: root.prefs.textMode
          onChanged: function(v) { root.changed("textMode", v) }
        }
      }

      Option {
        label: "With nothing going on"
        hint: root.prefs.whenEmpty === "brief" ? "The pill shows the weather."
          : (root.prefs.whenEmpty === "icon" ? "Just an empty pill." : "No pill at all.")
        ButtonGroup {
          foreground: root.foreground
          fontFamily: root.fontFamily
          options: [
            { value: "brief", label: "Weather" },
            { value: "icon", label: "Empty" },
            { value: "hide", label: "Hide" }
          ]
          value: root.prefs.whenEmpty
          onChanged: function(v) { root.changed("whenEmpty", v) }
        }
      }

      SwitchOption {
        key: "coverAccent"
        label: "Colors from the cover and the sky"
        hint: "Off: the theme's colors."
      }

      SwitchOption {
        key: "animations"
        label: "Animations"
      }

      More {
        SwitchOption {
          key: "showProgress"
          label: "Progress line in the pill"
          hint: "Timers, scripts and the like. Music shows it on its card."
        }
        SwitchOption { key: "showCount"; label: "Position in the pill (2/4)" }
      }
    }

    // --- Popup shortcuts -------------------------------------------------------------

    Column {
      width: parent.width
      spacing: Style.space(10)
      visible: root.page === "shortcuts"

      Intro { text: "The two rows at the bottom of the popup." }

      SwitchOption {
        key: "showQuickToggles"
        label: "Quick toggles"
        hint: "Turn things on and off."
      }

      Grid {
        width: parent.width
        columns: 2
        columnSpacing: Style.space(16)
        rowSpacing: Style.space(8)
        visible: root.prefs.showQuickToggles === true

        ListCell { glyph: "\u{f009b}"; label: "DND"; itemId: "dnd"; listKey: "quickToggleItems"; list: root.prefs.quickToggles; allowed: Model.QUICK_TOGGLES }
        ListCell { glyph: "\u{f050e}"; label: "Night"; itemId: "nightlight"; listKey: "quickToggleItems"; list: root.prefs.quickToggles; allowed: Model.QUICK_TOGGLES }
        ListCell { glyph: "\u{f0176}"; label: "Stay awake"; itemId: "stayAwake"; listKey: "quickToggleItems"; list: root.prefs.quickToggles; allowed: Model.QUICK_TOGGLES }
        ListCell { glyph: "\u{f0ec2}"; label: "Record"; itemId: "record"; listKey: "quickToggleItems"; list: root.prefs.quickToggles; allowed: Model.QUICK_TOGGLES }
        ListCell { glyph: "\u{f088c}"; label: "Reminder"; itemId: "reminder"; listKey: "quickToggleItems"; list: root.prefs.quickToggles; allowed: Model.QUICK_TOGGLES }
        ListCell { glyph: "\u{f036c}"; label: "Dictation"; itemId: "dictation"; listKey: "quickToggleItems"; list: root.prefs.quickToggles; allowed: Model.QUICK_TOGGLES }
      }

      PanelSeparator { foreground: root.foreground }

      SwitchOption {
        key: "showQuickStart"
        label: "Quick start"
        hint: root.prefs.moduleTimer ? "Start timers, the stopwatch and more. Keys: 1–6, s, p."
          : "Needs Timers & Pomodoro turned on."
      }

      Column {
        width: parent.width
        spacing: Style.space(10)
        visible: root.prefs.showQuickStart === true

        Option {
          label: "Timer buttons (min)"
          hint: "Up to 6, with commas. Enter saves."
          TextField {
            id: presetsField
            width: Style.space(120)
            foreground: root.foreground
            text: root.prefs.timerPresets
            placeholderText: "1,5,10,25"
            onAccepted: { root.changed("timerPresets", text); focus = false }
            onEditingFinished: if (text !== root.prefs.timerPresets) root.changed("timerPresets", text)
          }
        }

        Grid {
          width: parent.width
          columns: 2
          columnSpacing: Style.space(16)
          rowSpacing: Style.space(8)

          ListCell { glyph: "\u{f520}"; label: "Stopwatch"; itemId: "stopwatch"; listKey: "quickStartItems"; list: root.prefs.quickStartExtras; allowed: Model.QUICK_START_EXTRAS }
          ListCell { glyph: "\u{f04fe}"; label: "Pomodoro"; itemId: "pomodoro"; listKey: "quickStartItems"; list: root.prefs.quickStartExtras; allowed: Model.QUICK_START_EXTRAS }
          ListCell { glyph: "\u{f04b2}"; label: "Sleep"; itemId: "sleep"; listKey: "quickStartItems"; list: root.prefs.quickStartExtras; allowed: Model.QUICK_START_EXTRAS }
        }

        Option {
          visible: root.prefs.quickStartExtras.indexOf("sleep") !== -1
          label: "Sleep timer (min)"
          hint: "Pauses the media after this long."
          NumberField {
            foreground: root.foreground
            fontFamily: root.fontFamily
            value: root.prefs.sleepMinutes
            from: 1
            to: 720
            stepSize: 5
            onModified: function(v) { root.changed("sleepMinutes", v) }
          }
        }
      }
    }

    // --- Omarchy integration ---------------------------------------------------------

    Column {
      width: parent.width
      spacing: Style.space(10)
      visible: root.page === "omarchy"

      Intro { text: "The Now Bar can do the job of two of Omarchy's own widgets. Optional, and easy to undo." }

      WidgetSwap {
        swapState: root.indicatorsState
        glyph: "\u{f009b}"
        replacedTitle: "Indicators: using the Now Bar"
        nativeTitle: "Indicators: using Omarchy's"
        replacedText: "Its widget is off; the Quick toggles and activities do its job. Restore puts it back where it was."
        nativeText: "The Now Bar already shows what the indicators show, and the Quick toggles turn those things on. Replace turns the widget off."
        replaceLabel: "Replace the indicators"
        restoreLabel: "Restore Omarchy's indicators"
        onRequested: function(replace) { root.indicatorsRequested(replace) }
      }

      WidgetSwap {
        swapState: root.weatherWidgetState
        glyph: "\u{f0599}"
        replacedTitle: "Weather: using the Now Bar"
        nativeTitle: "Weather: using Omarchy's"
        replacedText: "Its widget is off and SUPER+CTRL+ALT+W opens the weather card. Restore gives both back."
        nativeText: "Replace turns its widget off and points SUPER+CTRL+ALT+W at the weather card."
        warning: "Edits ~/.config/hypr/bindings.lua (a marked block; a backup is kept next to it)."
        replaceLabel: "Replace the weather widget"
        restoreLabel: "Restore Omarchy's widget"
        onRequested: function(replace) { root.weatherWidgetRequested(replace) }
      }
    }
  }
}
