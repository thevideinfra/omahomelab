import QtQuick
import QtTest
import Quickshell
import "plugin" as P

Item {
    width: 500; height: 700
    P.Panel { id: panel; settings: ({ host: "pve.lan", showCountInBar: true }) }
    P.Panel { id: sshPanel; settings: ({ host: "pve.lan", consoleMode: "terminal", sshUser: "ks", sshDomain: "lan", sshUsers: ({ pihole: "admin" }) }) }
    P.Panel { id: quietPanel; settings: ({ host: "pve.lan", showCountInBar: false }) }
    P.Panel { id: collapsedPanel; settings: ({ host: "pve.lan", nodesCollapsed: true }) }
    P.Panel { id: compactPanel; settings: ({ host: "pve.lan", density: "compact", fontSize: "large", showStorage: false }) }

    TestCase {
        name: "PanelSmoke"
        when: windowShown

        function lastProc() { return Quickshell.procs[Quickshell.procs.length - 1] }
        function lastExec() { return Quickshell.execs[Quickshell.execs.length - 1] }
        function flag(cmd, name) { return cmd[cmd.indexOf(name) + 1] }
        // The settings writes since index n (applying also re-reads the status, which is not one).
        function writesSince(n) { return Quickshell.procs.slice(n).filter(function(c) { return c[0] === "omarchy" }) }

        function test_flow() {
            wait(300)
            // --- initial poll (triggeredOnStart) used the parsed settings
            verify(Quickshell.procs.length >= 1, "status poll ran")
            var first = Quickshell.procs[0]
            compare(first[1].split("/").pop(), "status.sh")
            compare(flag(first, "--host"), "pve.lan")
            compare(flag(first, "--port"), "8006")
            compare(flag(first, "--insecure"), "0")

            // --- state after the data arrived
            verify(panel.healthy)
            compare(panel.label, "3/4")            // 3 running of 4 non-template guests
            verify(panel.barTooltip.indexOf("3 of 4") !== -1)
            compare(panel.guestRows.map(function(g) { return g.vmid }), [100, 200, 201, 101])

            // --- opening resets the cursor and refreshes again
            var before = Quickshell.procs.length
            panel.open()
            wait(50)
            verify(Quickshell.procs.length > before, "open() refreshes")
            compare(panel.cursorActive, false)

            // --- first action key only reveals the cursor; nothing fires
            before = Quickshell.procs.length
            panel.handleKey("d")
            compare(panel.cursorActive, true)
            compare(Quickshell.procs.length, before)

            // --- graceful shutdown of vmid 100 goes to action.sh with the right args
            compare(panel.selectedGuest.vmid, 100)
            panel.handleKey("d")
            var p = lastProc()
            compare(p[1].split("/").pop(), "action.sh")
            compare(flag(p, "--op"), "shutdown")
            compare(flag(p, "--node"), "pve1")
            compare(flag(p, "--type"), "qemu")
            compare(flag(p, "--vmid"), "100")

            // --- force stop needs a second key press
            wait(20)
            var n = Quickshell.procs.length
            panel.handleKey("f")
            compare(panel.pendingConfirm, "stop:100")
            compare(Quickshell.procs.length, n, "no request on first x")
            panel.handleKey("f")
            compare(panel.pendingConfirm, "")
            compare(flag(lastProc(), "--op"), "stop")

            // --- moving the cursor cancels a pending confirmation
            panel.handleKey("f")
            compare(panel.pendingConfirm, "stop:100")
            panel.moveCursor(0, 1)
            compare(panel.pendingConfirm, "")
            compare(panel.selectedGuest.vmid, 200)

            // --- locked guest (201): only console is offered, power keys are refused
            panel.setRowCursor(2)
            compare(panel.selectedGuest.vmid, 201)
            compare(panel.selectedActions.map(function(a) { return a.op }), ["console"])
            n = Quickshell.procs.length
            panel.handleKey("d")
            compare(Quickshell.procs.length, n, "shutdown refused while locked")

            // --- stopped guest (101): start works, console/shutdown are refused
            panel.setRowCursor(3)
            compare(panel.selectedGuest.vmid, 101)
            n = Quickshell.procs.length
            Quickshell.execs = []
            panel.handleKey("c")
            panel.handleKey("d")
            compare(Quickshell.procs.length, n)
            compare(Quickshell.execs.length, 0)
            panel.handleKey("s")
            compare(flag(lastProc(), "--op"), "start")
            compare(flag(lastProc(), "--vmid"), "101")

            // --- console on a running guest opens the noVNC URL in the browser
            wait(20)
            panel.setRowCursor(0)
            panel.handleKey("c")
            var e = lastExec()
            compare(e[0], "omarchy-launch-browser")
            verify(e[1].indexOf("https://pve.lan:8006/?console=kvm&novnc=1&vmid=100") === 0, e[1])

            // --- the header's GitHub link opens the repository in the browser
            Quickshell.execs = []
            panel.openRepo()
            compare(lastExec(), ["omarchy-launch-browser", "https://github.com/thevideinfra/omaprox"])
            compare(panel.repoUrl, "https://github.com/thevideinfra/omaprox")

            // --- web UI + setup helpers
            panel.handleKey("o")
            compare(lastExec()[1], "https://pve.lan:8006/")
            panel.handleKey("t")
            e = lastExec()
            compare(e[0], "omarchy-launch-terminal")
            compare(e[2].split("/").pop(), "setup.sh")

            // --- Enter does the sensible default (console for running)
            Quickshell.execs = []
            panel.setRowCursor(0)
            panel.cursorActive = true
            panel.runOp("console")
            compare(Quickshell.execs.length, 1)

            // --- selection survives a refresh that reorders/changes rows
            panel.setRowCursor(3)
            compare(panel.selectedVmid, 101)
            panel.syncCursor()
            compare(panel.selectedGuest.vmid, 101)
        }

        function test_style_and_settings() {
            wait(300)
            // display settings default to normal and follow the setting
            compare(panel.density, "normal")
            compare(panel.densityScale, 0.71)
            compare(compactPanel.density, "compact")
            compare(compactPanel.densityScale, 0.61)
            verify(compactPanel.fontBody > 0)
            verify(compactPanel.fontBody !== panel.fontBody, "font size and density change the body font")

            // the bar pill is a glyph plus the running/total count, or the glyph alone
            compare(panel.barText, "󰒋 3/4")
            compare(quietPanel.barText, "󰒋")

            // the panel is about as wide and tall as tandem's, and smaller when compact
            verify(panel.panelWidth <= 240, "width " + panel.panelWidth)
            verify(panel.pagesMaxHeight <= 360, "pages height " + panel.pagesMaxHeight)
            verify(compactPanel.panelWidth <= panel.panelWidth)
            verify(compactPanel.pagesMaxHeight < panel.pagesMaxHeight)

            // the panel's own padding is well under the kit's default of 14, and follows density
            verify(panel.panelPadding <= 9, "padding " + panel.panelPadding)
            verify(panel.panelPadding >= 4, "padding " + panel.panelPadding)
            verify(compactPanel.panelPadding <= panel.panelPadding)

            // the pages use the full width, so the left and right margins match
            compare(findChild(panel, "pageFlick").width, findChild(panel, "headerBlock").width)
            compare(findChild(panel, "pageFlick").x, findChild(panel, "headerBlock").x)

            // the NODES section can be collapsed; the choice is kept in the settings
            compare(panel.nodesCollapsed, false)
            compare(collapsedPanel.nodesCollapsed, true)
            Quickshell.execs = []
            panel.toggleNodes()
            compare(lastExec(), ["omarchy", "bar", "set", "videinfra.omaprox", "nodesCollapsed", "true", "--json"])
            collapsedPanel.toggleNodes()
            compare(lastExec()[5], "false")

            // storage section is on unless switched off
            compare(panel.showStorage, true)
            compare(compactPanel.showStorage, false)

            // header: the name, the host under it (a link), and the counts live on the section labels
            compare(panel.title, "omaprox")
            tryCompare(panel, "statusLine", "pve.lan", 6000)   // an earlier test's action message may still be showing
            compare(panel.statusIsLink, true)
            compare(panel.guestsTag, "3/4 RUNNING")
            verify(/^[0-9]+\/[0-9]+ ONLINE$/.test(panel.nodesTag), "nodes tag: " + panel.nodesTag)
            // an action in progress replaces the host, and is not a link
            panel.setRowCursor(0)
            panel.runOp("reboot")
            verify(panel.statusLine !== "pve.lan", "the action's message replaces the host: " + panel.statusLine)
            compare(panel.statusIsLink, false)

            // the title and node names link to the web UI; the hint names where
            compare(panel.webUiHint, "Open pve.lan:8006 in the browser")

            // the settings view has a key reference
            verify(panel.keyRows.length >= 14, "key reference rows")
            compare(panel.keyRows[0].key, "S")

            // the version comes from manifest.json
            verify(/^[0-9]+\.[0-9]+\.[0-9]+/.test(panel.version), "version: " + panel.version)

            // choices save through omarchy bar set, as JSON
            Quickshell.execs = []
            panel.setSetting("density", "compact")
            compare(lastExec(), ["omarchy", "bar", "set", "videinfra.omaprox", "density", "\"compact\"", "--json"])
            panel.setSetting("hideStopped", true)
            compare(lastExec()[5], "true")
        }

        function test_inline_power_button() {
            wait(300)
            panel.open()
            wait(50)
            var running = panel.guestRows[0]
            var stopped = panel.guestRows[3]
            compare(running.vmid, 100)
            compare(stopped.vmid, 101)

            // running guest: the inline button is a graceful shutdown, no confirm
            compare(panel.powerOpFor(running), "shutdown")
            var n = Quickshell.procs.length
            panel.powerToggle(running)
            compare(Quickshell.procs.length, n + 1)
            compare(flag(lastProc(), "--op"), "shutdown")
            compare(flag(lastProc(), "--vmid"), "100")
            compare(panel.pendingConfirm, "")

            // stopped guest: start
            wait(20)
            compare(panel.powerOpFor(stopped), "start")
            panel.powerToggle(stopped)
            compare(flag(lastProc(), "--op"), "start")
            compare(flag(lastProc(), "--vmid"), "101")

            // clicking the button also selects its row
            compare(panel.selectedGuest.vmid, 101)

            // locked guest has no inline power button
            compare(panel.powerOpFor(panel.guestRows[2]), "")
            n = Quickshell.procs.length
            panel.powerToggle(panel.guestRows[2])
            compare(Quickshell.procs.length, n, "locked guest: nothing runs")
        }

        function test_expanded_row_actions() {
            wait(300)
            panel.setRowCursor(0)
            compare(panel.selectedGuest.vmid, 100)
            compare(panel.selectedRowActions.map(function(a) { return a.op }),
                    ["reboot", "spice", "snapshot", "stop"])
            panel.setRowCursor(3)
            compare(panel.selectedRowActions.map(function(a) { return a.op }), ["snapshot"])
        }

        function test_terminal_console_mode() {
            wait(300)
            compare(panel.consoleMode, "browser")
            compare(sshPanel.consoleMode, "terminal")

            // browser mode: Console opens the browser, never a terminal
            Quickshell.execs = []
            panel.setRowCursor(0)
            panel.runOp("console")
            compare(lastExec()[0], "omarchy-launch-browser")

            // terminal mode: Console runs ssh user@name.domain in a terminal
            Quickshell.execs = []
            sshPanel.setRowCursor(0)
            compare(sshPanel.selectedGuest.name, "web")
            sshPanel.runOp("console")
            compare(Quickshell.execs.length, 1)
            compare(lastExec(), ["omarchy-launch-terminal", "ssh", "ks@web.lan"])

            // SPICE key still goes to action.sh whatever the mode
            var n = Quickshell.procs.length
            sshPanel.runOp("spice")
            compare(flag(lastProc(), "--op"), "spice")
            verify(Quickshell.procs.length > n)
        }

        function test_pages() {
            wait(300)
            panel.showPage("guests")   // earlier tests may have left another tab showing
            compare(panel.pages.map(function(p) { return p.id }), ["guests", "keys", "settings"])
            compare(panel.page, "guests")

            // left/right (and stepPage) cycle through the tabs and wrap round
            panel.handleMove(1, 0)
            compare(panel.page, "keys")
            panel.stepPage(1)
            compare(panel.page, "settings")
            panel.stepPage(1)
            compare(panel.page, "guests")
            panel.stepPage(-1)
            compare(panel.page, "settings")

            // showPage picks a tab by id and refuses unknown ones (the IPC page command)
            compare(panel.showPage("settings"), true)
            compare(panel.page, "settings")
            compare(panel.showPage("nope"), false)
            compare(panel.page, "settings")
            panel.showPage("guests")

            // up/down only move the guest cursor on the Guests tab
            panel.page = "keys"
            panel.cursorActive = true
            panel.setRowCursor(0)
            panel.handleMove(0, 1)
            compare(panel.rowIndex, 0)
            panel.page = "guests"
            panel.handleMove(0, 1)
            compare(panel.rowIndex, 1)

            // guest action keys do nothing off the Guests tab
            panel.page = "settings"
            var n = Quickshell.procs.length
            panel.handleKey("s")
            panel.handleKey("d")
            compare(Quickshell.procs.length, n)

            // opening the panel always lands on Guests
            panel.page = "keys"
            panel.close()
            panel.open()
            wait(50)
            compare(panel.page, "guests")
        }

        function test_scroll_only_follows_the_keyboard() {
            wait(300)
            panel.close()
            panel.open()
            wait(100)
            compare(panel.page, "guests")
            compare(panel.pageScroll, 0)
            verify(panel.pageOverflows, "the guest list is taller than the page area in this test")

            // hovering a card (setRowCursor) must not scroll the page
            panel.setRowCursor(panel.guestRows.length - 1)
            wait(100)
            compare(panel.pageScroll, 0, "hover does not scroll")

            // moving with the keyboard does scroll the selection into view
            panel.cursorActive = true
            for (var i = 0; i < panel.guestRows.length; i++) panel.handleMove(0, 1)
            wait(100)
            verify(panel.pageScroll > 0, "keyboard scrolls to the last guest")

            // every tab starts at the top
            panel.showPage("keys")
            compare(panel.pageScroll, 0)
            panel.showPage("guests")
            compare(panel.pageScroll, 0)
        }

        function test_ssh_user_per_guest() {
            wait(300)
            function idx(name) {
                for (var i = 0; i < sshPanel.guestRows.length; i++)
                    if (sshPanel.guestRows[i].name === name) return i
                return -1
            }
            // effective user: the guest's override, else the default
            compare(sshPanel.sshUserOf(sshPanel.guestRows[idx("web")]), "ks")
            compare(sshPanel.sshUserOf(sshPanel.guestRows[idx("pihole")]), "admin")

            // Console uses it
            Quickshell.execs = []
            sshPanel.setRowCursor(idx("pihole"))
            sshPanel.runOp("console")
            compare(lastExec(), ["omarchy-launch-terminal", "ssh", "admin@pihole.lan"])

            // saving an override only stages it; Apply writes the whole map as JSON
            Quickshell.execs = []
            var n = Quickshell.procs.length
            var web = sshPanel.guestRows[idx("web")]
            compare(sshPanel.saveGuestSshUser(web, "bob"), true)
            compare(sshPanel.pending, 1)
            compare(sshPanel.dirty, true)
            compare(Quickshell.procs.length, n, "nothing is written until Apply")
            compare(Quickshell.execs.length, 0)
            // the box shows the pending value; Console keeps using the saved one
            compare(sshPanel.sshUserOf(web), "bob")
            sshPanel.setRowCursor(idx("web"))
            sshPanel.runOp("console")
            compare(lastExec(), ["omarchy-launch-terminal", "ssh", "ks@web.lan"])

            sshPanel.apply()
            compare(writesSince(n).length, 1)
            compare(writesSince(n)[0], ["omarchy", "bar", "set", "videinfra.omaprox", "sshUsers", "{\"pihole\":\"admin\",\"web\":\"bob\"}", "--json"])
            compare(sshPanel.pending, 0)
            compare(sshPanel.sshUserOf(web), "bob", "the applied value shows until the shell reloads")

            // a blank box stages the removal of the guest's override
            n = Quickshell.procs.length
            compare(sshPanel.saveGuestSshUser(sshPanel.guestRows[idx("pihole")], ""), true)
            compare(Quickshell.procs.length, n)
            sshPanel.apply()
            compare(writesSince(n).length, 1)
            compare(writesSince(n)[0][5], "{\"web\":\"bob\"}")

            // a bad name is refused and nothing is staged
            compare(sshPanel.saveGuestSshUser(web, "bad user"), false)
            compare(sshPanel.pending, 0)
        }

        function test_connection_fields() {
            wait(300)
            panel.revert()
            var n = Quickshell.procs.length
            Quickshell.execs = []
            // unchanged from what is saved: nothing is staged
            compare(sshPanel.commitField("sshUser", "ks"), true)
            compare(sshPanel.pending, 0)
            // valid changes are staged, not written
            compare(sshPanel.commitField("sshUser", "ops"), true)
            compare(sshPanel.commitField("sshDomain", ""), true)
            compare(sshPanel.commitField("port", "8007"), true)
            compare(sshPanel.commitField("host", "pve2.lan"), true)
            compare(sshPanel.pending, 4)
            compare(Quickshell.procs.length, n, "nothing is written until Apply")
            compare(sshPanel.fieldValue("sshUser", "ks"), "ops")
            // putting a field back to its saved value drops it from the pending list
            compare(sshPanel.commitField("sshUser", "ks"), true)
            compare(sshPanel.pending, 3)
            compare(sshPanel.commitField("sshUser", "ops"), true)
            compare(sshPanel.pending, 4)

            // Revert discards them all
            sshPanel.revert()
            compare(sshPanel.pending, 0)
            compare(sshPanel.fieldValue("sshUser", "ks"), "ks")

            // Apply writes each one, one after another, in the right type
            sshPanel.commitField("sshUser", "ops")
            sshPanel.commitField("port", "8007")
            sshPanel.commitField("host", "pve2.lan")
            n = Quickshell.procs.length
            sshPanel.apply()
            var written = writesSince(n)
            compare(written.length, 3)
            compare(written.map(function(c) { return c[4] }).sort(), ["host", "port", "sshUser"])
            for (var i = 0; i < written.length; i++) {
                compare(written[i].slice(0, 4), ["omarchy", "bar", "set", "videinfra.omaprox"])
                compare(written[i][6], "--json")
            }
            compare(written.filter(function(c) { return c[4] === "port" })[0][5], "8007")
            compare(written.filter(function(c) { return c[4] === "host" })[0][5], "\"pve2.lan\"")
            compare(sshPanel.pending, 0)
            compare(sshPanel.applying, false)
            compare(sshPanel.applyError, "")
            compare(sshPanel.fieldValue("host", "pve.lan"), "pve2.lan", "applied value shows until the shell reloads")
            sshPanel.revert()

            // bad values are refused and not staged
            compare(sshPanel.commitField("sshUser", "bad user"), false)
            compare(sshPanel.commitField("sshDomain", "-x"), false)
            compare(sshPanel.commitField("port", "99999"), false)
            compare(sshPanel.commitField("host", "bad host!"), false)
            compare(sshPanel.commitField("nope", "x"), false)
            compare(sshPanel.pending, 0)
        }

        function test_apply_failure_keeps_the_edits() {
            wait(300)
            panel.revert()
            compare(panel.commitField("sshDomain", "failme"), true)
            compare(panel.commitField("port", "8009"), true)
            panel.apply()
            compare(panel.applying, false)
            verify(panel.applyError.indexOf("sshDomain") !== -1, "error names the setting: " + panel.applyError)
            verify(panel.applyError.indexOf("boom") !== -1, "error carries the reason: " + panel.applyError)
            verify(panel.dirty, "edits stay staged so nothing is lost")
            verify(panel.bannerVisible)
            panel.revert()
            compare(panel.applyError, "")
            compare(panel.bannerVisible, false)
        }

        function test_banner_and_enter_apply() {
            wait(300)
            panel.revert()
            compare(panel.bannerVisible, false)
            panel.commitField("sshUser", "ops2")
            compare(panel.bannerVisible, true)
            compare(panel.pendingText, "1 pending")
            // Enter applies on the Settings tab only
            var n = Quickshell.procs.length
            panel.page = "guests"
            panel.cursorActive = false
            panel.activate()
            compare(writesSince(n).length, 0, "not on the Guests tab")
            panel.page = "settings"
            panel.activate()
            compare(writesSince(n).length, 1)
            compare(writesSince(n)[0][4], "sshUser")
            panel.revert()
            panel.page = "guests"
        }

        function test_typing_does_not_fire_shortcuts() {
            wait(300)
            panel.open()
            wait(50)
            panel.setRowCursor(0)
            panel.cursorActive = true
            compare(panel.editing, false)
            panel.editorFocus(panel, true)
            compare(panel.editing, true)
            var n = Quickshell.procs.length
            Quickshell.execs = []
            panel.handleKey("d")
            panel.handleKey("f")
            panel.handleKey("t")
            panel.handleKey("o")
            compare(Quickshell.procs.length, n, "no action while a field has focus")
            compare(Quickshell.execs.length, 0, "no setup/web UI while a field has focus")
            panel.editorFocus(panel, false)
            compare(panel.editing, false)
            // focus moving between two fields: the old one letting go must not clear the new one
            var other = Qt.createQmlObject('import QtQuick; Item {}', panel)
            panel.editorFocus(panel, true)
            panel.editorFocus(other, true)
            panel.editorFocus(panel, false)
            compare(panel.editing, true)
            panel.editorFocus(other, false)
            compare(panel.editing, false)
        }


        // Real key events through the real PanelKeyCatcher. As in tandem, an edit shows
        // up as pending the moment it is made, without pressing Enter.
        function openSettings() {
            sshPanel.recent = ({})   // a value applied by an earlier test, still shown until the shell reloads
            sshPanel.revert()
            sshPanel.close()
            sshPanel.open()
            sshPanel.showPage("settings")
            wait(100)
        }

        function test_an_edit_is_pending_as_you_type() {
            wait(300)
            openSettings()
            var box = findChild(sshPanel, "box-sshDomain")
            verify(box && box.visible, "domain box is visible on the Settings tab")
            box.forceActiveFocus()
            compare(sshPanel.editing, true, "focus in a box marks the panel as editing")
            compare(sshPanel.pending, 0)
            compare(sshPanel.bannerVisible, false)
            box.selectAll()
            keyClick("h")
            compare(sshPanel.pending, 1, "the first keystroke shows the banner")
            compare(sshPanel.bannerVisible, true)
            compare(sshPanel.pendingText, "1 pending")
            keyClick("x"); keyClick("l")
            compare(box.text, "hxl", "h, x and l reach the box, they are not taken as shortcuts")
            compare(sshPanel.fieldValue("sshDomain", "lan"), "hxl")
            box.selectAll()
            keyClick("h"); keyClick("o"); keyClick("m"); keyClick("e")
            compare(sshPanel.fieldValue("sshDomain", "lan"), "home")
            compare(sshPanel.pending, 1, "still one edit, not one per keystroke")

            // Enter only lets go of the box. It must not apply the edit.
            var n = Quickshell.procs.length
            keyClick(Qt.Key_Return)
            wait(50)
            compare(writesSince(n).length, 0, "Enter does not apply")
            compare(sshPanel.pending, 1)
            compare(box.activeFocus, false, "Enter lets go of the box")
            compare(sshPanel.editing, false)

            // typing the saved value back drops the edit and the banner
            box.forceActiveFocus()
            box.selectAll()
            keyClick("l"); keyClick("a"); keyClick("n")
            compare(sshPanel.pending, 0)
            compare(sshPanel.bannerVisible, false)
            sshPanel.revert()
        }

        function test_an_invalid_edit_is_flagged_and_not_pending() {
            wait(300)
            openSettings()
            var box = findChild(sshPanel, "box-sshUser")
            box.forceActiveFocus()
            box.selectAll()
            keyClick("o"); keyClick("p")
            compare(sshPanel.pending, 1)
            keyClick(";")
            compare(box.bad, true, "a semicolon is not a valid user name")
            compare(sshPanel.pending, 0, "an invalid edit is not left pending")
            keyClick(Qt.Key_Backspace)
            compare(box.bad, false)
            compare(sshPanel.pending, 1)
            sshPanel.revert()
        }

        function test_escape_puts_the_saved_value_back() {
            wait(300)
            openSettings()
            var box = findChild(sshPanel, "box-sshUser")
            box.forceActiveFocus()
            box.selectAll()
            keyClick("z"); keyClick("z")
            compare(sshPanel.pending, 1)
            keyClick(Qt.Key_Escape)
            compare(sshPanel.pending, 0)
            compare(box.text, "ks", "back to the saved user")
        }

        function test_a_guest_ssh_user_is_pending_as_you_type() {
            wait(300)
            sshPanel.revert()
            sshPanel.close()
            sshPanel.open()
            wait(100)
            compare(sshPanel.page, "guests")
            var web = null
            for (var i = 0; i < sshPanel.guestRows.length; i++)
                if (sshPanel.guestRows[i].name === "web") web = sshPanel.guestRows[i]
            sshPanel.expandedVmid = web.vmid
            wait(100)
            var box = findChild(sshPanel, "box-guest-web")
            verify(box && box.visible, "the guest's SSH box shows in its open card")
            compare(box.text, "ks")
            box.forceActiveFocus()
            box.selectAll()
            keyClick("b"); keyClick("o"); keyClick("b")
            compare(sshPanel.pending, 1)
            compare(sshPanel.sshUserOf(web), "bob")
            // blank goes back to the default and drops the edit
            box.selectAll()
            keyClick(Qt.Key_Backspace)
            compare(sshPanel.pending, 0)
            sshPanel.revert()
        }

        function test_more_below_hint() {
            wait(300)
            panel.close()
            panel.open()
            wait(100)
            // a page taller than the panel hints that there is more below, until the bottom
            verify(panel.pageOverflows)
            compare(panel.pageScroll, 0)
            compare(panel.moreBelow, true)
            // clicking the hint scrolls down a page at a time and never past the end
            var last = -1
            for (var i = 0; i < 20 && panel.moreBelow; i++) {
                panel.scrollMore()
                verify(panel.pageScroll > last, "it moves down")
                last = panel.pageScroll
            }
            compare(panel.moreBelow, false)
            compare(panel.pageOverflows, true)
            panel.scrollMore()
            compare(panel.pageScroll, last, "nothing past the bottom")
            // another tab starts at the top, with its own hint
            panel.showPage("keys")
            compare(panel.pageScroll, 0)
            compare(panel.moreBelow, panel.pageOverflows)
            panel.showPage("guests")
        }

        function test_inline_console_button() {
            wait(300)
            panel.showPage("guests")
            var web = panel.guestRows[0]
            var db = panel.guestRows[3]
            var locked = panel.guestRows[2]
            compare(web.name, "web")
            // running and locked-but-running guests can open a console, a stopped one cannot
            compare(panel.hasConsole(web), true)
            compare(panel.hasConsole(locked), true)
            compare(panel.hasConsole(db), false)

            // clicking the button opens the console for that card, in the chosen mode
            Quickshell.execs = []
            panel.openConsole(web)
            compare(lastExec()[0], "omarchy-launch-browser")
            compare(panel.selectedGuest.vmid, web.vmid, "it also selects the card")
            Quickshell.execs = []
            sshPanel.openConsole(sshPanel.guestRows[0])
            compare(lastExec(), ["omarchy-launch-terminal", "ssh", "ks@web.lan"])

            // a guest with no console does nothing
            Quickshell.execs = []
            panel.openConsole(db)
            compare(Quickshell.execs.length, 0)

            // the tooltip says what the click will do
            verify(panel.consoleTip(web).toLowerCase().indexOf("browser") !== -1, panel.consoleTip(web))
            verify(sshPanel.consoleTip(sshPanel.guestRows[0]).indexOf("ks@web.lan") !== -1, sshPanel.consoleTip(sshPanel.guestRows[0]))
        }
    }
}
