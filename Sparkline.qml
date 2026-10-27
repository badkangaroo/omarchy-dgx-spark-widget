import QtQuick
import qs.Commons

// Compact percentage sparkline for the DGX Spark status panel.
Item {
  id: root

  property var values: []
  property real current: values.length ? Number(values[values.length - 1]) : 0
  property string label: ""
  property string valueText: ""
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property real chartHeight: Style.space(28)

  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color fill: Style.selectedFillFor(foreground, accent)

  width: parent ? parent.width : Style.space(240)
  height: labelRow.height + Style.space(6) + chartHeight

  Row {
    id: labelRow
    width: parent.width
    spacing: Style.space(8)

    Text {
      text: root.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.letterSpacing: 1
      textFormat: Text.PlainText
    }

    Item { width: parent.width - label.width - valueLabel.width - parent.spacing * 2; height: 1 }

    Text {
      id: valueLabel
      text: root.valueText !== "" ? root.valueText : (Number.isFinite(root.current) ? Math.round(root.current) + "%" : "—")
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      textFormat: Text.PlainText
    }
  }

  Canvas {
    id: chart
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    height: root.chartHeight
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var w = width
      var h = height
      ctx.clearRect(0, 0, w, h)

      // Track
      ctx.globalAlpha = 0.18
      ctx.fillStyle = root.foreground
      ctx.beginPath()
      var radius = Math.min(4, h / 2)
      ctx.moveTo(radius, 0)
      ctx.arcTo(w, 0, w, h, radius)
      ctx.arcTo(w, h, 0, h, radius)
      ctx.arcTo(0, h, 0, 0, radius)
      ctx.arcTo(0, 0, w, 0, radius)
      ctx.closePath()
      ctx.fill()
      ctx.globalAlpha = 1.0

      var vals = root.values || []
      if (vals.length < 1) return

      var maxPoints = Math.max(vals.length, 2)
      var step = w / Math.max(maxPoints - 1, 1)

      function yAt(v) {
        var n = Math.max(0, Math.min(100, Number(v) || 0))
        return h - (n / 100) * (h - 2) - 1
      }

      // Fill under line
      ctx.beginPath()
      ctx.moveTo(0, h)
      for (var i = 0; i < vals.length; i++) {
        var x = i * step
        if (i === 0) ctx.lineTo(x, yAt(vals[i]))
        else ctx.lineTo(x, yAt(vals[i]))
      }
      ctx.lineTo((vals.length - 1) * step, h)
      ctx.closePath()
      ctx.fillStyle = root.fill
      ctx.globalAlpha = 0.55
      ctx.fill()
      ctx.globalAlpha = 1.0

      // Line
      ctx.beginPath()
      for (var j = 0; j < vals.length; j++) {
        var xx = j * step
        var yy = yAt(vals[j])
        if (j === 0) ctx.moveTo(xx, yy)
        else ctx.lineTo(xx, yy)
      }
      ctx.strokeStyle = root.foreground
      ctx.lineWidth = 1.5
      ctx.stroke()
    }
  }

  onValuesChanged: chart.requestPaint()
  onForegroundChanged: chart.requestPaint()
  onWidthChanged: chart.requestPaint()
  onHeightChanged: chart.requestPaint()
}
