import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar widget and panel for videinfra.omaprox, styled after tandem and
// omaudiopanel: a header with the version and a close button, section labels
// with icons, rounded cards, boxed choices, and tabs along the bottom (Guests,
// Keys, Settings). All Proxmox traffic goes through status.sh and action.sh
// (Service.qml).
Panel {
    id: root

    moduleName: "videinfra.omaprox"
    ipcTarget: "videinfra.omaprox"
    manageIpc: false

    // ---- display settings (shell.json, set from the Settings tab) ---------
    readonly property string density: String(setting("density", "normal"))
    readonly property real densityScale: Model.densityScale(density)
    readonly property string fontSize: String(setting("fontSize", "normal"))
    // Text shrinks half as fast as spacing so compact stays readable, then the
    // font size setting scales it on top. Sized off the title token, as in
    // tandem and omasnapper.
    readonly property real fontScale: (0.5 + 0.5 * densityScale) * Model.fontSizeScale(fontSize)
    readonly property real fontTitle: Math.round(Style.font.title * fontScale * 1.1)
    readonly property real fontBody: Math.round(Style.font.title * fontScale)
    readonly property real fontSmall: Math.max(9, Math.round(Style.font.title * fontScale * 0.9))
    readonly property real fontCaption: Math.max(9, Math.round(Style.font.caption * fontScale))
    readonly property real fontDisplay: Math.round(Style.font.display * fontScale)

    readonly property var keyRows: Model.keyHelp()
    readonly property string consoleMode: svc.consoleMode
    readonly property bool showStorage: Model.settingBool(setting("showStorage", true), true)

    // About tandem's size: never narrower than the status line needs, and the
    // page area stops growing at pagesMaxHeight; longer pages scroll.
    readonly property real panelWidth: Math.max(sp(330), Style.space(220))
    readonly property real pagesMaxHeight: sp(500)

    property string version: ""

    // How far the page is scrolled, and whether it needs to be.
    readonly property real pageScroll: panelFlick.contentY
    readonly property bool pageOverflows: panelFlick.contentHeight > panelFlick.height

    // Text-box edits wait here until Apply, as in tandem: key -> new value. The
    // keys are host, port, sshUser, sshDomain and sshUsers (the per-guest map).
    property var staged: ({})
    // Just applied, shown until the shell has reloaded its settings.
    property var recent: ({})
    readonly property int pending: Object.keys(staged).length
    readonly property bool dirty: pending > 0
    property bool applying: false
    property string applyError: ""
    property var applyQueue: []
    readonly property bool bannerVisible: dirty || applying || applyError !== ""
    readonly property string pendingText: applyError !== "" ? applyError
        : (applying ? "Applying…" : pending + " pending")

    // The text box being edited, if any: the single-key shortcuts must stay quiet then.
    property Item editorItem: null
    readonly property bool editing: editorItem !== null

    // A thin position cue for pages longer than the panel; it shows when a page
    // appears or scrolls, then fades.
    property bool scrollCueOn: false
    readonly property bool scrollCueVisible: pageOverflows && scrollCueOn

    property string page: "guests"
    readonly property var pages: [
        { id: "guests", label: "Guests", icon: "" },
        { id: "keys", label: "Keys", icon: "" },
        { id: "settings", label: "Settings", icon: "" }
    ]

    // Set by the guest list, which lives in a component and so has no id out here.
    property Repeater guestList: null
    property int rowIndex: 0
    property int selectedVmid: -1
    // Guest whose card is open to show its remaining actions.
    property int expandedVmid: -1
    property bool cursorActive: false
    // "op:vmid" of a destructive action waiting for a second key press.
    property string pendingConfirm: ""

    readonly property color urgent: bar ? bar.urgent : Color.urgent
    readonly property color dim: Qt.darker(barForeground, 1.55)
    // Text on an accent fill: black or white by the accent's luminance.
    readonly property color onAccent: {
        var c = Color.accent
        return (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) > 0.5 ? "#101014" : "#ffffff"
    }

    readonly property bool healthy: svc.installed && svc.configured && svc.lastError === ""

    readonly property var guestRows: Model.visibleGuests(svc.guests, svc.nameFilter, svc.hideStopped, svc.showTemplates)
    readonly property var selectedGuest: guestRows.length > 0 && rowIndex < guestRows.length ? guestRows[rowIndex] : null
    readonly property var selectedActions: Model.guestActions(selectedGuest)
    readonly property var selectedRowActions: Model.rowActions(selectedGuest)

    readonly property string label: svc.showCountInBar && healthy
        ? svc.summary.running + "/" + svc.summary.total
        : ""
    // The bar pill: a server glyph, then the running/total count when it is on.
    readonly property string barText: "󰒋" + (label !== "" ? " " + label : "")
    readonly property string barTooltip: {
        if (!svc.installed) return "Proxmox — curl and jq are required"
        if (!svc.configured) return "Proxmox — " + svc.statusText
        if (svc.lastError !== "") return "Proxmox — " + svc.lastError
        return "Proxmox — " + svc.summary.running + " of " + svc.summary.total + " guests running"
    }

    // Header status line: what just happened, else the state of the connection.
    readonly property string statusLine: {
        if (svc.actionStatus !== "") return svc.actionStatus
        if (!svc.installed) return "curl and jq required"
        if (!svc.configured) return svc.statusText
        if (svc.lastError !== "") return "Unreachable"
        return svc.parts.host + " · " + svc.summary.running + "/" + svc.summary.total
            + " running · " + svc.summary.nodesOnline + "/" + svc.summary.nodesTotal + " nodes"
    }

    // Tooltip for the title and node names, which open the Proxmox web UI.
    readonly property string webUiHint: svc.parts.host !== ""
        ? "Open " + svc.parts.host + ":" + svc.parts.port + " in the browser"
        : "Open the Proxmox web UI"

    // Style.space scaled by the chosen density.
    function sp(px) {
        return Style.space(px * densityScale)
    }

    function tint(alpha) {
        return Util.alpha(barForeground, alpha)
    }

    function setSetting(key, value) {
        Quickshell.execDetached(["omarchy", "bar", "set", "videinfra.omaprox", key, JSON.stringify(value), "--json"])
    }

    // Switch to a tab by id; false for an unknown one.
    function showPage(id) {
        for (var i = 0; i < pages.length; i++) {
            if (pages[i].id === id) {
                page = id
                return true
            }
        }
        return false
    }

    // Text boxes report focus here, so editing blocks the shortcut keys.
    function editorFocus(item, focused) {
        if (focused) editorItem = item
        else if (editorItem === item) editorItem = null
    }

    function showScrollCue() {
        scrollCueOn = true
        scrollCueTimer.restart()
    }

    // What a setting shows: the pending edit, else what was just applied, else what is saved.
    function fieldValue(key, saved) {
        if (key in staged) return staged[key]
        if (key in recent) return recent[key]
        return saved
    }

    function isStaged(key) {
        return key in staged
    }

    // Stage an edit, or drop it when it puts the setting back to what is saved.
    function stage(key, value, saved) {
        var next = {}
        for (var k in staged) if (k !== key) next[k] = staged[k]
        if (JSON.stringify(value) !== JSON.stringify(saved)) next[key] = value
        staged = next
    }

    // Drop one pending edit.
    function unstageField(key) {
        var next = {}
        for (var k in staged) if (k !== key) next[k] = staged[k]
        staged = next
    }

    // Put one guest's ssh user back to what is saved.
    function resetGuestSshUser(guest) {
        if (!guest) return
        var saved = svc.sshUsers[guest.name]
        var r = Model.setSshUser(fieldValue("sshUsers", svc.sshUsers), guest.name, saved === undefined ? "" : saved)
        if (r.ok) stage("sshUsers", r.map, svc.sshUsers)
    }

    function revert() {
        staged = {}
        applyError = ""
    }

    // Write every pending edit, one `omarchy bar set` after another: they all edit
    // shell.json, so running them side by side could lose one.
    function apply() {
        if (applying || !dirty) return
        var queue = []
        for (var k in staged) queue.push({ key: k, value: staged[k] })
        applyQueue = queue
        applyError = ""
        applying = true
        applyNext()
    }

    function applyNext() {
        if (applyQueue.length === 0) {
            recent = staged
            staged = {}
            applying = false
            recentTimer.restart()
            svc.refresh()
            svc.note("Saved", 2500)
            return
        }
        var item = applyQueue[0]
        applier.command = ["omarchy", "bar", "set", "videinfra.omaprox", item.key, JSON.stringify(item.value), "--json"]
        applier.running = true
    }

    // Enter: apply on the Settings tab, the default action on a guest.
    function activate() {
        if (page === "settings") {
            if (dirty && !applying) apply()
            return
        }
        if (page !== "guests") return
        if (!cursorActive) {
            cursorActive = true
            return
        }
        runOp(Model.defaultOp(selectedGuest))
    }

    // The user ssh logs in as for a guest, for the box in its card (pending edits included).
    function sshUserOf(guest) {
        return Model.sshUserFor(guest, fieldValue("sshUser", svc.sshUser), fieldValue("sshUsers", svc.sshUsers))
    }

    // Stage one guest's ssh user (blank, or the default, removes its override). False,
    // with a note, when it is not a valid user name.
    function saveGuestSshUser(guest, text) {
        var u = String(text || "").trim()
        var defaultUser = fieldValue("sshUser", svc.sshUser)
        if (guest && u === Model.sshUserFor(guest, defaultUser, {})) u = ""
        var r = Model.setSshUser(fieldValue("sshUsers", svc.sshUsers), guest ? guest.name : "", u)
        if (!r.ok) return false
        stage("sshUsers", r.map, svc.sshUsers)
        return true
    }

    // Stage one connection field from the Settings tab. False means it was refused as invalid.
    function commitField(key, text) {
        var t = String(text || "").trim()
        var saved = ""
        var value = t
        if (key === "sshUser") {
            if (t !== "" && !Model.validSshUser(t)) return false
            saved = svc.sshUser
        } else if (key === "sshDomain") {
            if (!Model.validDomain(t)) return false
            value = t.replace(/^\.+/, "")
            saved = svc.sshDomain
        } else if (key === "host") {
            if (t !== "" && !Model.validHost(t)) return false
            saved = svc.hostSetting
        } else if (key === "port") {
            if (!Model.validPort(t)) return false
            value = Number(t)
            saved = svc.portSetting
        } else {
            return false
        }
        stage(key, value, saved)
        return true
    }

    function stepPage(step) {
        var index = 0
        for (var i = 0; i < pages.length; i++) if (pages[i].id === page) index = i
        page = pages[((index + step) % pages.length + pages.length) % pages.length].id
    }

    // ---- cursor -----------------------------------------------------------
    function syncCursor() {
        if (guestRows.length === 0) {
            rowIndex = 0
            return
        }
        if (selectedVmid >= 0) {
            for (var i = 0; i < guestRows.length; i++) {
                if (guestRows[i].vmid === selectedVmid) {
                    rowIndex = i
                    return
                }
            }
        }
        rowIndex = Math.max(0, Math.min(guestRows.length - 1, rowIndex))
        selectedVmid = guestRows[rowIndex].vmid
    }

    function setRowCursor(index) {
        cursorActive = true
        if (guestRows.length === 0) return
        rowIndex = Math.max(0, Math.min(guestRows.length - 1, index))
        selectedVmid = guestRows[rowIndex].vmid
        pendingConfirm = ""
    }

    // Keyboard movement opens the card it lands on, so its keys are visible, and
    // scrolls it into view. Mouse hover only moves the highlight: scrolling then
    // would drag the page about under the pointer.
    function moveCursor(dx, dy) {
        if (dy === 0) return
        setRowCursor(rowIndex + dy)
        if (selectedGuest) expandedVmid = selectedGuest.vmid
        Qt.callLater(ensureVisible)
    }

    // Arrow keys: left/right switch tabs; up/down move through the guests.
    function handleMove(dx, dy) {
        if (dx !== 0) {
            stepPage(dx)
            return
        }
        if (page !== "guests") return
        if (!cursorActive) {
            cursorActive = true
            return
        }
        moveCursor(0, dy)
    }

    function toggleExpanded(guest) {
        expandedVmid = expandedVmid === guest.vmid ? -1 : guest.vmid
        Qt.callLater(ensureVisible)
    }

    function ensureVisible() {
        if (!panelFlick || !guestList) return
        var item = guestList.itemAt(rowIndex)
        if (!item) return
        var y = item.mapToItem(pageStack, 0, 0).y
        var pad = sp(6)
        if (y < panelFlick.contentY)
            panelFlick.contentY = Math.max(0, y - pad)
        else if (y + item.height > panelFlick.contentY + panelFlick.height)
            panelFlick.contentY = y + item.height - panelFlick.height + pad
    }

    onGuestRowsChanged: syncCursor()

    // Every tab starts at the top, and shows the scroll cue if it is long.
    onPageChanged: {
        panelFlick.contentY = 0
        showScrollCue()
    }
    onPageOverflowsChanged: if (pageOverflows) showScrollCue()

    // ---- actions ----------------------------------------------------------
    function runOp(op) {
        var g = selectedGuest
        if (!g || op === "") return
        var spec = Model.findAction(g, op)
        if (!spec) {
            svc.note("Not available for " + g.name + " right now")
            return
        }
        if (spec.confirm) {
            var token = op + ":" + g.vmid
            if (pendingConfirm !== token) {
                pendingConfirm = token
                confirmTimer.restart()
                svc.note("Press " + spec.key.toUpperCase() + " again to " + spec.label.toLowerCase() + " " + g.name, 3000)
                return
            }
            pendingConfirm = ""
        }
        svc.perform(op, g)
    }

    // The op behind a card's inline button: start, graceful shutdown or resume.
    function powerOpFor(guest) {
        var a = Model.powerAction(guest)
        return a ? a.op : ""
    }

    function powerToggle(guest) {
        var op = powerOpFor(guest)
        if (op === "") return
        for (var i = 0; i < guestRows.length; i++) {
            if (guestRows[i].vmid === guest.vmid) {
                setRowCursor(i)
                break
            }
        }
        runOp(op)
    }

    function handleKey(t) {
        if (editing) return
        var k = String(t).toLowerCase()
        if (k === "g") { svc.refresh(); return }
        if (k === "o") { svc.openWebUi(); return }
        if (k === "t") { svc.setup(); return }
        // The action keys act on the selected guest, so only on the Guests tab.
        if (page !== "guests") return
        var op = Model.opForKey(k)
        if (op === "") return
        // First key press only reveals the selection so nothing fires blind.
        if (!cursorActive) { cursorActive = true; return }
        runOp(op)
    }

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    onOpenedChanged: if (opened) {
        cursorActive = false
        pendingConfirm = ""
        editorItem = null
        page = "guests"
        expandedVmid = -1
        rowIndex = 0
        selectedVmid = -1
        syncCursor()
        if (panelFlick) panelFlick.contentY = 0
        svc.refresh()
        showScrollCue()
        Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    }

    Service {
        id: svc
        settings: root.settings
    }

    FileView {
        path: svc.localPath("manifest.json")
        printErrors: false
        onLoaded: root.version = Model.manifestVersion(text())
    }

    // Forget the just-applied values once the shell has had time to reload its settings.
    Timer {
        id: recentTimer
        interval: 4000
        repeat: false
        onTriggered: root.recent = ({})
    }

    Process {
        id: applier
        running: false
        command: []
        stdout: StdioCollector { id: applyOut; waitForEnd: true }
        stderr: StdioCollector { id: applyErr; waitForEnd: true }
        onExited: function(exitCode) {
            if (exitCode !== 0) {
                var why = String(applyErr.text || applyOut.text || "unknown error").replace(/\s+/g, " ").trim()
                root.applyError = "Could not save " + root.applyQueue[0].key + ": " + (why.length > 90 ? why.substring(0, 87) + "…" : why)
                root.applyQueue = []
                root.applying = false
                return
            }
            root.applyQueue = root.applyQueue.slice(1)
            root.applyNext()
        }
    }

    Timer {
        id: scrollCueTimer
        interval: 1200
        repeat: false
        onTriggered: root.scrollCueOn = false
    }

    Timer {
        id: confirmTimer
        interval: 3000
        repeat: false
        onTriggered: root.pendingConfirm = ""
    }

    IpcHandler {
        target: root.ipcTarget

        function open(): void { root.open() }
        function close(): void { root.close() }
        function show(): void { root.open() }
        function hide(): void { root.close() }
        function toggle(): void { root.toggle() }
        function refresh(): string { svc.refresh(); return "ok" }
        function page(id: string): string { return root.showPage(id) ? "ok" : "unknown page" }
        function status(): string { return root.healthy ? "Connected" : (svc.lastError || svc.statusText) }
        function running(): string { return svc.summary.running + "/" + svc.summary.total }
        function guests(): string { return JSON.stringify(root.guestRows) }
    }

    // A WidgetButton, not a BarIconButton: that one is icon-only and never draws the count.
    WidgetButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: root.barText
        dimmed: !root.healthy
        tooltipText: root.barTooltip

        onPressed: function(buttonCode) {
            if (buttonCode === Qt.RightButton) svc.refresh()
            else if (buttonCode === Qt.MiddleButton) svc.openWebUi()
            else root.toggle()
        }
    }

    KeyboardPanel {
        id: panel

        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: panel.fittedContentWidth(root.panelWidth)
        contentHeight: panel.fittedContentHeight(
            headerBlock.implicitHeight + pagesHeight + tabBlock.implicitHeight + 2 * root.sp(10), root.sp(640))

        // The tallest page up to the cap, so the panel does not jump about as the tabs change.
        readonly property real pagesHeight: Math.min(root.pagesMaxHeight,
            Math.max(guestsPage.implicitHeight, keysPage.implicitHeight, settingsPage.implicitHeight))

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            blocked: root.editing

            onMoveRequested: function(dx, dy) { root.handleMove(dx, dy) }
            onActivateRequested: root.activate()
            onCloseRequested: root.close()
            onTabRequested: function(direction) { root.switchPanel(direction) }
            onTextKey: function(t) { root.handleKey(t) }

            // ---------- Header: icon · title, version, link / status · close ----------
            Column {
                id: headerBlock
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                spacing: root.sp(10)

                Item {
                    width: parent.width
                    implicitHeight: Math.max(headerIcon.implicitHeight, headerLabels.implicitHeight)

                    ServerIcon {
                        id: headerIcon
                        iconSize: Math.round(root.fontDisplay * 1.3)
                        color: root.healthy ? Color.accent : root.dim
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                        id: headerLabels
                        anchors.left: headerIcon.right
                        anchors.leftMargin: root.sp(12)
                        anchors.right: closeButton.left
                        anchors.rightMargin: root.sp(8)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: root.sp(2)

                        // The name on the left; the version and the web UI link on
                        // the right of the same line, so they stay clear of it.
                        Item {
                            width: parent.width
                            implicitHeight: Math.max(titleText.implicitHeight, versionRow.implicitHeight)

                            Text {
                                id: titleText
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Proxmox"
                                color: titleMouse.containsMouse ? Color.accent : root.barForeground
                                font.family: Style.font.family
                                font.pixelSize: root.fontTitle
                                font.bold: true
                                font.underline: titleMouse.containsMouse

                                MouseArea {
                                    id: titleMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: svc.openWebUi()
                                }

                                PanelToolTip {
                                    visible: titleMouse.containsMouse
                                    text: root.webUiHint
                                    fontFamily: Style.font.family
                                }
                            }

                            Row {
                                id: versionRow
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: root.sp(7)

                                Rectangle {
                                    visible: root.version !== ""
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: versionText.implicitWidth + root.sp(10)
                                    height: versionText.implicitHeight + root.sp(4)
                                    radius: height / 2
                                    color: Util.alpha(Color.accent, 0.15)
                                    border.width: 1
                                    border.color: Util.alpha(Color.accent, 0.45)

                                    Text {
                                        id: versionText
                                        anchors.centerIn: parent
                                        textFormat: Text.PlainText
                                        text: "v" + root.version
                                        color: Color.accent
                                        font.family: Style.font.family
                                        font.pixelSize: root.fontCaption
                                        font.bold: true
                                    }
                                }

                                // Opens the Proxmox web UI in the browser.
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    textFormat: Text.PlainText
                                    text: ""
                                    color: linkMouse.containsMouse ? Color.accent : root.barForeground
                                    opacity: linkMouse.containsMouse ? 1.0 : 0.6
                                    font.family: Style.font.family
                                    font.pixelSize: root.fontBody

                                    MouseArea {
                                        id: linkMouse
                                        anchors.fill: parent
                                        anchors.margins: -root.sp(4)
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: svc.openWebUi()
                                    }

                                    PanelToolTip {
                                        visible: linkMouse.containsMouse
                                        text: root.webUiHint
                                        fontFamily: Style.font.family
                                    }
                                }
                            }
                        }

                        Text {
                            width: parent.width
                            textFormat: Text.PlainText
                            text: root.statusLine.toUpperCase()
                            color: Qt.darker(root.barForeground, 1.4)
                            font.family: Style.font.family
                            font.pixelSize: root.fontCaption
                            font.bold: true
                            font.letterSpacing: 0.6
                            elide: Text.ElideRight
                        }
                    }

                    Rectangle {
                        id: closeButton
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: root.sp(26)
                        height: root.sp(26)
                        radius: root.sp(6)
                        color: closeMouse.containsMouse ? root.tint(0.12) : "transparent"

                        Text {
                            anchors.centerIn: parent
                            textFormat: Text.PlainText
                            text: ""
                            color: root.barForeground
                            font.family: Style.font.family
                            font.pixelSize: root.fontBody
                        }

                        MouseArea {
                            id: closeMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.close()
                        }

                        PanelToolTip {
                            visible: closeMouse.containsMouse
                            text: "Close"
                            fontFamily: Style.font.family
                        }
                    }
                }

                PanelSeparator { foreground: root.barForeground }
            }

            // ---------- Pages ----------
            Flickable {
                id: panelFlick
                anchors.left: parent.left
                // A gutter for the scroll cue, so it never sits over a card.
                anchors.right: parent.right
                anchors.rightMargin: root.sp(7)
                anchors.top: headerBlock.bottom
                anchors.topMargin: root.sp(10)
                anchors.bottom: tabBlock.top
                anchors.bottomMargin: root.sp(10)
                contentWidth: width
                onContentYChanged: root.showScrollCue()
                contentHeight: pageStack.height
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                flickableDirection: Flickable.VerticalFlick
                interactive: contentHeight > height

                Item {
                    id: pageStack
                    width: panelFlick.width
                    height: root.page === "guests" ? guestsPage.implicitHeight
                        : (root.page === "keys" ? keysPage.implicitHeight : settingsPage.implicitHeight)

                    GuestsPage { id: guestsPage; visible: root.page === "guests" }
                    KeysPage { id: keysPage; visible: root.page === "keys" }
                    SettingsPage { id: settingsPage; visible: root.page === "settings" }
                }
            }

            // Where you are in a long page; only while it appears or moves.
            Rectangle {
                readonly property real travel: panelFlick.height - height
                readonly property real range: Math.max(1, panelFlick.contentHeight - panelFlick.height)
                width: Math.max(2, root.sp(3))
                height: Math.max(root.sp(24), panelFlick.height * panelFlick.height / Math.max(1, panelFlick.contentHeight))
                radius: width / 2
                x: parent.width - width - root.sp(1)
                y: panelFlick.y + travel * Math.max(0, Math.min(1, panelFlick.contentY / range))
                color: Color.accent
                opacity: root.scrollCueVisible ? 0.55 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 220 } }
            }

            // ---------- Errors, then the tabs ----------
            Column {
                id: tabBlock
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                spacing: root.sp(10)

                Rectangle {
                    width: parent.width
                    visible: svc.lastError !== "" || svc.warning !== ""
                    implicitHeight: errorText.implicitHeight + root.sp(16)
                    radius: root.sp(7)
                    color: Util.alpha(root.urgent, 0.12)
                    border.width: 1
                    border.color: Util.alpha(root.urgent, 0.4)

                    Text {
                        id: errorText
                        anchors.fill: parent
                        anchors.margins: root.sp(8)
                        wrapMode: Text.Wrap
                        textFormat: Text.PlainText
                        text: svc.lastError !== "" ? svc.lastError : svc.warning
                        color: root.barForeground
                        font.family: Style.font.family
                        font.pixelSize: root.fontCaption
                    }
                }

                // Edits waiting for Apply, as in tandem.
                Rectangle {
                    width: parent.width
                    visible: root.bannerVisible
                    implicitHeight: bannerRow.implicitHeight + root.sp(16)
                    radius: root.sp(7)
                    color: Util.alpha(root.applyError !== "" ? root.urgent : Color.accent, 0.12)
                    border.width: 1
                    border.color: Util.alpha(root.applyError !== "" ? root.urgent : Color.accent, 0.4)

                    Row {
                        id: bannerRow
                        anchors.fill: parent
                        anchors.margins: root.sp(8)
                        spacing: root.sp(8)

                        Text {
                            width: parent.width - revertText.width - applyButton.width - root.sp(16)
                            anchors.verticalCenter: parent.verticalCenter
                            textFormat: Text.PlainText
                            text: root.pendingText
                            color: root.barForeground
                            font.family: Style.font.family
                            font.pixelSize: root.fontSmall
                            font.bold: true
                            elide: Text.ElideRight
                        }

                        Text {
                            id: revertText
                            anchors.verticalCenter: parent.verticalCenter
                            visible: !root.applying
                            textFormat: Text.PlainText
                            text: "Revert"
                            color: root.barForeground
                            opacity: revertMouse.containsMouse ? 1.0 : 0.65
                            font.family: Style.font.family
                            font.pixelSize: root.fontSmall

                            MouseArea {
                                id: revertMouse
                                anchors.fill: parent
                                anchors.margins: -root.sp(4)
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.revert()
                            }
                        }

                        Rectangle {
                            id: applyButton
                            anchors.verticalCenter: parent.verticalCenter
                            width: applyText.implicitWidth + root.sp(18)
                            height: applyText.implicitHeight + root.sp(10)
                            radius: root.sp(6)
                            color: Color.accent
                            opacity: root.applying || !root.dirty ? 0.5 : (applyMouse.containsMouse ? 1.0 : 0.9)

                            Text {
                                id: applyText
                                anchors.centerIn: parent
                                textFormat: Text.PlainText
                                text: "Apply"
                                color: root.onAccent
                                font.family: Style.font.family
                                font.pixelSize: root.fontSmall
                                font.bold: true
                            }

                            MouseArea {
                                id: applyMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                enabled: root.dirty && !root.applying
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.apply()
                            }
                        }
                    }
                }

                PanelSeparator { foreground: root.barForeground }

                Row {
                    width: parent.width

                    Repeater {
                        model: root.pages

                        Item {
                            id: tab
                            required property var modelData
                            readonly property bool current: root.page === modelData.id
                            width: parent.width / root.pages.length
                            height: tabColumn.implicitHeight + root.sp(8)

                            Rectangle {
                                visible: tab.current
                                anchors.top: parent.top
                                anchors.horizontalCenter: parent.horizontalCenter
                                width: parent.width * 0.5
                                height: Math.max(2, root.sp(2))
                                radius: height / 2
                                color: Color.accent
                            }

                            Column {
                                id: tabColumn
                                anchors.centerIn: parent
                                spacing: root.sp(2)

                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    textFormat: Text.PlainText
                                    text: tab.modelData.icon
                                    color: tab.current ? Color.accent : root.barForeground
                                    opacity: tab.current || tabMouse.containsMouse ? 1.0 : 0.55
                                    font.family: Style.font.family
                                    font.pixelSize: root.fontTitle
                                }

                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    textFormat: Text.PlainText
                                    text: tab.modelData.label
                                    color: tab.current ? Color.accent : root.barForeground
                                    opacity: tab.current || tabMouse.containsMouse ? 1.0 : 0.55
                                    font.family: Style.font.family
                                    font.pixelSize: root.fontCaption
                                    font.bold: tab.current
                                }
                            }

                            MouseArea {
                                id: tabMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.page = tab.modelData.id
                            }
                        }
                    }
                }
            }
        }
    }

    // ======================================================== pages

    component GuestsPage: Column {
        width: parent.width
        spacing: root.sp(10)

        // ------------------------------------------------ setup
        Column {
            visible: !svc.installed || !svc.configured || svc.lastError !== ""
            width: parent.width
            spacing: root.sp(8)

            SectionLabel { icon: ""; text: "SETUP" }

            Flow {
                width: parent.width
                spacing: root.sp(8)

                ActionButton {
                    visible: !svc.installed
                    text: "Install curl and jq"
                    strong: true
                    onClicked: svc.installDeps()
                }
                ActionButton {
                    visible: svc.installed
                    text: "Set up token and certificate"
                    strong: true
                    onClicked: svc.setup()
                }
                ActionButton {
                    visible: svc.installed && svc.configured
                    text: "Retry now"
                    onClicked: svc.refresh()
                }
            }
            Caption {
                width: parent.width
                visible: svc.installed
                text: "Setup opens a terminal (key: T). Retry is key G."
            }
        }

        // ----------------------------------------------- nodes
        Column {
            visible: root.healthy && svc.nodes.length > 0
            width: parent.width
            spacing: root.sp(8)

            SectionLabel { icon: ""; text: "NODES" }

            Repeater {
                model: svc.nodes

                NodeCard {
                    required property var modelData
                    width: parent.width
                    node: modelData
                }
            }
        }

        // --------------------------------------------- guests
        Column {
            visible: root.healthy
            width: parent.width
            spacing: root.sp(8)

            SectionLabel {
                icon: ""
                text: "VMS AND CONTAINERS"
                tag: svc.nameFilter !== "" ? "FILTER: " + svc.nameFilter.toUpperCase()
                    : root.guestRows.length + (root.guestRows.length === 1 ? " GUEST" : " GUESTS")
            }

            Caption {
                visible: root.guestRows.length === 0
                width: parent.width
                text: svc.guests.length === 0 ? "No guests visible to this token" : "No guests match the current filters"
            }

            Column {
                width: parent.width
                spacing: root.sp(5)

                Repeater {
                    id: guestRepeater
                    model: root.guestRows
                    Component.onCompleted: root.guestList = guestRepeater

                    GuestCard {
                        required property var modelData
                        required property int index
                        width: parent.width
                        guest: modelData
                        position: index
                    }
                }
            }
        }

        // ------------------------------------------ storage
        Column {
            visible: root.healthy && root.showStorage && svc.storage.length > 0
            width: parent.width
            spacing: root.sp(8)

            SectionLabel { icon: ""; text: "STORAGE" }

            Repeater {
                model: svc.storage

                StorageCard {
                    required property var modelData
                    width: parent.width
                    entry: modelData
                }
            }
        }

        Caption {
            visible: root.healthy
            width: parent.width
            text: "↑↓ select · Enter default action · every key is listed on the Keys tab"
        }
    }

    component KeysPage: Column {
        width: parent.width
        spacing: root.sp(10)

        SectionLabel { icon: ""; text: "KEYBOARD" }

        Caption {
            width: parent.width
            text: "Actions apply to the selected guest, and only when its state allows them. The first key press only shows the selection."
        }

        Column {
            width: parent.width
            spacing: root.sp(5)

            Repeater {
                model: root.keyRows

                KeyRow {
                    required property var modelData
                    width: parent.width
                    label: modelData.label
                    note: modelData.note
                    keys: modelData.key
                }
            }
        }
    }

    component SettingsPage: Column {
        width: parent.width
        spacing: root.sp(10)

        SectionLabel { icon: ""; text: "DENSITY" }

        Segmented {
            width: parent.width
            columns: 3
            choices: [
                { value: "compact", label: "Compact" },
                { value: "normal", label: "Normal" },
                { value: "roomy", label: "Roomy" }
            ]
            selected: root.density
            onPicked: function(value) { root.setSetting("density", value) }
        }

        SectionLabel { icon: ""; text: "FONT SIZE" }

        Segmented {
            width: parent.width
            columns: 3
            choices: [
                { value: "small", label: "Small" },
                { value: "normal", label: "Normal" },
                { value: "large", label: "Large" }
            ]
            selected: root.fontSize
            onPicked: function(value) { root.setSetting("fontSize", value) }
        }

        PanelSeparator { foreground: root.barForeground }
        SectionLabel { icon: ""; text: "SHOW" }

        SettingSwitch {
            width: parent.width
            label: "Count next to the bar icon"
            checked: svc.showCountInBar
            onToggled: root.setSetting("showCountInBar", !svc.showCountInBar)
        }
        SettingSwitch {
            width: parent.width
            label: "Storage section"
            checked: root.showStorage
            onToggled: root.setSetting("showStorage", !root.showStorage)
        }
        SettingSwitch {
            width: parent.width
            label: "Hide stopped guests"
            checked: svc.hideStopped
            onToggled: root.setSetting("hideStopped", !svc.hideStopped)
        }
        SettingSwitch {
            width: parent.width
            label: "Show templates"
            checked: svc.showTemplates
            onToggled: root.setSetting("showTemplates", !svc.showTemplates)
        }

        PanelSeparator { foreground: root.barForeground }
        SectionLabel { icon: ""; text: "CONSOLE" }

        Segmented {
            width: parent.width
            columns: 3
            choices: [
                { value: "browser", label: "Browser" },
                { value: "spice", label: "SPICE" },
                { value: "terminal", label: "SSH" }
            ]
            selected: root.consoleMode
            onPicked: function(value) { root.setSetting("consoleMode", value) }
        }

        Caption {
            width: parent.width
            text: root.consoleMode === "terminal"
                ? "Console runs ssh in a terminal, using the guest's name as its address. Open a guest to give it its own user."
                : (root.consoleMode === "spice" ? "Console opens remote-viewer (virt-viewer)." : "Console opens the web UI console in your browser.")
        }

        SettingField {
            width: parent.width
            visible: root.consoleMode === "terminal"
            label: "Default user"
            fieldKey: "sshUser"
            value: root.fieldValue("sshUser", svc.sshUser)
            placeholder: "root"
        }
        SettingField {
            width: parent.width
            visible: root.consoleMode === "terminal"
            label: "Domain"
            fieldKey: "sshDomain"
            value: root.fieldValue("sshDomain", svc.sshDomain)
            placeholder: "e.g. lan"
        }

        PanelSeparator { foreground: root.barForeground }
        SectionLabel { icon: ""; text: "CONNECTION" }

        SettingField {
            width: parent.width
            label: "Host"
            fieldKey: "host"
            value: root.fieldValue("host", svc.hostSetting)
            placeholder: "pve.lan"
        }
        SettingField {
            width: parent.width
            label: "Port"
            fieldKey: "port"
            value: String(root.fieldValue("port", svc.portSetting))
            placeholder: "8006"
        }

        Caption {
            width: parent.width
            text: "The certificate path and name filter are in the widget's settings."
        }

        Flow {
            width: parent.width
            spacing: root.sp(8)

            ActionButton {
                text: "Set up token"
                onClicked: svc.setup()
            }
            ActionButton {
                text: "Open web UI"
                onClicked: svc.openWebUi()
            }
        }
    }

    // ======================================================== cards

    component NodeCard: Rectangle {
        id: nodeCard
        property var node: null
        readonly property bool online: node !== null && node.status === "online"
        implicitHeight: nodeColumn.implicitHeight + root.sp(16)
        radius: root.sp(7)
        color: root.tint(0.05)
        border.width: 1
        border.color: root.tint(0.1)

        Column {
            id: nodeColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: root.sp(8)
            spacing: root.sp(5)

            RowLayout {
                width: parent.width
                spacing: root.sp(8)

                Text {
                    textFormat: Text.PlainText
                    text: ""
                    color: nodeCard.online ? Color.accent : (node && node.status === "offline" ? root.urgent : root.barForeground)
                    opacity: nodeCard.online ? 1.0 : 0.6
                    font.family: Style.font.family
                    font.pixelSize: root.fontBody
                    Layout.preferredWidth: root.sp(20)
                }
                Text {
                    text: node ? node.name : ""
                    color: nodeMouse.containsMouse ? Color.accent : root.barForeground
                    font.family: Style.font.family
                    font.pixelSize: root.fontBody
                    font.bold: true
                    font.underline: nodeMouse.containsMouse
                    Layout.fillWidth: true
                    elide: Text.ElideRight

                    MouseArea {
                        id: nodeMouse
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        width: Math.min(parent.width, parent.implicitWidth)
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: svc.openWebUi()
                    }

                    PanelToolTip {
                        visible: nodeMouse.containsMouse
                        text: root.webUiHint
                        fontFamily: Style.font.family
                    }
                }
                Text {
                    text: nodeCard.online ? "up " + Model.formatUptime(node.uptime) : (node ? node.status : "")
                    color: node && node.status === "offline" ? root.urgent : root.barForeground
                    opacity: node && node.status === "offline" ? 1.0 : 0.55
                    font.family: Style.font.family
                    font.pixelSize: root.fontCaption
                }
            }
            MiniMeter {
                visible: nodeCard.online
                width: parent.width
                caption: "CPU"
                value: node ? node.cpu : 0
                detail: node ? Model.formatPercent(node.cpu) + " of " + node.maxcpu : ""
            }
            MiniMeter {
                visible: nodeCard.online
                width: parent.width
                caption: "MEM"
                value: node ? Model.fraction(node.mem, node.maxmem) : 0
                detail: node ? Model.formatBytes(node.mem) + "/" + Model.formatBytes(node.maxmem) : ""
            }
        }
    }

    component StorageCard: Rectangle {
        property var entry: null
        readonly property real used: entry ? Model.fraction(entry.used, entry.total) : 0
        implicitHeight: storageColumn.implicitHeight + root.sp(16)
        radius: root.sp(7)
        color: root.tint(0.05)
        border.width: 1
        border.color: root.tint(0.1)

        Column {
            id: storageColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: root.sp(8)
            spacing: root.sp(4)

            RowLayout {
                width: parent.width
                spacing: root.sp(8)

                Text {
                    text: entry ? entry.name + (entry.shared ? "" : "  @" + entry.node) : ""
                    color: root.barForeground
                    font.family: Style.font.family
                    font.pixelSize: root.fontSmall
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                }
                Text {
                    text: entry && entry.total > 0
                        ? Model.formatBytes(entry.used) + " / " + Model.formatBytes(entry.total) + "  " + Model.formatPercent(used)
                        : (entry ? entry.status : "")
                    color: Model.usageLevel(used) === "critical" ? root.urgent : root.barForeground
                    opacity: Model.usageLevel(used) === "critical" ? 1.0 : 0.55
                    font.family: Style.font.family
                    font.pixelSize: root.fontCaption
                }
            }
            Rectangle {
                visible: entry !== null && entry.total > 0
                width: parent.width
                height: root.sp(5)
                radius: height / 2
                color: root.tint(0.14)

                Rectangle {
                    width: parent.width * used
                    height: parent.height
                    radius: parent.radius
                    color: Model.usageLevel(used) === "critical" ? root.urgent : Color.accent
                    opacity: Model.usageLevel(used) === "warning" ? 0.85 : 1.0
                }
            }
        }
    }

    component MiniMeter: RowLayout {
        property string caption: ""
        property real value: 0
        property string detail: ""
        spacing: root.sp(8)

        Text {
            text: caption
            color: root.barForeground
            opacity: 0.55
            font.family: Style.font.family
            font.pixelSize: root.fontCaption
            Layout.preferredWidth: root.sp(34)
        }
        Rectangle {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            height: root.sp(6)
            radius: height / 2
            color: root.tint(0.14)

            Rectangle {
                width: parent.width * Math.max(0, Math.min(1, value))
                height: parent.height
                radius: parent.radius
                color: Model.usageLevel(value) === "critical" ? root.urgent : Color.accent
                opacity: Model.usageLevel(value) === "warning" ? 0.85 : 1.0
                Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutQuad } }
            }
        }
        Text {
            text: detail
            color: root.barForeground
            opacity: 0.55
            font.family: Style.font.family
            font.pixelSize: root.fontCaption
            horizontalAlignment: Text.AlignRight
            Layout.preferredWidth: root.sp(112)
        }
    }

    // A VM or container as a card: icon, name and details, usage, and the inline
    // power button. Click opens the card to show Reboot, Console and the rest;
    // the pointer only moves the highlight.
    component GuestCard: Rectangle {
        id: guestCard
        property var guest: null
        property int position: 0
        readonly property bool expanded: guest !== null && root.expandedVmid === guest.vmid
        readonly property bool running: guest !== null && guest.status === "running"
        readonly property bool hasCursor: root.cursorActive && root.rowIndex === position
        readonly property string powerOp: root.powerOpFor(guest)
        readonly property var extraActions: Model.rowActions(guest)

        implicitHeight: cardColumn.implicitHeight + root.sp(14)
        radius: root.sp(7)
        color: expanded ? Util.alpha(Color.accent, 0.1) : (hasCursor ? root.tint(0.09) : root.tint(0.05))
        border.width: 1
        border.color: expanded ? Util.alpha(Color.accent, 0.45) : root.tint(0.1)

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onEntered: root.setRowCursor(guestCard.position)
            onClicked: {
                root.setRowCursor(guestCard.position)
                root.toggleExpanded(guestCard.guest)
            }
        }

        Column {
            id: cardColumn
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: root.sp(7)
            spacing: root.sp(8)

            RowLayout {
                width: parent.width
                spacing: root.sp(8)

                Text {
                    textFormat: Text.PlainText
                    text: guest ? (guest.type === "lxc" ? "" : "") : ""
                    color: guestCard.running || guestCard.expanded ? Color.accent : root.barForeground
                    opacity: guest && guest.status === "stopped" ? 0.45 : (guest && guest.status === "paused" ? 0.65 : 1.0)
                    font.family: Style.font.family
                    font.pixelSize: root.fontTitle
                    Layout.preferredWidth: root.sp(22)
                    horizontalAlignment: Text.AlignHCenter
                    Layout.alignment: Qt.AlignVCenter
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: root.sp(2)

                    Text {
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                        text: guest ? guest.name : ""
                        color: root.barForeground
                        font.family: Style.font.family
                        font.pixelSize: root.fontBody
                        font.bold: guestCard.expanded
                        elide: Text.ElideRight
                    }
                    Text {
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                        text: {
                            if (!guest) return ""
                            var bits = [Model.guestLabel(guest.type) + " " + guest.vmid, guest.node]
                            if (guestCard.running) bits.push("up " + Model.formatUptime(guest.uptime))
                            if (guest.lock !== "") bits.push("locked: " + guest.lock)
                            if (guest.tags !== "") bits.push(guest.tags)
                            return bits.join(" · ")
                        }
                        color: guest && guest.lock !== "" ? root.urgent : root.barForeground
                        opacity: guest && guest.lock !== "" ? 1.0 : 0.55
                        font.family: Style.font.family
                        font.pixelSize: root.fontCaption
                        elide: Text.ElideRight
                    }
                }

                Column {
                    Layout.alignment: Qt.AlignVCenter
                    spacing: root.sp(2)

                    Text {
                        anchors.right: parent.right
                        textFormat: Text.PlainText
                        text: guestCard.running ? Model.formatPercent(guest.cpu) : (guest ? guest.status : "")
                        color: root.barForeground
                        opacity: 0.75
                        font.family: Style.font.family
                        font.pixelSize: root.fontCaption
                    }
                    Text {
                        anchors.right: parent.right
                        visible: guestCard.running
                        textFormat: Text.PlainText
                        text: guest ? Model.formatBytes(guest.mem) : ""
                        color: root.barForeground
                        opacity: 0.45
                        font.family: Style.font.family
                        font.pixelSize: root.fontCaption
                    }
                }

                // Inline power: start when stopped, graceful shutdown when
                // running. Force stop stays behind the confirm in the open card.
                Rectangle {
                    id: powerButton
                    visible: guestCard.powerOp !== ""
                    Layout.preferredWidth: root.sp(28)
                    Layout.preferredHeight: root.sp(28)
                    Layout.alignment: Qt.AlignVCenter
                    radius: root.sp(6)
                    color: powerMouse.containsMouse && !svc.actionBusy ? Util.alpha(Color.accent, 0.18) : root.tint(0.08)
                    border.width: 1
                    border.color: powerMouse.containsMouse && !svc.actionBusy ? Color.accent : root.tint(0.22)
                    opacity: svc.actionBusy ? 0.4 : 1.0

                    Text {
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: guestCard.powerOp === "shutdown" ? "󰐥" : "󰐊"
                        color: powerMouse.containsMouse && !svc.actionBusy ? Color.accent : root.barForeground
                        font.family: Style.font.family
                        font.pixelSize: root.fontBody
                    }

                    MouseArea {
                        id: powerMouse
                        anchors.fill: parent
                        enabled: !svc.actionBusy
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.powerToggle(guestCard.guest)
                    }

                    PanelToolTip {
                        visible: powerMouse.containsMouse
                        text: guestCard.powerOp === "shutdown" ? "Shut down " + guestCard.guest.name
                            : (guestCard.powerOp === "resume" ? "Resume " + guestCard.guest.name : "Start " + guestCard.guest.name)
                        fontFamily: Style.font.family
                    }
                }
            }

            // The rest of the actions, or why there are none.
            Flow {
                visible: guestCard.expanded && guestCard.extraActions.length > 0
                width: parent.width
                spacing: root.sp(6)

                Repeater {
                    model: guestCard.extraActions

                    ActionButton {
                        required property var modelData
                        readonly property bool armed: guestCard.guest !== null
                            && root.pendingConfirm === modelData.op + ":" + guestCard.guest.vmid
                        text: modelData.label + (armed ? " — press again" : "")
                        keyHint: modelData.key.toUpperCase()
                        danger: modelData.danger === true
                        strong: armed
                        active: !svc.actionBusy || modelData.op === "console"
                        onClicked: { root.setRowCursor(guestCard.position); root.runOp(modelData.op) }
                    }
                }
            }

            // Which user Console logs in as, when Console is an ssh session.
            Item {
                visible: guestCard.expanded && root.consoleMode === "terminal" && guestCard.guest !== null && guestCard.guest.status !== "stopped"
                width: parent.width
                implicitHeight: Math.max(sshLabel.implicitHeight, sshBox.implicitHeight)

                Text {
                    id: sshLabel
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: "SSH as"
                    color: root.barForeground
                    opacity: 0.65
                    font.family: Style.font.family
                    font.pixelSize: root.fontCaption
                }

                TextBox {
                    id: sshBox
                    objectName: "box-guest-" + (guestCard.guest ? guestCard.guest.name : "")
                    anchors.right: parent.right
                    width: parent.width * 0.62
                    value: root.sshUserOf(guestCard.guest)
                    pending: root.isStaged("sshUsers")
                    placeholderText: root.sshUserOf(null) || "root"
                    onEdited: function(text) {
                        var ok = root.saveGuestSshUser(guestCard.guest, text)
                        if (!ok) root.resetGuestSshUser(guestCard.guest)
                        sshBox.bad = !ok
                    }
                    onRevertRequested: root.resetGuestSshUser(guestCard.guest)
                }
            }

            Caption {
                visible: guestCard.expanded && guestCard.extraActions.length === 0 && guestCard.powerOp === ""
                width: parent.width
                text: guest && guest.lock !== "" ? "Locked by: " + guest.lock : "No actions available in this state"
            }
        }
    }

    // ======================================================== components

    // Title with a dim icon, and an optional tag on the right.
    component SectionLabel: Item {
        id: section
        property string icon: ""
        property string text: ""
        property string tag: ""

        width: parent ? parent.width : implicitWidth
        implicitHeight: Math.max(sectionTitle.implicitHeight, sectionIcon.implicitHeight)

        Text {
            id: sectionIcon
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: root.sp(20)
            textFormat: Text.PlainText
            text: section.icon
            color: root.barForeground
            opacity: 0.65
            font.family: Style.font.family
            font.pixelSize: root.fontBody
        }

        Text {
            id: sectionTitle
            anchors.left: sectionIcon.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: section.text
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: root.fontSmall
            font.bold: true
            font.letterSpacing: 1.2
        }

        Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: section.tag
            color: root.barForeground
            opacity: 0.4
            font.family: Style.font.family
            font.pixelSize: root.fontCaption
            font.letterSpacing: 0.8
        }
    }

    component Caption: Text {
        color: root.barForeground
        opacity: 0.45
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        font.family: Style.font.family
        font.pixelSize: root.fontCaption
    }

    // A small outlined button. strong fills it with the accent; danger turns it
    // urgent; keyHint adds the shortcut at the end.
    component ActionButton: Rectangle {
        id: actionButton
        property string text: ""
        property string keyHint: ""
        property bool strong: false
        property bool danger: false
        property bool active: true
        signal clicked()

        readonly property color tone: danger ? root.urgent : Color.accent

        implicitWidth: buttonRow.implicitWidth + root.sp(18)
        implicitHeight: buttonRow.implicitHeight + root.sp(10)
        radius: root.sp(5)
        color: strong ? tone : (buttonMouse.containsMouse && active ? Util.alpha(tone, 0.18) : "transparent")
        border.width: 1
        border.color: strong ? tone : (buttonMouse.containsMouse && active ? tone : (danger ? Util.alpha(root.urgent, 0.55) : root.tint(0.25)))
        opacity: active ? 1.0 : 0.4

        Row {
            id: buttonRow
            anchors.centerIn: parent
            spacing: root.sp(6)

            Text {
                textFormat: Text.PlainText
                text: actionButton.text
                color: actionButton.strong ? root.onAccent
                    : (actionButton.danger ? root.urgent : (buttonMouse.containsMouse && actionButton.active ? Color.accent : root.barForeground))
                font.family: Style.font.family
                font.pixelSize: root.fontCaption
                font.bold: actionButton.strong
            }
            Text {
                visible: actionButton.keyHint !== ""
                textFormat: Text.PlainText
                text: actionButton.keyHint
                color: actionButton.strong ? root.onAccent : root.barForeground
                opacity: 0.55
                font.family: Style.font.family
                font.pixelSize: root.fontCaption
            }
        }

        MouseArea {
            id: buttonMouse
            anchors.fill: parent
            enabled: actionButton.active
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: actionButton.clicked()
        }
    }

    // A label (and note) on the left and key caps on the right: "Start  [S]".
    component KeyRow: Rectangle {
        id: keyRow
        property string label: ""
        property string note: ""
        property string keys: ""

        implicitHeight: Math.max(labelColumn.implicitHeight, capsRow.implicitHeight) + root.sp(14)
        radius: root.sp(7)
        color: root.tint(0.05)
        border.width: 1
        border.color: root.tint(0.1)

        Column {
            id: labelColumn
            anchors.left: parent.left
            anchors.leftMargin: root.sp(10)
            anchors.right: capsRow.left
            anchors.rightMargin: root.sp(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.sp(1)

            Text {
                width: parent.width
                textFormat: Text.PlainText
                text: keyRow.label
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: root.fontBody
                elide: Text.ElideRight
            }
            Text {
                width: parent.width
                visible: keyRow.note !== ""
                textFormat: Text.PlainText
                text: keyRow.note
                color: root.barForeground
                opacity: 0.55
                font.family: Style.font.family
                font.pixelSize: root.fontCaption
                wrapMode: Text.WordWrap
            }
        }

        Row {
            id: capsRow
            anchors.right: parent.right
            anchors.rightMargin: root.sp(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.sp(4)

            Repeater {
                model: keyRow.keys.split(" ")

                Rectangle {
                    required property string modelData
                    width: Math.max(root.sp(22), capText.implicitWidth + root.sp(14))
                    height: capText.implicitHeight + root.sp(8)
                    radius: root.sp(5)
                    color: root.tint(0.08)
                    border.width: 1
                    border.color: root.tint(0.28)

                    Text {
                        id: capText
                        anchors.centerIn: parent
                        textFormat: Text.PlainText
                        text: parent.modelData
                        color: root.barForeground
                        font.family: Style.font.family
                        font.pixelSize: root.fontSmall
                    }
                }
            }
        }
    }

    // Equal-width choice boxes in a grid; the chosen one is tinted and outlined
    // in the accent. choices: [{ value, label }].
    component Segmented: Grid {
        id: segmented
        property var choices: []
        property var selected
        signal picked(var value)

        spacing: root.sp(6)
        readonly property real cellWidth: (width - (columns - 1) * spacing) / columns

        Repeater {
            model: segmented.choices

            Rectangle {
                id: choice
                required property var modelData
                readonly property bool chosen: segmented.selected === modelData.value
                width: segmented.cellWidth
                implicitHeight: choiceText.implicitHeight + root.sp(12)
                radius: root.sp(7)
                color: chosen ? Util.alpha(Color.accent, 0.12) : (choiceMouse.containsMouse ? root.tint(0.09) : root.tint(0.05))
                border.width: chosen ? 2 : 1
                border.color: chosen ? Color.accent : root.tint(0.12)

                Text {
                    id: choiceText
                    anchors.centerIn: parent
                    textFormat: Text.PlainText
                    text: choice.modelData.label
                    color: choice.chosen ? Color.accent : root.barForeground
                    font.family: Style.font.family
                    font.pixelSize: root.fontSmall
                    font.bold: choice.chosen
                }

                MouseArea {
                    id: choiceMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: segmented.picked(choice.modelData.value)
                }
            }
        }
    }

    // A text box that tells the panel when it has focus (so shortcut keys stay
    // quiet) and reports every edit as it is made, so the pending banner shows at
    // once, as in tandem. Enter only lets go of the box; Esc asks for the saved
    // value back.
    component TextBox: TextField {
        id: box
        property string value: ""
        property bool bad: false
        // An edit waiting for Apply.
        property bool pending: false
        signal edited(string text)
        signal revertRequested()

        foreground: root.barForeground
        accent: Color.accent
        color: bad ? root.urgent : (pending ? Color.accent : root.barForeground)
        font.pixelSize: root.fontSmall
        verticalPadding: root.sp(4)
        horizontalPadding: root.sp(8)
        selectByMouse: true

        // Hand focus back to the panel only after the key event has finished:
        // doing it at once un-blocks the key catcher while this very key is still
        // on its way up to it.
        function release() {
            Qt.callLater(function() {
                box.focus = false
                keyCatcher.forceActiveFocus()
            })
        }

        Component.onCompleted: text = value
        onValueChanged: if (!activeFocus) { text = value; bad = false }
        onTextEdited: edited(text)
        onActiveFocusChanged: {
            root.editorFocus(box, activeFocus)
            if (!activeFocus) { text = value; bad = false }
        }
        // Enter is handled and stopped here: a text input leaves it unaccepted, so it
        // would otherwise keep bubbling up to the key catcher and apply the edits.
        Keys.onReturnPressed: function(event) { release(); event.accepted = true }
        Keys.onEnterPressed: function(event) { release(); event.accepted = true }
        Keys.onEscapePressed: function(event) {
            revertRequested()
            text = value
            bad = false
            release()
            event.accepted = true
        }
    }

    // A label on the left and a text box on the right; each edit is staged through commitField.
    component SettingField: Item {
        id: field
        property string label: ""
        property string fieldKey: ""
        property string value: ""
        property string placeholder: ""

        implicitHeight: Math.max(fieldLabel.implicitHeight, fieldBox.implicitHeight)

        Text {
            id: fieldLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: field.label
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: root.fontBody
        }

        TextBox {
            id: fieldBox
            objectName: "box-" + field.fieldKey
            anchors.right: parent.right
            width: parent.width * 0.58
            value: field.value
            pending: root.isStaged(field.fieldKey)
            placeholderText: field.placeholder
            onEdited: function(text) {
                var ok = root.commitField(field.fieldKey, text)
                if (!ok) root.unstageField(field.fieldKey)
                fieldBox.bad = !ok
            }
            onRevertRequested: root.unstageField(field.fieldKey)
        }
    }

    // A labelled on/off switch row; the whole row takes the click.
    component SettingSwitch: Item {
        id: settingRow
        property string label: ""
        property bool checked: false
        signal toggled()

        implicitHeight: Math.max(settingLabel.implicitHeight, settingToggle.implicitHeight)

        Text {
            id: settingLabel
            anchors.left: parent.left
            anchors.right: settingToggle.left
            anchors.rightMargin: root.sp(8)
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: settingRow.label
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: root.fontBody
            elide: Text.ElideRight
        }

        AccentSwitch {
            id: settingToggle
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: settingRow.checked
        }

        MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: settingRow.toggled()
        }
    }

    // On/off switch in the theme accent: accent track and knob when on, a dim
    // neutral track when off. Presentation only; its row owns the click.
    component AccentSwitch: Item {
        id: sw
        property bool checked: false

        implicitWidth: root.sp(34)
        implicitHeight: root.sp(18)

        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: sw.checked ? Util.alpha(Color.accent, 0.3) : root.tint(0.1)
            border.width: 1
            border.color: sw.checked ? Color.accent : root.tint(0.25)
            Behavior on color { ColorAnimation { duration: 120 } }

            Rectangle {
                width: parent.height - root.sp(6)
                height: width
                radius: width / 2
                anchors.verticalCenter: parent.verticalCenter
                x: sw.checked ? parent.width - width - root.sp(3) : root.sp(3)
                color: sw.checked ? Color.accent : Qt.darker(root.barForeground, 1.4)
                Behavior on x { NumberAnimation { duration: 120 } }
                Behavior on color { ColorAnimation { duration: 120 } }
            }
        }
    }
}
