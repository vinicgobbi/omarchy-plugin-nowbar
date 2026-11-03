import QtQuick
import "NowbarModel.js" as Model

// Soft translucent hills over the played part of the media card's seek bar:
// they flow toward the handle while the music plays and sink into the bar when
// it pauses. The shapes come from NowbarModel.js (hillHeight and friends); this
// only keeps them moving and draws them. Stands on its own bottom edge, from x 0
// to `end`.
Canvas {
  id: root

  // 0..1 along the track: how tall they are early on.
  property real value: 0
  // Where the handle is, in px.
  property real end: 0
  // Height of the tallest hill at scale 1.
  property real peak: 18
  // Fits the layers' hump widths to the shell's scale.
  property real unit: 1
  property color color: "white"
  // Music playing: they rise; else they sink.
  property bool waving: false
  // Off: they just stand still (the "Animations" option).
  property bool animate: true
  // Only worth drawing while it is on screen.
  property bool active: true

  property real amp: 0
  property real time: 0
  property double lastFrame: 0

  readonly property bool moving: animate && active && visible && (waving || amp > 0)

  Component.onCompleted: amp = waving ? 1 : 0
  onWavingChanged: {
    if (!animate) { amp = waving ? 1 : 0; requestPaint() }
  }
  onAnimateChanged: {
    if (!animate) { amp = waving ? 1 : 0; requestPaint() }
  }
  onMovingChanged: lastFrame = Date.now()
  onEndChanged: requestPaint()
  onColorChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()
  onActiveChanged: if (active) requestPaint()

  // 30 frames a second is plenty for something this soft, and it only runs
  // with the popup open on a card that plays.
  Timer {
    interval: 33
    repeat: true
    running: root.moving
    onTriggered: {
      var t = Date.now()
      var dt = Math.min(0.1, Math.max(0, t - root.lastFrame) / 1000)
      root.lastFrame = t
      root.time += dt * root.amp
      var target = root.waving ? 1 : 0
      var next = root.amp + (target - root.amp) * (1 - Math.exp(-dt * 5))
      root.amp = Math.abs(target - next) < 0.01 ? target : next
      root.requestPaint()
    }
  }

  function channel(v, white) {
    return Math.round((v + (1 - v) * white) * 255)
  }

  onPaint: {
    var ctx = getContext("2d")
    ctx.reset()
    var span = end
    if (amp <= 0 || span <= 2) return
    var base = height
    var top = Math.max(0, base - peak * Model.HILLS_START)
    var scale = peak * Model.hillsScale(value, span / unit) * amp
    var step = Math.max(2, 2 * unit)
    for (var i = 0; i < Model.HILLS.length; i++) {
      var layer = Model.HILLS[i]
      var humps = Model.hillHumps(layer, span / unit)
      ctx.beginPath()
      ctx.moveTo(0, base)
      for (var x = 0; x <= span; x += step) {
        ctx.lineTo(x, base - scale * Model.hillHeight(layer, i, x / span, humps, time))
      }
      ctx.lineTo(span, base)
      ctx.closePath()
      var rgb = channel(color.r, layer.white) + "," + channel(color.g, layer.white) + "," + channel(color.b, layer.white)
      var fill = ctx.createLinearGradient(0, top, 0, base)
      fill.addColorStop(0, "rgba(" + rgb + "," + layer.alpha + ")")
      fill.addColorStop(1, "rgba(" + rgb + "," + (layer.alpha * 0.45) + ")")
      ctx.fillStyle = fill
      ctx.fill()
    }
  }
}
