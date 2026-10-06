import QtQuick
import qs.Ui
import qs.Commons

// Options view shown inside the popup (gear button or "c"). It only reads the
// preferences it is given and reports changes upward; BarWidget.qml stores
// them on the widget's shell.json entry. Built from the shell's own controls
// so it looks like the other Omarchy panels.
Column {
  id: root

  property var prefs: ({})
  property color foreground: Color.foreground
  property string fontFamily: Style.font.family

  // True while typing in a text field: the popup's key shortcuts step aside.
  readonly property bool editing: presetsField.activeFocus

  signal changed(string name, var value)
  signal resetRequested()
  signal backRequested()

  spacing: Style.space(8)

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

  // Half-width "Name [switch]" cell bound to one boolean preference.
  component Cell: Item {
    id: cell
    property string label: ""
    property string key: ""

    width: parent ? (parent.width - parent.columnSpacing) / 2 : 0
    height: Math.max(cellLabel.implicitHeight, cellSwitch.implicitHeight)

    Text {
      id: cellLabel
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.right: cellSwitch.left
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      text: cell.label
      color: root.foreground
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

  // --- header ---------------------------------------------------------------

  Item {
    width: parent.width
    height: backButton.implicitHeight

    Button {
      id: backButton
      iconText: "\u{f004d}"
      foreground: root.foreground
      tooltipText: "Back"
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
      tooltipText: "Restore the default options"
      onClicked: root.resetRequested()
    }
  }

  PanelSectionHeader {
    text: "ACTIVITIES"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Grid {
    width: parent.width
    columns: 2
    columnSpacing: Style.space(16)
    rowSpacing: Style.space(8)

    Cell { label: "Media"; key: "moduleMedia" }
    Cell { label: "Timer"; key: "moduleTimer" }
    Cell { label: "Reminders"; key: "moduleReminders" }
    Cell { label: "Recording"; key: "moduleRecording" }
    Cell { label: "Dictation"; key: "moduleDictation" }
    Cell { label: "Camera/mic"; key: "modulePrivacy" }
    Cell { label: "Modes"; key: "moduleModes" }
    Cell { label: "Charging"; key: "moduleCharging" }
    Cell { label: "Scripts"; key: "modulePush" }
    Cell { label: "Bluetooth"; key: "moduleBluetooth" }
    Cell { label: "Screenshots"; key: "moduleScreenshot" }
  }

  PanelSeparator { foreground: root.foreground }

  PanelSectionHeader {
    text: "PILL"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Option {
    label: "Focus new activities"
    hint: "Something that just started takes the pill, unless you switched by hand a moment ago."
    ToggleSwitch {
      foreground: root.foreground
      checked: root.prefs.autoFocus === true
      onToggled: root.changed("autoFocus", !checked)
    }
  }

  Option {
    label: "Cover colors"
    hint: "Media takes its highlight color from the album cover."
    ToggleSwitch {
      foreground: root.foreground
      checked: root.prefs.coverAccent === true
      onToggled: root.changed("coverAccent", !checked)
    }
  }

  Option {
    label: "Progress line"
    ToggleSwitch {
      foreground: root.foreground
      checked: root.prefs.showProgress === true
      onToggled: root.changed("showProgress", !checked)
    }
  }

  Option {
    label: "Position (2/4)"
    ToggleSwitch {
      foreground: root.foreground
      checked: root.prefs.showCount === true
      onToggled: root.changed("showCount", !checked)
    }
  }

  Option {
    label: "When nothing is going on"
    hint: "Brief: weather, next reminder and updates. Empty: just the pill. Hide: no pill."
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

  Option {
    label: "Long text"
    hint: "Text that doesn't fit: scroll it around, or cut it with …"
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

  Option {
    label: "Text width (px)"
    hint: "The pill always keeps this size."
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

  PanelSeparator { foreground: root.foreground }

  PanelSectionHeader {
    text: "TIMERS"
    foreground: root.foreground
    fontFamily: root.fontFamily
  }

  Option {
    label: "Quick start timers"
    hint: "Minutes, separated by commas (up to 6). Enter to save."
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

  Option {
    label: "Pomodoro focus (min)"
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
    label: "Pomodoro break (min)"
    hint: "Every 4th break is the long one."
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
    label: "Pomodoro long break (min)"
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
}
