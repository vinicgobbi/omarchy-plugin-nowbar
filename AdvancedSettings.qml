import QtQuick
import qs.Ui
import qs.Commons
import "NowbarModel.js" as Model

// Options view shown inside the popup (gear button or "c"). It only reads the
// preferences it is given and reports changes upward; BarWidget.qml stores
// them on the widget's shell.json entry. Built from the shell's own controls
// so it looks like the other Omarchy panels.
//
// One tab at a time, so it stays short:
//   Activities  what can show up, and whether new ones take the pill
//   Look        what the pill shows and the dynamic colors
//   Quick       the popup's Quick toggles and Quick start (and Omarchy's
//               indicators widget, which the Quick toggles replace)
//   Weather     temperature unit and taking over Omarchy's weather widget
//   Updates     which package sources are checked, and how often
Column {
  id: root

  property var prefs: ({})
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  // "activities" | "look" | "quick" | "weather" | "updates"
  property string tab: "activities"
  readonly property var tabs: [
    { value: "activities", label: "Activities" },
    { value: "look", label: "Look" },
    { value: "quick", label: "Quick" },
    { value: "weather", label: "Weather" },
    { value: "updates", label: "Updates" }
  ]

  // Tab / Shift+Tab in the popup.
  function cycleTab(direction) {
    var i = 0
    for (var k = 0; k < tabs.length; k++) if (tabs[k].value === tab) i = k
    tab = tabs[((i + direction) % tabs.length + tabs.length) % tabs.length].value
  }

  // True while typing in a text field: the popup's key shortcuts step aside.
  readonly property bool editing: presetsField.activeFocus

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
        color: Qt.darker(root.foreground, 1.5)
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

  // Half-width "glyph Name [switch]" cell bound to one boolean preference.
  component Cell: Item {
    id: cell
    property string label: ""
    property string glyph: ""
    property string key: ""

    width: parent ? (parent.width - parent.columnSpacing) / 2 : 0
    height: Math.max(cellLabel.implicitHeight, cellSwitch.implicitHeight)

    Text {
      id: cellGlyph
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(20)
      textFormat: Text.PlainText
      text: cell.glyph
      color: root.prefs[cell.key] === true ? root.foreground : Qt.darker(root.foreground, 1.8)
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
      color: root.prefs[cell.key] === true ? root.foreground : Qt.darker(root.foreground, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      elide: Text.ElideRight
    }

    ToggleSwitch {
      id: cellSwitch
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      foreground: root.foreground
      checked: root.prefs[cell.key] === true
      onToggled: root.changed(cell.key, !checked)
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
      color: lc.on ? root.foreground : Qt.darker(root.foreground, 1.8)
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
      color: lc.on ? root.foreground : Qt.darker(root.foreground, 1.5)
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

  // One line under the tabs saying what the tab is about.
  component Intro: Text {
    width: parent ? parent.width : 0
    textFormat: Text.PlainText
    wrapMode: Text.WordWrap
    color: Qt.darker(root.foreground, 1.4)
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
        color: Qt.darker(root.foreground, 1.3)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        width: parent.width
        visible: swap.warning !== ""
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        text: "\u{f0026}  " + swap.warning
        color: Qt.darker(root.foreground, 1.5)
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

  // --- header + tabs (always shown) ---------------------------------------------

  Item {
    width: parent.width
    height: backButton.implicitHeight

    Button {
      id: backButton
      iconText: "\u{f004d}"
      foreground: root.foreground
      tooltipText: "Back (q)"
      onClicked: root.backRequested()
    }

    Text {
      textFormat: Text.PlainText
      anchors.left: backButton.right
      anchors.leftMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: "Now Bar options"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
    }

    Button {
      anchors.right: parent.right
      text: "Reset"
      foreground: Qt.darker(root.foreground, 1.4)
      tooltipText: "Restore the default options (all tabs)"
      onClicked: root.resetRequested()
    }
  }

  ButtonGroup {
    width: parent.width
    foreground: root.foreground
    fontFamily: root.fontFamily
    options: root.tabs
    value: root.tab
    onChanged: function(v) { root.tab = v }
  }

  // --- Activities ----------------------------------------------------------------

  Column {
    width: parent.width
    spacing: Style.space(10)
    visible: root.tab === "activities"

    Intro { text: "What can show up in the Now Bar. Turned off, it never appears and isn't checked." }

    Section { text: "LIVE" }

    Grid {
      width: parent.width
      columns: 2
      columnSpacing: Style.space(16)
      rowSpacing: Style.space(8)

      Cell { glyph: "\u{f075a}"; label: "Media"; key: "moduleMedia" }
      Cell { glyph: "\u{f13ab}"; label: "Timers"; key: "moduleTimer" }
      Cell { glyph: "\u{f088c}"; label: "Reminders"; key: "moduleReminders" }
      Cell { glyph: "\u{f044a}"; label: "Recording"; key: "moduleRecording" }
      Cell { glyph: "\u{f036c}"; label: "Dictation"; key: "moduleDictation" }
      Cell { glyph: "\u{f0100}"; label: "Camera/mic"; key: "modulePrivacy" }
    }

    Section { text: "SYSTEM" }

    Grid {
      width: parent.width
      columns: 2
      columnSpacing: Style.space(16)
      rowSpacing: Style.space(8)

      Cell { glyph: "\u{f009b}"; label: "Modes/VPN"; key: "moduleModes" }
      Cell { glyph: "\u{f0084}"; label: "Battery"; key: "moduleCharging" }
      Cell { glyph: "\u{f00b1}"; label: "Bluetooth"; key: "moduleBluetooth" }
      Cell { glyph: "\u{f0e51}"; label: "Screenshot"; key: "moduleScreenshot" }
      Cell { glyph: "\u{f0599}"; label: "Weather"; key: "moduleWeather" }
      Cell { glyph: "\u{f0996}"; label: "Scripts"; key: "modulePush" }
      Cell { glyph: "\u{f06b0}"; label: "Updates"; key: "moduleUpdates" }
    }

    PanelSeparator { foreground: root.foreground }

    SwitchOption {
      key: "autoFocus"
      label: "Focus new activities"
      hint: "Something that just started takes the pill, unless you switched by hand a moment ago."
    }

    Section { text: "MEDIA" }

    Option {
      label: "Paused player"
      hint: "Gives the pill to what else is going on after this long; it stays in the carousel."
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

    Intro {
      text: root.playerList.length > 0
        ? "Players shown in the Now Bar. A hidden one still answers the media keys."
        : "Players show up here while they are open, to hide the ones you don't want in the Now Bar."
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
            color: pc.shown ? root.foreground : Qt.darker(root.foreground, 1.8)
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
            color: pc.shown ? root.foreground : Qt.darker(root.foreground, 1.5)
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

  // --- Look ------------------------------------------------------------------------

  Column {
    width: parent.width
    spacing: Style.space(10)
    visible: root.tab === "look"

    Intro { text: "How the pill looks in the bar. It always keeps the same size." }

    Section { text: "PILL" }

    Option {
      label: "Text width (px)"
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
      hint: "Scroll it around, or cut it with …"
      ButtonGroup {
        foreground: root.foreground
        fontFamily: root.fontFamily
        options: [
          { value: "scroll", label: "Scroll" },
          { value: "ellipsis", label: "Cut" }
        ]
        value: root.prefs.textMode
        onChanged: function(v) { root.changed("textMode", v) }
      }
    }

    SwitchOption { key: "showProgress"; label: "Progress line" }
    SwitchOption { key: "showCount"; label: "Position (2/4)" }

    Option {
      label: "When idle"
      hint: "When nothing is going on. Brief: the weather card. Empty: just the pill. Hide: no pill."
      ButtonGroup {
        foreground: root.foreground
        fontFamily: root.fontFamily
        options: [
          { value: "brief", label: "Brief" },
          { value: "icon", label: "Empty" },
          { value: "hide", label: "Hide" }
        ]
        value: root.prefs.whenEmpty
        onChanged: function(v) { root.changed("whenEmpty", v) }
      }
    }

    Section { text: "COLORS" }

    SwitchOption {
      key: "coverAccent"
      label: "Dynamic colors"
      hint: "Media takes its colors from the album cover, weather from the sky: highlight, popup border and background."
    }

    Section { text: "MOTION" }

    SwitchOption {
      key: "animations"
      label: "Animations"
      hint: "The popup unfolds from the pill, cards slide in, and the pill pulses when something urgent comes up. Off: everything changes at once."
    }
  }

  // --- Quick -------------------------------------------------------------------------

  Column {
    width: parent.width
    spacing: Style.space(10)
    visible: root.tab === "quick"

    Intro { text: "The two rows at the bottom of the popup. Keys there: 1\u20136 start a timer, s the stopwatch, p a Pomodoro." }

    Section { text: "QUICK TOGGLES" }

    SwitchOption {
      key: "showQuickToggles"
      label: "Show Quick toggles"
      hint: "Turn things on and off, like Omarchy's indicators."
    }

    Grid {
      width: parent.width
      columns: 2
      columnSpacing: Style.space(16)
      rowSpacing: Style.space(8)

      ListCell { glyph: "\u{f009b}"; label: "DND"; itemId: "dnd"; listKey: "quickToggleItems"; list: root.prefs.quickToggles; allowed: Model.QUICK_TOGGLES; active: root.prefs.showQuickToggles }
      ListCell { glyph: "\u{f050e}"; label: "Night"; itemId: "nightlight"; listKey: "quickToggleItems"; list: root.prefs.quickToggles; allowed: Model.QUICK_TOGGLES; active: root.prefs.showQuickToggles }
      ListCell { glyph: "\u{f0176}"; label: "Stay awake"; itemId: "stayAwake"; listKey: "quickToggleItems"; list: root.prefs.quickToggles; allowed: Model.QUICK_TOGGLES; active: root.prefs.showQuickToggles }
      ListCell { glyph: "\u{f0ec2}"; label: "Record"; itemId: "record"; listKey: "quickToggleItems"; list: root.prefs.quickToggles; allowed: Model.QUICK_TOGGLES; active: root.prefs.showQuickToggles }
      ListCell { glyph: "\u{f088c}"; label: "Reminder"; itemId: "reminder"; listKey: "quickToggleItems"; list: root.prefs.quickToggles; allowed: Model.QUICK_TOGGLES; active: root.prefs.showQuickToggles }
      ListCell { glyph: "\u{f036c}"; label: "Dictation"; itemId: "dictation"; listKey: "quickToggleItems"; list: root.prefs.quickToggles; allowed: Model.QUICK_TOGGLES; active: root.prefs.showQuickToggles }
    }

    WidgetSwap {
      swapState: root.indicatorsState
      glyph: "\u{f009b}"
      replacedTitle: "Indicators replaced by the Now Bar"
      nativeTitle: "Omarchy's indicators are in use"
      replacedText: "The indicators widget is off. Its toggles are these Quick toggles, and what's on shows up as activities. Restore puts the widget back where it was."
      nativeText: "The Now Bar shows everything the indicators show (recording, dictation, reminders, Do Not Disturb, night light, stay awake) and these Quick toggles turn them on. Replace turns the indicators widget off."
      replaceLabel: "Replace the indicators"
      restoreLabel: "Restore Omarchy's indicators"
      onRequested: function(replace) { root.indicatorsRequested(replace) }
    }

    PanelSeparator { foreground: root.foreground }

    Section { text: "QUICK START" }

    SwitchOption {
      key: "showQuickStart"
      label: "Show Quick start"
      hint: root.prefs.moduleTimer ? "Timers, stopwatch, Pomodoro and the media sleep timer."
        : "Needs the Timers activity (Activities tab)."
    }

    Option {
      label: "Timers"
      hint: "Minutes, separated by commas (up to 6). Enter to save. Empty: none."
      opacity: root.prefs.showQuickStart ? 1 : 0.45
      TextField {
        id: presetsField
        width: Style.space(120)
        foreground: root.foreground
        enabled: root.prefs.showQuickStart
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

      ListCell { glyph: "\u{f520}"; label: "Stopwatch"; itemId: "stopwatch"; listKey: "quickStartItems"; list: root.prefs.quickStartExtras; allowed: Model.QUICK_START_EXTRAS; active: root.prefs.showQuickStart }
      ListCell { glyph: "\u{f04fe}"; label: "Pomodoro"; itemId: "pomodoro"; listKey: "quickStartItems"; list: root.prefs.quickStartExtras; allowed: Model.QUICK_START_EXTRAS; active: root.prefs.showQuickStart }
      ListCell { glyph: "\u{f04b2}"; label: "Sleep"; itemId: "sleep"; listKey: "quickStartItems"; list: root.prefs.quickStartExtras; allowed: Model.QUICK_START_EXTRAS; active: root.prefs.showQuickStart }
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
      hint: "Turned on for each focus block and off for the breaks (left alone if you had it on already)."
    }
  }

  // --- Weather ---------------------------------------------------------------------

  Column {
    width: parent.width
    spacing: Style.space(10)
    visible: root.tab === "weather"

    Intro { text: "The weather card: wttr.in, for the location saved in Omarchy (or a guess from your IP)." }

    Option {
      label: "Temperature"
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

    Section { text: "OMARCHY'S WEATHER WIDGET" }

    WidgetSwap {
      swapState: root.weatherWidgetState
      glyph: "\u{f0599}"
      replacedTitle: "Replaced by the Now Bar"
      nativeTitle: "Omarchy's widget is in use"
      replacedText: "The weather widget is off and SUPER+CTRL+ALT+W opens the weather card. Restore turns the widget back on and gives the shortcut back."
      nativeText: "Replace turns Omarchy's weather widget off and points SUPER+CTRL+ALT+W at the weather card."
      warning: "Edits ~/.config/hypr/bindings.lua (a marked block; a backup is kept next to it)."
      replaceLabel: "Replace the weather widget"
      restoreLabel: "Restore Omarchy's widget"
      onRequested: function(replace) { root.weatherWidgetRequested(replace) }
    }
  }

  // --- Updates ----------------------------------------------------------------------

  Column {
    width: parent.width
    spacing: Style.space(10)
    visible: root.tab === "updates"

    Intro {
      text: "Updates waiting show up as a card, which takes the pill when something new is found (like any new activity). Checking only reads: no password asked. The card's Update button opens a terminal with Omarchy's updater (plus flatpak, plugins and themes when they have updates), which asks for your password there."
    }

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

    Section { text: "HOW OFTEN" }

    Option {
      label: "Every"
      ButtonGroup {
        foreground: root.foreground
        fontFamily: root.fontFamily
        options: Model.UPDATE_INTERVALS.map(function(m) { return { value: String(m), label: Model.intervalLabel(m).replace(" min", "m").replace(" h", "h").replace(" d", "d") } })
        value: String(root.prefs.updateInterval)
        onChanged: function(v) { root.changed("updateInterval", parseInt(v, 10)) }
      }
    }

    Option {
      label: "Custom (minutes)"
      hint: "Any interval, from 5 minutes to 7 days. Now: " + Model.intervalLabel(root.prefs.updateInterval || 180) + "."
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
      label: "Check at startup"
      hint: "Once each time the computer starts (about a minute after you log in), besides the interval."
    }
  }
}
