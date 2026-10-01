// Run with: node test/model.test.js
const assert = require("assert")
const M = require("../Model.js")

let passed = 0
function test(name, fn) {
    try { fn(); passed++ } catch (e) { console.error("FAIL:", name, "\n ", e.message); process.exitCode = 1 }
}

test("formatBytes", () => {
    assert.strictEqual(M.formatBytes(0), "0B")
    assert.strictEqual(M.formatBytes(1023), "1023B")
    assert.strictEqual(M.formatBytes(1024), "1.0K")
    assert.strictEqual(M.formatBytes(1.5 * 1024 ** 3), "1.5G")
    assert.strictEqual(M.formatBytes(12 * 1024 ** 3), "12G")
    assert.strictEqual(M.formatBytes(3 * 1024 ** 4), "3.0T")
    assert.strictEqual(M.formatBytes("garbage"), "0B")
})

test("formatUptime", () => {
    assert.strictEqual(M.formatUptime(0), "—")
    assert.strictEqual(M.formatUptime(42), "42s")
    assert.strictEqual(M.formatUptime(3700), "1h 1m")
    assert.strictEqual(M.formatUptime(86400 * 5 + 3600), "5d 1h")
})

test("usageLevel + fraction", () => {
    assert.strictEqual(M.usageLevel(0.5), "normal")
    assert.strictEqual(M.usageLevel(0.75), "warning")
    assert.strictEqual(M.usageLevel(0.9), "critical")
    assert.strictEqual(M.fraction(5, 0), 0)
    assert.strictEqual(M.fraction(200, 100), 1)
    assert.strictEqual(M.formatPercent(0.125), "13%")
})

test("hostParts", () => {
    assert.deepStrictEqual(M.hostParts("pve.lan", 8006), { host: "pve.lan", port: 8006 })
    assert.deepStrictEqual(M.hostParts("https://pve.lan:8007/", 8006), { host: "pve.lan", port: 8007 })
    assert.deepStrictEqual(M.hostParts("pve.lan:9000", 8006), { host: "pve.lan", port: 9000 })
    assert.deepStrictEqual(M.hostParts("[fe80::1]:8010", 8006), { host: "[fe80::1]", port: 8010 })
    assert.deepStrictEqual(M.hostParts("fe80::1", 8006), { host: "fe80::1", port: 8006 })
    assert.deepStrictEqual(M.hostParts("  ", "x"), { host: "", port: 8006 })
    assert.deepStrictEqual(M.hostParts("pve", 99999), { host: "pve", port: 8006 })
})

test("urls", () => {
    const parts = { host: "pve.lan", port: 8006 }
    assert.strictEqual(M.webUiUrl(parts), "https://pve.lan:8006/")
    assert.strictEqual(M.webUiUrl({ host: "fe80::1", port: 8006 }), "https://[fe80::1]:8006/")
    const url = M.consoleUrl(parts, { vmid: 100, name: "my vm&x", node: "pve1", type: "qemu" })
    assert.ok(url.startsWith("https://pve.lan:8006/?console=kvm&novnc=1&vmid=100"))
    assert.ok(url.includes("vmname=my%20vm%26x"))
    assert.ok(M.consoleUrl(parts, { vmid: 200, name: "ct", node: "pve1", type: "lxc" }).includes("console=lxc"))
})

const status = JSON.stringify({
    ok: true, installed: true, configured: true, statusText: "Connected", lastError: "", host: "pve",
    nodes: [{ name: "pve1", status: "online", cpu: 0.1, maxcpu: 8, mem: 1, maxmem: 2, uptime: 5 }],
    guests: [
        { vmid: 101, name: "db", type: "qemu", node: "pve1", status: "stopped", tags: "", lock: "", template: false },
        { vmid: 100, name: "web", type: "qemu", node: "pve1", status: "running", tags: "prod;web", lock: "", template: false },
        { vmid: 102, name: "tpl", type: "qemu", node: "pve1", status: "stopped", tags: "", lock: "", template: true },
        { vmid: 200, name: "pihole", type: "lxc", node: "pve1", status: "running", tags: "", lock: "", template: false },
        { vmid: 201, name: "busy", type: "lxc", node: "pve1", status: "running", tags: "", lock: "backup", template: false }
    ],
    storage: []
})

test("parseStatus happy path and failures", () => {
    const p = M.parseStatus(status)
    assert.ok(p.ok && p.configured)
    assert.strictEqual(p.guests.length, 5)
    assert.strictEqual(M.parseStatus("").ok, false)
    assert.strictEqual(M.parseStatus("not json").ok, false)
    assert.strictEqual(M.parseStatus("null").ok, false)
    const unconf = M.parseStatus('{"ok":true,"configured":false,"statusText":"No token"}')
    assert.strictEqual(unconf.configured, false)
    assert.deepStrictEqual(unconf.guests, [])
})

test("visibleGuests sorts running first and hides templates", () => {
    const g = M.parseStatus(status).guests
    assert.deepStrictEqual(M.visibleGuests(g, "", false, false).map(x => x.vmid), [100, 200, 201, 101])
    assert.deepStrictEqual(M.visibleGuests(g, "", true, false).map(x => x.vmid), [100, 200, 201])
    assert.strictEqual(M.visibleGuests(g, "", false, true).length, 5)
    assert.deepStrictEqual(M.visibleGuests(g, "PROD", false, false).map(x => x.vmid), [100])
    assert.deepStrictEqual(M.visibleGuests(g, "200", false, false).map(x => x.vmid), [200])
    assert.deepStrictEqual(M.visibleGuests(null, "", false, false), [])
})

test("summary ignores templates", () => {
    const p = M.parseStatus(status)
    const s = M.summary(p.nodes, p.guests)
    assert.deepStrictEqual(s, { nodesTotal: 1, nodesOnline: 1, total: 4, running: 3, stopped: 1 })
})

test("guestActions follow state", () => {
    const g = M.parseStatus(status).guests
    const byId = id => g.find(x => x.vmid === id)
    const ops = x => M.guestActions(x).map(a => a.op)
    assert.deepStrictEqual(ops(byId(100)), ["shutdown", "reboot", "console", "spice", "snapshot", "stop"])
    assert.deepStrictEqual(ops(byId(101)), ["start", "snapshot"])
    assert.deepStrictEqual(ops(byId(102)), [])
    assert.deepStrictEqual(ops(byId(201)), ["console"])
    assert.deepStrictEqual(ops(null), [])
    assert.deepStrictEqual(ops({ status: "paused", lock: "", template: false }), ["resume", "console", "stop"])
    assert.deepStrictEqual(ops({ status: "unknown", lock: "", template: false }), [])
})

test("force stop needs confirmation, others do not", () => {
    assert.strictEqual(M.ACTIONS.stop.confirm, true)
    assert.strictEqual(M.ACTIONS.shutdown.confirm, undefined)
    const running = M.parseStatus(status).guests[1]
    assert.strictEqual(M.findAction(running, "stop").confirm, true)
    assert.strictEqual(M.findAction(running, "start"), null)
})

test("keys are unique and map back to ops", () => {
    const keys = Object.keys(M.ACTIONS).map(k => M.ACTIONS[k].key)
    assert.strictEqual(new Set(keys).size, keys.length)
    for (const k of Object.keys(M.ACTIONS)) assert.strictEqual(M.opForKey(M.ACTIONS[k].key.toUpperCase()), k)
    assert.strictEqual(M.opForKey("z"), "")
    // keys reserved by the panel itself must not collide with actions
    for (const reserved of ["g", "o", "t"]) assert.strictEqual(M.opForKey(reserved), "")
    // PanelKeyCatcher takes these for itself (vim arrows, delete, space) and never
    // passes them on as text keys, so an action bound to one could not fire
    for (const taken of ["h", "j", "k", "l", "x", " "]) assert.strictEqual(M.opForKey(taken), "", "'" + taken + "' is taken by the key catcher")
})

test("defaultOp", () => {
    assert.strictEqual(M.defaultOp({ status: "stopped" }), "start")
    assert.strictEqual(M.defaultOp({ status: "running" }), "console")
    assert.strictEqual(M.defaultOp({ status: "paused" }), "resume")
    assert.strictEqual(M.defaultOp(null), "")
})

test("parseResult", () => {
    assert.deepStrictEqual(M.parseResult('{"ok":true,"message":"hi"}'), { ok: true, message: "hi" })
    assert.strictEqual(M.parseResult("nope").ok, false)
})

test("densityScale and fontSizeScale match the sibling plugins", () => {
    assert.strictEqual(M.densityScale("compact"), 0.61)
    assert.strictEqual(M.densityScale("normal"), 0.71)
    assert.strictEqual(M.densityScale("roomy"), 0.83)
    assert.strictEqual(M.densityScale("comfortable"), 0.83, "old name still works")
    assert.strictEqual(M.densityScale("bogus"), 0.71)
    assert.strictEqual(M.fontSizeScale("small"), 0.85)
    assert.strictEqual(M.fontSizeScale("normal"), 0.95)
    assert.strictEqual(M.fontSizeScale("large"), 1.07)
    assert.strictEqual(M.fontSizeScale(undefined), 0.95)
})

test("settingBool accepts booleans and their string forms", () => {
    assert.strictEqual(M.settingBool(true, false), true)
    assert.strictEqual(M.settingBool("true", false), true)
    assert.strictEqual(M.settingBool(false, true), false)
    assert.strictEqual(M.settingBool("false", true), false)
    assert.strictEqual(M.settingBool(undefined, true), true)
    assert.strictEqual(M.settingBool("maybe", false), false)
})

test("powerAction is the one-click start or graceful shutdown", () => {
    const op = g => { const a = M.powerAction(g); return a ? a.op : "" }
    assert.strictEqual(op({ status: "stopped", lock: "", template: false }), "start")
    assert.strictEqual(op({ status: "running", lock: "", template: false }), "shutdown")
    assert.strictEqual(op({ status: "paused", lock: "", template: false }), "resume")
    assert.strictEqual(op({ status: "stopped", lock: "backup", template: false }), "")
    assert.strictEqual(op({ status: "running", lock: "backup", template: false }), "")
    assert.strictEqual(op({ status: "stopped", lock: "", template: true }), "")
    assert.strictEqual(op({ status: "unknown", lock: "", template: false }), "")
    assert.strictEqual(op(null), "")
    assert.strictEqual(M.powerAction({ status: "running", lock: "", template: false }).confirm, undefined)
})

test("rowActions are the valid actions minus the inline power one", () => {
    const ops = g => M.rowActions(g).map(a => a.op)
    assert.deepStrictEqual(ops({ status: "running", lock: "", template: false }),
        ["reboot", "console", "spice", "snapshot", "stop"])
    assert.deepStrictEqual(ops({ status: "stopped", lock: "", template: false }), ["snapshot"])
    assert.deepStrictEqual(ops({ status: "paused", lock: "", template: false }), ["console", "stop"])
    // locked guest: console stays, nothing else
    assert.deepStrictEqual(ops({ status: "running", lock: "backup", template: false }), ["console"])
    assert.deepStrictEqual(ops(null), [])
})

test("guestGlyph tells VMs from containers", () => {
    assert.notStrictEqual(M.guestGlyph("qemu"), M.guestGlyph("lxc"))
    assert.strictEqual(M.guestLabel("lxc"), "CT")
    assert.strictEqual(M.guestLabel("qemu"), "VM")
})

test("consoleMode: explicit choice wins, preferSpice is the fallback", () => {
    assert.strictEqual(M.consoleMode("terminal", false), "terminal")
    assert.strictEqual(M.consoleMode("browser", true), "browser")
    assert.strictEqual(M.consoleMode("spice", false), "spice")
    assert.strictEqual(M.consoleMode(undefined, true), "spice")
    assert.strictEqual(M.consoleMode("", false), "browser")
    assert.strictEqual(M.consoleMode("bogus", true), "spice")
    assert.strictEqual(M.consoleMode(undefined, undefined), "browser")
})

test("sshTarget builds user@name[.domain] and refuses anything that could be an option", () => {
    const g = name => ({ name: name })
    assert.strictEqual(M.sshTarget(g("web"), "", ""), "root@web")
    assert.strictEqual(M.sshTarget(g("web"), "ks", "lan"), "ks@web.lan")
    assert.strictEqual(M.sshTarget(g("web"), "ks", ".lan"), "ks@web.lan")
    assert.strictEqual(M.sshTarget(g("Web-01.x"), "  ", "  "), "root@Web-01.x")
    assert.strictEqual(M.sshTarget(g("my vm"), "ks", ""), "")
    assert.strictEqual(M.sshTarget(g("-oProxyCommand=x"), "ks", ""), "")
    assert.strictEqual(M.sshTarget(g("web"), "-oProxyCommand=x", ""), "")
    assert.strictEqual(M.sshTarget(g("web"), "bad user", ""), "")
    assert.strictEqual(M.sshTarget(g("web"), "ks", "-bad"), "")
    assert.strictEqual(M.sshTarget(g("web;rm"), "ks", ""), "")
    assert.strictEqual(M.sshTarget(g(""), "ks", ""), "")
    assert.strictEqual(M.sshTarget(null, "ks", ""), "")
})

test("keyHelp lists every action key, derived from ACTIONS, plus the panel keys", () => {
    const rows = M.keyHelp()
    const keys = rows.map(r => r.key)
    assert.strictEqual(new Set(keys).size, keys.length, "no duplicate keys")
    for (const n of Object.keys(M.ACTIONS)) {
        const a = M.ACTIONS[n]
        const row = rows.find(r => r.key === a.key.toUpperCase())
        assert.ok(row, "row for " + n)
        assert.strictEqual(row.label, a.label)
        assert.ok(row.note.length > 0, "note for " + n)
    }
    for (const k of ["↑ ↓", "← →", "Enter", "G", "O", "T", "Esc"]) assert.ok(keys.includes(k), k)
    for (const r of rows) assert.ok(r.label.length > 0)
    // when-notes come from guestActions, not hand-written state lists
    assert.ok(rows.find(r => r.key === "S").note.startsWith("stopped"))
    assert.ok(rows.find(r => r.key === "D").note.startsWith("running"))
    assert.ok(rows.find(r => r.key === "U").note.startsWith("paused"))
    assert.ok(rows.find(r => r.key === "C").note.startsWith("running or paused"))
    assert.ok(rows.find(r => r.key === "F").note.includes("press twice"))
})

test("manifestVersion reads the version or gives an empty string", () => {
    assert.strictEqual(M.manifestVersion('{"id":"x","version":"1.2.3"}'), "1.2.3")
    assert.strictEqual(M.manifestVersion('{"id":"x"}'), "")
    assert.strictEqual(M.manifestVersion("not json"), "")
    assert.strictEqual(M.manifestVersion(""), "")
    assert.strictEqual(M.manifestVersion(undefined), "")
})

test("ssh user: override, then default, then root; bad values are refused", () => {
    const g = n => ({ name: n })
    assert.strictEqual(M.sshUserFor(g("web"), "", {}), "root")
    assert.strictEqual(M.sshUserFor(g("web"), "ks", {}), "ks")
    assert.strictEqual(M.sshUserFor(g("web"), "ks", { web: "bob" }), "bob")
    assert.strictEqual(M.sshUserFor(g("db"), "ks", { web: "bob" }), "ks")
    assert.strictEqual(M.sshUserFor(g("web"), " ks ", { web: "  " }), "ks")
    assert.strictEqual(M.sshUserFor(g("web"), "", undefined), "root")
    assert.strictEqual(M.sshUserFor(null, "ks", {}), "ks")
    // the override feeds sshTarget
    assert.strictEqual(M.sshTarget(g("web"), M.sshUserFor(g("web"), "ks", { web: "bob" }), "lan"), "bob@web.lan")

    assert.ok(M.validSshUser("ks") && M.validSshUser("a.b-c_d"))
    assert.ok(!M.validSshUser("") && !M.validSshUser("bad user") && !M.validSshUser("-o") && !M.validSshUser("a;b"))
    assert.ok(M.validDomain("") && M.validDomain("lan") && M.validDomain(".lan") && M.validDomain("home.example.com"))
    assert.ok(!M.validDomain("-x") && !M.validDomain("a b") && !M.validDomain("a;b"))
    assert.ok(M.validHost("pve.lan") && M.validHost("192.168.1.5") && M.validHost("[fe80::1]") && M.validHost("https://pve.lan:8006/"))
    assert.ok(!M.validHost("bad host!") && !M.validHost("a;b"))
    assert.ok(M.validPort("8006") && M.validPort(1) && !M.validPort("0") && !M.validPort("70000") && !M.validPort("x") && !M.validPort("80.5"))
})

test("setSshUser returns the updated override map, or refuses", () => {
    const base = { pihole: "admin" }
    let r = M.setSshUser(base, "web", "bob")
    assert.deepStrictEqual(r, { ok: true, map: { pihole: "admin", web: "bob" } })
    assert.deepStrictEqual(base, { pihole: "admin" }, "input is not mutated")
    assert.deepStrictEqual(M.setSshUser(base, "pihole", "").map, {}, "blank removes the override")
    assert.deepStrictEqual(M.setSshUser(base, "pihole", "  ").map, {})
    assert.strictEqual(M.setSshUser(base, "web", "bad user").ok, false)
    assert.deepStrictEqual(M.setSshUser(undefined, "web", "bob").map, { web: "bob" })
    assert.strictEqual(M.setSshUser(base, "", "bob").ok, false, "needs a guest name")
})

console.log(process.exitCode ? "model tests FAILED" : "model tests passed (" + passed + ")")
