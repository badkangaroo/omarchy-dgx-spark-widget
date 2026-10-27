// DGX Spark Status Widget — bar chip + click-to-open panel.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "alexokita.dgx-spark-widget"

  readonly property string collector: Qt.resolvedUrl("bin/dgx-spark-status").toString().replace("file://", "")
  readonly property int refreshIntervalSec: Math.max(2, Number(setting("refreshIntervalSec", 5)) || 5)

  property bool ok: false
  property bool sshOk: false
  property bool busy: false
  property string summary: "Spark…"
  property string detail: ""

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }
  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }
  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  function refreshChip() {
    if (!chipProc.running) chipProc.running = true
  }

  function applyChip(text) {
    try {
      var s = JSON.parse(text || "{}")
      root.ok = s.ok === true
      var auth = s.auth || {}
      root.sshOk = auth.ok === true
      var conn = s.connection || {}
      var model = ""
      var tok = -1
      var isBusy = false
      var services = s.services || []
      for (var i = 0; i < services.length; i++) {
        var svc = services[i]
        if (svc.id === "tensorfold") {
          if (svc.models && svc.models.length) model = String(svc.models[0])
          if (svc.liveTokPerSec !== undefined) tok = Number(svc.liveTokPerSec)
          else if (svc.decodeTokPerSec !== undefined) tok = Number(svc.decodeTokPerSec)
          if (svc.health) isBusy = svc.health.busy === true
        }
      }
      root.busy = isBusy

      var device = s.device || {}
      var bits = ["Spark"]
      if (!root.ok) {
        root.summary = "Spark ✕"
        root.detail = (conn.error || "unreachable")
        return
      }
      if (!root.sshOk) {
        bits.push("sign in")
        if (model) bits.push(shortModel(model))
        root.summary = bits.join(" ")
        root.detail = "Click to enter SSH credentials"
        return
      }
      if (device.gpuPct !== undefined) bits.push("G" + Math.round(device.gpuPct))
      if (device.cpuPct !== undefined) bits.push("C" + Math.round(device.cpuPct))
      if (device.memPct !== undefined) bits.push("M" + Math.round(device.memPct))
      if (model) bits.push(shortModel(model))
      if (tok >= 0) bits.push(tok.toFixed(tok >= 10 ? 0 : 1) + "t/s")
      root.summary = bits.join(" ")
      root.detail = (conn.host || "") + (conn.transport ? " via " + conn.transport : "")
    } catch (e) {
      root.ok = false
      root.summary = "Spark ?"
      root.detail = "parse error"
    }
  }

  function shortModel(name) {
    var s = String(name || "")
    if (s.length <= 14) return s
    return s.slice(0, 12) + "…"
  }

  Process {
    id: chipProc
    command: [root.collector, "status", "--json", "--fast", "--no-rates"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyChip(text)
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshChip()
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.summary
    active: root.ok && (root.busy || root.sshOk)
    tooltipText: root.detail || root.summary
    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refreshChip()
      else root.togglePanel()
    }
  }
}
