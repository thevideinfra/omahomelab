import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Polls Proxmox through status.sh and runs actions through action.sh.
// All Proxmox traffic is done by those two scripts; this file only orchestrates.
Item {
    id: root

    property var settings: ({})

    property bool installed: true
    property bool configured: false
    property bool refreshing: false
    property string statusText: "Checking…"
    property string lastError: ""
    property string warning: ""
    property var nodes: []
    property var guests: []
    property var storage: []
    property string actionStatus: ""

    readonly property bool actionBusy: actionProcess.running

    // ---- settings ---------------------------------------------------------
    readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 15, 5, 600)
    readonly property string hostSetting: strSetting("host")
    readonly property int portSetting: intSetting("port", 8006, 1, 65535)
    readonly property var parts: Model.hostParts(hostSetting, portSetting)
    readonly property string caCertPath: strSetting("caCertPath")
    readonly property bool insecureTls: setting("insecureTls", false) === true
    readonly property string nameFilter: strSetting("nameFilter")
    readonly property bool hideStopped: setting("hideStopped", false) === true
    readonly property bool showTemplates: setting("showTemplates", false) === true
    readonly property bool showCountInBar: setting("showCountInBar", true) !== false
    readonly property string consoleMode: Model.consoleMode(setting("consoleMode", ""), setting("preferSpice", false))
    readonly property string sshUser: strSetting("sshUser")
    readonly property string sshDomain: strSetting("sshDomain")
    // Guest name -> ssh user, for guests that log in as someone other than sshUser.
    readonly property var sshUsers: {
        var v = setting("sshUsers", {})
        return v && typeof v === "object" ? v : {}
    }

    readonly property var summary: Model.summary(nodes, guests)

    // Resolve helpers next to this file so the plugin folder stays relocatable.
    readonly property string statusPath: localPath("status.sh")
    readonly property string actionPath: localPath("action.sh")
    readonly property string setupPath: localPath("setup.sh")

    property string _statusOutput: ""
    property string _actionOutput: ""
    property string _actionLabel: ""

    function localPath(name) {
        return Qt.resolvedUrl(name).toString().replace(/^file:\/\//, "")
    }

    function setting(name, fallback) {
        var value = settings ? settings[name] : undefined
        return value === undefined || value === null ? fallback : value
    }

    function strSetting(name) {
        return String(setting(name, "") || "").trim()
    }

    function intSetting(name, fallback, min, max) {
        var n = parseInt(String(setting(name, fallback)), 10)
        if (!isFinite(n)) n = fallback
        if (n < min) n = min
        if (n > max) n = max
        return n
    }

    function connectionArgs() {
        return [
            "--host", parts.host,
            "--port", String(parts.port),
            "--ca", caCertPath,
            "--insecure", insecureTls ? "1" : "0"
        ]
    }

    // ---- status -----------------------------------------------------------
    function refresh() {
        if (statusProcess.running) return
        _statusOutput = ""
        refreshing = true
        statusProcess.command = ["bash", statusPath].concat(connectionArgs())
        statusProcess.running = true
    }

    function applyStatus(raw) {
        var parsed = Model.parseStatus(raw)
        if (!parsed.ok) {
            lastError = parsed.lastError || "Failed to read Proxmox status"
            return
        }
        installed = parsed.installed
        configured = parsed.configured
        statusText = parsed.statusText
        lastError = parsed.lastError
        warning = parsed.warning
        nodes = parsed.nodes
        guests = parsed.guests
        storage = parsed.storage
    }

    // ---- actions ----------------------------------------------------------
    function note(text, ms) {
        actionStatus = text
        actionStatusTimer.interval = ms || 3500
        actionStatusTimer.restart()
    }

    function openWebUi() {
        Quickshell.execDetached(["omarchy-launch-browser", Model.webUiUrl(parts)])
    }

    function openConsole(guest) {
        if (!guest) return
        if (consoleMode === "spice") {
            perform("spice", guest)
            return
        }
        if (consoleMode === "terminal") {
            var target = Model.sshTarget(guest, Model.sshUserFor(guest, sshUser, sshUsers), sshDomain)
            if (target === "") {
                note("Cannot ssh to " + guest.name + ": its name or the ssh user is not a valid host or user", 6000)
                return
            }
            Quickshell.execDetached(["omarchy-launch-terminal", "ssh", target])
            note("Opened ssh " + target + " in a terminal")
            return
        }
        Quickshell.execDetached(["omarchy-launch-browser", Model.consoleUrl(parts, guest)])
        note("Opened console for " + guest.name + " in the browser (log in to Proxmox there first)")
    }

    function perform(op, guest) {
        if (!guest) return
        if (op === "console") {
            openConsole(guest)
            return
        }
        if (actionProcess.running) {
            note("Another action is still running")
            return
        }
        var spec = Model.findAction(guest, op)
        _actionLabel = spec ? spec.label : op
        _actionOutput = ""
        actionProcess.command = ["bash", actionPath].concat(connectionArgs()).concat([
            "--op", op,
            "--node", guest.node,
            "--type", guest.type,
            "--vmid", String(guest.vmid)
        ])
        note(_actionLabel + " " + guest.name + "…", 8000)
        actionProcess.running = true
    }

    // First-run helper: needs a real terminal for the hidden token prompt.
    function setup() {
        Quickshell.execDetached(["omarchy-launch-terminal", "bash", setupPath,
            "--host", parts.host, "--port", String(parts.port)])
        note("Opened setup in a terminal")
    }

    function installDeps() {
        Quickshell.execDetached(["omarchy-launch-terminal", "omarchy", "pkg", "add", "curl", "jq"])
        note("Installing curl and jq in a terminal")
    }

    // Proxmox tasks are asynchronous, so look again shortly after acting.
    function scheduleFollowUps() {
        followUpFast.restart()
        followUpSlow.restart()
    }

    Timer {
        id: refreshTimer
        interval: root.refreshIntervalSec * 1000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Timer { id: followUpFast; interval: 1500; repeat: false; onTriggered: root.refresh() }
    Timer { id: followUpSlow; interval: 5000; repeat: false; onTriggered: root.refresh() }

    Timer {
        id: actionStatusTimer
        interval: 3500
        repeat: false
        onTriggered: root.actionStatus = ""
    }

    Process {
        id: statusProcess
        running: false
        command: []
        stdout: StdioCollector { id: statusStdout; waitForEnd: true; onStreamFinished: root._statusOutput = text }
        stderr: StdioCollector { id: statusStderr; waitForEnd: true }
        onExited: function(exitCode) {
            root.refreshing = false
            var stdout = String(statusStdout.text || root._statusOutput || "")
            if (exitCode === 0) {
                root.applyStatus(stdout)
            } else {
                var err = String(statusStderr.text || stdout || "").replace(/\s+/g, " ").trim()
                root.lastError = err.length > 140 ? err.substring(0, 137) + "…" : (err || "Could not read Proxmox status")
            }
        }
    }

    Process {
        id: actionProcess
        running: false
        command: []
        stdout: StdioCollector { id: actionStdout; waitForEnd: true; onStreamFinished: root._actionOutput = text }
        stderr: StdioCollector { id: actionStderr; waitForEnd: true }
        onExited: function(exitCode) {
            var stdout = String(actionStdout.text || root._actionOutput || "")
            if (exitCode === 0) {
                var r = Model.parseResult(stdout)
                root.note(r.message || (r.ok ? "Done" : "Action failed"), r.ok ? 3500 : 7000)
            } else {
                root.note(root._actionLabel + " failed: " + String(actionStderr.text || "unknown error").trim(), 7000)
            }
            root.scheduleFollowUps()
        }
    }
}
