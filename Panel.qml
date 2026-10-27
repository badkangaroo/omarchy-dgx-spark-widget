import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

Panel {
  id: root
  moduleName: "alexokita.dgx-spark-widget"
  ipcTarget: "alexokita.dgx-spark-widget"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property string collector: Qt.resolvedUrl("bin/dgx-spark-status").toString().replace("file://", "")
  readonly property int refreshIntervalSec: Math.max(2, Number(setting("refreshIntervalSec", 5)) || 5)
  readonly property color foreground: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  property bool sshOk: false
  property bool authenticating: false
  property string authError: ""
  property string authTarget: ""
  property string connectionHost: ""
  property string connectionTransport: ""
  property string modelName: ""
  property real liveTokPerSec: -1
  property bool llmBusy: false
  property var device: ({})
  property var history: ({ cpu: [], gpu: [], mem: [] })
  property var ifaceRates: ({})
  property string statusSummary: "Checking Spark…"

  // Auth form fields live in the TextFields themselves; we only keep these as
  // seeds / mirrors. Password never goes to disk or argv.
  property string usernameText: ""
  property string passwordText: ""
  property string hostText: ""
  property bool authFieldsSeeded: false

  readonly property bool editingText: userField.activeFocus || passField.activeFocus || hostField.activeFocus
  readonly property bool showAuth: !sshOk

  function open() { controller.show(); refresh(true) }
  function close() { controller.hide() }
  function toggle() { opened ? close() : open() }
  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    close()
    Qt.callLater(function() { popoutSwitchClosing = false })
  }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  function refresh(forceFast) {
    if (statusProc.running) return
    statusProc.command = forceFast
      ? [root.collector, "status", "--json", "--fast", "--no-rates"]
      : [root.collector, "status", "--json", "--fast"]
    statusProc.running = true
  }

  function applyStatus(text) {
    try {
      var s = JSON.parse(text || "{}")
      var conn = s.connection || {}
      var auth = s.auth || {}
      root.connectionHost = conn.host || ""
      root.connectionTransport = conn.transport || ""
      root.sshOk = auth.ok === true
      root.authTarget = auth.target || ""
      // Never overwrite a live auth error with the background status probe
      // (that probe still uses whatever sshTarget is saved in config).
      if (!root.authenticating && !root.showAuth)
        root.authError = root.sshOk ? "" : (auth.error || "")
      else if (!root.authenticating && root.showAuth && root.authError === "" && !root.sshOk)
        root.authError = ""

      if (!root.authFieldsSeeded && !root.editingText) {
        if (root.hostText === "" && (s.config && s.config.host))
          root.hostText = String(s.config.host)
        else if (root.hostText === "" && root.connectionHost)
          root.hostText = root.connectionHost
        if (root.usernameText === "" && s.config && s.config.sshUser)
          root.usernameText = String(s.config.sshUser)
        if (hostField && root.hostText !== "") hostField.text = root.hostText
        if (userField && root.usernameText !== "") userField.text = root.usernameText
        root.authFieldsSeeded = root.hostText !== "" || root.usernameText !== ""
      }

      root.device = s.device && s.device.ok ? s.device : ({})
      root.history = s.history || ({ cpu: [], gpu: [], mem: [] })
      root.ifaceRates = s.ifaceRates || ({})

      var model = ""
      var live = -1
      var busy = false
      var services = s.services || []
      for (var i = 0; i < services.length; i++) {
        var svc = services[i]
        if (svc.id === "tensorfold") {
          if (svc.models && svc.models.length) model = String(svc.models[0])
          if (svc.liveTokPerSec !== undefined) live = Number(svc.liveTokPerSec)
          else if (svc.decodeTokPerSec !== undefined) live = Number(svc.decodeTokPerSec)
          if (svc.health) busy = svc.health.busy === true
        }
      }
      root.modelName = model
      root.liveTokPerSec = live
      root.llmBusy = busy

      if (!s.ok) root.statusSummary = "Spark unreachable"
      else if (!root.sshOk) root.statusSummary = "Reachable · sign in for device metrics"
      else root.statusSummary = (root.connectionTransport || "connected") + " · " + (root.connectionHost || "")
    } catch (e) {
      root.statusSummary = "Status parse error"
    }
  }

  function submitAuth() {
    if (root.authenticating) return
    root.authError = ""
    // Read from the widgets directly — property bindings can lag behind what
    // the user typed, which previously fell back to the session/config user.
    var user = String(userField.text || "").trim()
    var host = String(hostField.text || "").trim()
    var pass = String(passField.text || "")
    root.usernameText = user
    root.hostText = host
    root.passwordText = pass
    if (user === "") {
      root.authError = "Username required"
      return
    }
    if (host === "") {
      root.authError = "Host required"
      return
    }
    if (pass === "") {
      root.authError = "Password required"
      return
    }
    root.authenticating = true
    authTimeout.restart()
    authProc.secret = JSON.stringify({ user: user, host: host, password: pass })
    authProc.command = [root.collector, "auth"]
    authProc.stdinEnabled = true
    authProc.running = false
    authProc.running = true
  }

  function finishAuth(errorText) {
    authTimeout.stop()
    root.authenticating = false
    if (errorText) root.authError = errorText
  }

  function logout() {
    if (!logoutProc.running) logoutProc.running = true
  }

  function formatRate(bps) {
    var n = Number(bps) || 0
    if (n < 1024) return Math.round(n) + " B/s"
    if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB/s"
    return (n / (1024 * 1024)).toFixed(2) + " MB/s"
  }

  Process {
    id: statusProc
    command: [root.collector, "status", "--json", "--fast"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  Process {
    id: authProc
    property string secret: ""
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var s = JSON.parse(text || "{}")
          var auth = s.auth || {}
          if (s.ok) {
            root.passwordText = ""
            passField.text = ""
            root.sshOk = true
            root.finishAuth("")
            root.refresh(true)
          } else {
            var err = auth.error || "Authentication failed"
            if (auth.target) err = err + " (" + auth.target + ")"
            root.finishAuth(err)
          }
        } catch (e) {
          root.finishAuth("Authentication failed")
        }
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onStarted: {
      write(secret + "\n")
      secret = ""
      // Close the write pipe so the collector's readline is enough even if
      // a future change goes back to read()-until-EOF.
      stdinEnabled = false
    }
    onExited: function(code) {
      if (root.authenticating) {
        if (code !== 0 && root.authError === "")
          root.finishAuth("Authentication failed")
        else
          root.authenticating = false
        authTimeout.stop()
      }
    }
  }

  Timer {
    id: authTimeout
    interval: 35000
    repeat: false
    onTriggered: {
      if (!root.authenticating) return
      if (authProc.running) authProc.running = false
      root.finishAuth("Connection timed out")
    }
  }

  Process {
    id: logoutProc
    command: [root.collector, "logout"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.sshOk = false
        root.device = ({})
        root.history = ({ cpu: [], gpu: [], mem: [] })
        root.refresh(true)
      }
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: root.opened
    repeat: true
    onTriggered: root.refresh(false)
  }

  IpcHandler {
    target: root.moduleName
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh(false) }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editingText
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onReturnRequested: {
        if (root.showAuth) root.submitAuth()
      }

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: content
          width: parent.width
          spacing: Style.space(14)

          PanelHero {
            width: parent.width
            title: "DGX Spark"
            meta: root.statusSummary
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "󰢮"
                textFormat: Text.PlainText
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // -------- Auth gate --------
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.showAuth

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "Sign in with the Spark's SSH username and password (not this Omarchy session). The password is used once to install a local key and is not stored."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
            }

            Column {
              width: parent.width
              spacing: Style.space(6)
              Text {
                text: "HOST"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
                textFormat: Text.PlainText
              }
              TextField {
                id: hostField
                width: parent.width
                placeholderText: "Spark IP, .local, or Tailscale name"
                foreground: root.foreground
                font.family: root.fontFamily
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    userField.forceActiveFocus()
                    event.accepted = true
                  }
                }
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(6)
              Text {
                text: "USERNAME"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
                textFormat: Text.PlainText
              }
              TextField {
                id: userField
                width: parent.width
                placeholderText: "SSH username on the Spark"
                foreground: root.foreground
                font.family: root.fontFamily
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    passField.forceActiveFocus()
                    event.accepted = true
                  }
                }
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(6)
              Text {
                text: "PASSWORD"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
                textFormat: Text.PlainText
              }
              TextField {
                id: passField
                width: parent.width
                placeholderText: "SSH password"
                password: true
                foreground: root.foreground
                font.family: root.fontFamily
                Keys.onPressed: function(event) {
                  if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.submitAuth()
                    event.accepted = true
                  }
                }
              }
            }

            Text {
              width: parent.width
              visible: root.authError !== ""
              wrapMode: Text.WordWrap
              text: root.authError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              textFormat: Text.PlainText
            }

            Button {
              width: parent.width
              text: root.authenticating ? "Connecting…" : "Confirm"
              enabled: !root.authenticating
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.submitAuth()
            }
          }

          // -------- Device status --------
          Column {
            width: parent.width
            spacing: Style.space(12)
            visible: !root.showAuth

            Row {
              width: parent.width
              spacing: Style.space(10)
              Text {
                text: root.modelName !== "" ? root.modelName : "No LLM model"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                textFormat: Text.PlainText
              }
              Text {
                visible: root.liveTokPerSec >= 0
                text: root.liveTokPerSec.toFixed(root.liveTokPerSec >= 10 ? 0 : 1) + " tok/s"
                color: root.llmBusy ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                textFormat: Text.PlainText
              }
            }

            Sparkline {
              width: parent.width
              label: "GPU"
              values: root.history.gpu || []
              current: Number(root.device.gpuPct || 0)
              valueText: (root.device.gpuPct !== undefined ? Math.round(root.device.gpuPct) + "%" : "—")
                + (root.device.clockGraphicsMhz ? "  " + Math.round(root.device.clockGraphicsMhz) + " MHz" : "")
              foreground: root.foreground
              accent: Commons.Color.accent
              fontFamily: root.fontFamily
            }

            Sparkline {
              width: parent.width
              label: "CPU"
              values: root.history.cpu || []
              current: Number(root.device.cpuPct || 0)
              foreground: root.foreground
              accent: Commons.Color.accent
              fontFamily: root.fontFamily
            }

            Sparkline {
              width: parent.width
              label: "MEM"
              values: root.history.mem || []
              current: Number(root.device.memPct || 0)
              valueText: (root.device.memPct !== undefined ? Math.round(root.device.memPct) + "%" : "—")
                + (root.device.memUsedGb !== undefined
                  ? "  " + root.device.memUsedGb + "/" + root.device.memTotalGb + "G"
                  : "")
              foreground: root.foreground
              accent: Commons.Color.accent
              fontFamily: root.fontFamily
            }

            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: root.device.gpus && root.device.gpus.length > 0
              Text {
                text: "VRAM"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
                textFormat: Text.PlainText
              }
              Text {
                text: {
                  var g = root.device.gpus[0]
                  if (!g) return "—"
                  return Math.round(g.memUsedMb) + " / " + Math.round(g.memTotalMb) + " MB"
                    + (root.device.gpuTempC !== undefined && root.device.gpuTempC !== null
                      ? "  ·  " + Math.round(root.device.gpuTempC) + "°C" : "")
                }
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                textFormat: Text.PlainText
              }
            }

            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: root.ifaceRates && root.ifaceRates.ok === true
              Text {
                text: "NET  " + (root.ifaceRates.iface || "")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.letterSpacing: 1
                textFormat: Text.PlainText
              }
              Text {
                text: "↓ " + root.formatRate(root.ifaceRates.rxBps)
                  + "   ↑ " + root.formatRate(root.ifaceRates.txBps)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                textFormat: Text.PlainText
              }
            }

            PanelSeparator { foreground: root.foreground }

            Button {
              width: parent.width
              text: "Disconnect SSH"
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: root.logout()
            }
          }
        }
      }
    }
  }
}
