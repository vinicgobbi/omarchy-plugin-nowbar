import QtQuick
import qs.Ui
import qs.Commons

// The weather card in the popup: the Now Brief, laid out for a glance.
//   ☀  23°C   Sunny                    ⌖ City
//             Feels 25°                 H 32° · L 17°
//   [wind]  [humidity]  [rain]  [sunset]
//   Now  15h  18h  21h ...   (icon, temperature, rain chance)
//   Today      ☀   17° ▕━━━━━━━▏ 32°
//   Tomorrow   🌧   19°   ▕━━━━━━━▏ 33°
//   Updated 9:02                                   ⟳
// Everything comes from NowbarModel.parseWttr(); this only draws it.
Column {
  id: root

  property var weather: null
  property var extraLines: []
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  // "Updated 9:02" / "Offline · updated 3 h ago" (Model.weatherAge), and
  // whether a fetch is on its way.
  property string ageText: ""
  property bool stale: false
  property bool loading: false

  signal refreshRequested()
  // The place name was clicked: the options' Location.
  signal placeClicked()

  readonly property var w: weather || ({ hours: [], days: [] })
  readonly property color dim: Util.alpha(foreground, 0.7)

  spacing: Style.space(12)

  // --- hero ------------------------------------------------------------------

  Item {
    width: parent.width
    height: Math.max(heroLeft.implicitHeight, heroRight.implicitHeight)

    Row {
      id: heroLeft
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(12)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.w.icon || ""
        color: root.accent
        font.family: root.fontFamily
        font.pixelSize: Style.font.displayLarge * 1.5
      }

      Column {
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(1)

        Row {
          spacing: Style.space(2)

          Text {
            textFormat: Text.PlainText
            text: root.w.temp !== undefined ? root.w.temp + "°" : "—"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.displayLarge * 1.3
            font.bold: true
          }

          Text {
            anchors.top: parent.top
            anchors.topMargin: Style.space(4)
            textFormat: Text.PlainText
            text: root.w.unit ? root.w.unit.slice(1) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
        }

        Text {
          textFormat: Text.PlainText
          text: root.w.desc || ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }
      }
    }

    Column {
      id: heroRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Math.max(0, parent.width - heroLeft.width - Style.space(12))
      spacing: Style.space(3)

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignRight
        textFormat: Text.PlainText
        text: root.w.location ? "\u{f034e} " + root.w.location : ""
        visible: text !== ""
        color: placeArea.containsMouse ? root.accent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
        font.underline: placeArea.containsMouse
        elide: Text.ElideLeft

        MouseArea {
          id: placeArea
          // Only over the words, not the whole right-aligned line.
          anchors.right: parent.right
          width: Math.min(parent.width, parent.contentWidth)
          height: parent.height
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.placeClicked()
        }
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignRight
        textFormat: Text.PlainText
        text: root.w.days && root.w.days.length ? "H " + root.w.days[0].max + "°  ·  L " + root.w.days[0].min + "°" : ""
        visible: text !== ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Text {
        width: parent.width
        horizontalAlignment: Text.AlignRight
        textFormat: Text.PlainText
        text: root.w.feels !== undefined ? "Feels like " + root.w.feels + "°" : ""
        visible: text !== ""
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // --- stats -------------------------------------------------------------------

  Row {
    id: stats
    width: parent.width
    spacing: Style.space(6)

    readonly property var items: [
      { icon: "\u{f059d}", value: root.w.wind || "—", label: "Wind" },
      { icon: "\u{f058e}", value: root.w.humidity !== undefined ? root.w.humidity + "%" : "—", label: "Humidity" },
      { icon: "\u{f0597}", value: root.w.days && root.w.days.length ? root.w.days[0].rain + "%" : "—", label: "Rain today" },
      root.w.night
        ? { icon: "\u{f059c}", value: root.w.sunrise || "—", label: "Sunrise" }
        : { icon: "\u{f059b}", value: root.w.sunset || "—", label: "Sunset" }
    ]

    Repeater {
      model: stats.items

      Rectangle {
        required property var modelData
        width: (stats.width - stats.spacing * 3) / 4
        height: statCol.implicitHeight + Style.space(12)
        radius: Style.spacing.labelGap
        color: Util.alpha(root.foreground, 0.07)

        Column {
          id: statCol
          anchors.centerIn: parent
          width: parent.width - Style.space(8)
          spacing: Style.space(2)

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: modelData.icon
            color: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: modelData.value
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            text: modelData.label
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // --- next hours ----------------------------------------------------------------

  Row {
    id: hoursRow
    width: parent.width
    visible: root.w.hours && root.w.hours.length > 0

    Repeater {
      model: root.w.hours || []

      Column {
        required property var modelData
        required property int index
        width: hoursRow.width / Math.max(1, root.w.hours.length)
        spacing: Style.space(3)

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: modelData.label
          color: index === 0 ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: index === 0
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: modelData.icon
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
        }

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: modelData.temp + "°"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        // Rain chance only when it's worth a look.
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: modelData.rain >= 20 ? modelData.rain + "%" : " "
          color: "#5aa9ff"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }

  // --- next days, with a temperature range bar --------------------------------------

  Column {
    id: daysCol
    width: parent.width
    spacing: Style.space(6)
    visible: root.w.days && root.w.days.length > 0

    readonly property real lowest: {
      var d = root.w.days || []
      var v = Infinity
      for (var i = 0; i < d.length; i++) v = Math.min(v, d[i].min)
      return isFinite(v) ? v : 0
    }
    readonly property real highest: {
      var d = root.w.days || []
      var v = -Infinity
      for (var i = 0; i < d.length; i++) v = Math.max(v, d[i].max)
      return isFinite(v) ? v : 1
    }
    readonly property real span: Math.max(1, highest - lowest)

    Repeater {
      model: root.w.days || []

      Row {
        required property var modelData
        width: daysCol.width
        spacing: Style.space(8)

        Text {
          id: dayName
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(76)
          textFormat: Text.PlainText
          text: modelData.name
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          id: dayIcon
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(22)
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: modelData.icon
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
        }

        Text {
          id: dayRain
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(34)
          horizontalAlignment: Text.AlignRight
          textFormat: Text.PlainText
          text: modelData.rain >= 20 ? modelData.rain + "%" : ""
          color: "#5aa9ff"
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          id: dayMin
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(30)
          horizontalAlignment: Text.AlignRight
          textFormat: Text.PlainText
          text: modelData.min + "°"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // The day's range placed on the scale of the whole forecast.
        Item {
          id: rangeTrack
          anchors.verticalCenter: parent.verticalCenter
          width: Math.max(Style.space(30), parent.width - dayName.width - dayIcon.width - dayRain.width - dayMin.width - dayMax.width - parent.spacing * 5)
          height: Style.space(6)

          Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: Util.alpha(root.foreground, 0.1)
          }

          Rectangle {
            x: parent.width * (modelData.min - daysCol.lowest) / daysCol.span
            width: Math.max(height, parent.width * (modelData.max - modelData.min) / daysCol.span)
            height: parent.height
            radius: height / 2
            gradient: Gradient {
              orientation: Gradient.Horizontal
              GradientStop { position: 0.0; color: Qt.lighter(root.accent, 1.25) }
              GradientStop { position: 1.0; color: root.accent }
            }
          }
        }

        Text {
          id: dayMax
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(30)
          textFormat: Text.PlainText
          text: modelData.max + "°"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
      }
    }
  }

  Repeater {
    model: root.extraLines

    Text {
      required property var modelData
      width: root.width
      textFormat: Text.PlainText
      text: modelData
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }
  }

  // --- how fresh it is ----------------------------------------------------------

  Item {
    width: root.width
    height: Math.max(ageLine.implicitHeight, refreshButton.implicitHeight)
    visible: root.ageText !== ""

    Text {
      id: ageLine
      anchors.left: parent.left
      anchors.right: refreshButton.left
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: (root.stale ? "\u{f0026}  " : "") + (root.loading ? "Updating\u2026" : root.ageText)
      color: root.stale && !root.loading ? Color.urgent : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Button {
      id: refreshButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      iconText: "\u{f0450}"
      iconSpinning: root.loading
      text: root.stale ? "Refresh" : ""
      foreground: root.dim
      enabled: !root.loading
      tooltipText: "Fetch the weather now"
      onClicked: root.refreshRequested()
    }
  }
}
