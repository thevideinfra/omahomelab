// Pure logic for the Proxmox widget. No QML imports, so it also runs under node
// (see test/model.test.js). Written as plain ES5-style JS for the QML engine.

// ---------------------------------------------------------------- parsing

function toNumber(value, fallback) {
    var n = Number(value)
    return isFinite(n) ? n : (fallback === undefined ? 0 : fallback)
}

function asArray(value) {
    return Object.prototype.toString.call(value) === "[object Array]" ? value : []
}

function normalizeNode(n) {
    return {
        name: String(n.name || ""),
        status: String(n.status || "unknown"),
        cpu: toNumber(n.cpu), maxcpu: toNumber(n.maxcpu),
        mem: toNumber(n.mem), maxmem: toNumber(n.maxmem),
        uptime: toNumber(n.uptime)
    }
}

function normalizeGuest(g) {
    return {
        vmid: toNumber(g.vmid, -1),
        name: String(g.name || ("guest-" + g.vmid)),
        type: g.type === "lxc" ? "lxc" : "qemu",
        node: String(g.node || ""),
        status: String(g.status || "unknown"),
        cpu: toNumber(g.cpu), maxcpu: toNumber(g.maxcpu),
        mem: toNumber(g.mem), maxmem: toNumber(g.maxmem),
        uptime: toNumber(g.uptime),
        tags: String(g.tags || ""),
        lock: String(g.lock || ""),
        template: g.template === true
    }
}

function normalizeStorage(s) {
    return {
        name: String(s.name || ""),
        node: String(s.node || ""),
        shared: s.shared === true,
        used: toNumber(s.used), total: toNumber(s.total),
        status: String(s.status || "unknown")
    }
}

function parseStatus(raw) {
    var text = String(raw || "").trim()
    if (text === "")
        return { ok: false, lastError: "Empty response from the status helper" }
    var data
    try {
        data = JSON.parse(text)
    } catch (e) {
        return { ok: false, lastError: "Unreadable output from the status helper" }
    }
    if (!data || typeof data !== "object")
        return { ok: false, lastError: "Unexpected output from the status helper" }
    return {
        ok: data.ok !== false,
        installed: data.installed !== false,
        configured: data.configured === true,
        statusText: String(data.statusText || ""),
        lastError: String(data.lastError || ""),
        warning: String(data.warning || ""),
        host: String(data.host || ""),
        nodes: asArray(data.nodes).map(normalizeNode),
        guests: asArray(data.guests).map(normalizeGuest),
        storage: asArray(data.storage).map(normalizeStorage)
    }
}

function parseResult(raw) {
    try {
        var r = JSON.parse(String(raw || "").trim())
        return { ok: r.ok === true, message: String(r.message || "") }
    } catch (e) {
        return { ok: false, message: "Unreadable output from the action helper" }
    }
}

// ------------------------------------------------------------- formatting

function formatBytes(bytes) {
    var b = toNumber(bytes)
    if (b < 1024) return Math.round(b) + "B"
    var units = ["K", "M", "G", "T", "P"]
    var i = -1
    do {
        b /= 1024
        i++
    } while (b >= 1024 && i < units.length - 1)
    return (b < 10 ? b.toFixed(1) : String(Math.round(b))) + units[i]
}

function formatPercent(fraction) {
    return Math.round(toNumber(fraction) * 100) + "%"
}

function fraction(used, total) {
    var t = toNumber(total)
    if (t <= 0) return 0
    return Math.max(0, Math.min(1, toNumber(used) / t))
}

function formatUptime(seconds) {
    var s = Math.floor(toNumber(seconds))
    if (s <= 0) return "—"
    if (s < 60) return s + "s"
    var m = Math.floor(s / 60)
    if (m < 60) return m + "m"
    var h = Math.floor(m / 60)
    if (h < 24) return h + "h " + (m % 60) + "m"
    var d = Math.floor(h / 24)
    return d + "d " + (h % 24) + "h"
}

function usageLevel(f) {
    var x = toNumber(f)
    if (x >= 0.9) return "critical"
    if (x >= 0.75) return "warning"
    return "normal"
}

// ------------------------------------------------------------------ host

// Accepts "pve", "pve:8007", "https://pve:8006/", "[fe80::1]:8006", "192.168.1.5".
function hostParts(hostSetting, portSetting) {
    var h = String(hostSetting || "").trim()
    var port = Math.round(toNumber(portSetting, 8006))
    if (port < 1 || port > 65535) port = 8006
    h = h.replace(/^https?:\/\//i, "").replace(/\/.*$/, "")
    var m = h.match(/^\[([^\]]+)\](?::(\d+))?$/)
    if (m) return { host: "[" + m[1] + "]", port: m[2] ? Number(m[2]) : port }
    var first = h.indexOf(":")
    if (first !== -1 && first === h.lastIndexOf(":")) {
        var p = Number(h.substring(first + 1))
        h = h.substring(0, first)
        if (p >= 1 && p <= 65535) port = p
    }
    return { host: h, port: port }
}

function urlHost(parts) {
    var h = parts.host
    if (h.indexOf(":") !== -1 && h.charAt(0) !== "[") h = "[" + h + "]"
    return h + ":" + parts.port
}

function webUiUrl(parts) {
    return "https://" + urlHost(parts) + "/"
}

// noVNC console in the web UI. Needs a logged-in session in the browser.
function consoleUrl(parts, guest) {
    var kind = guest.type === "lxc" ? "lxc" : "kvm"
    return "https://" + urlHost(parts) + "/?console=" + kind + "&novnc=1"
        + "&vmid=" + encodeURIComponent(guest.vmid)
        + "&vmname=" + encodeURIComponent(guest.name)
        + "&node=" + encodeURIComponent(guest.node)
        + "&resize=off&cmd="
}

// --------------------------------------------------------------- guests

function statusRank(status) {
    if (status === "running") return 0
    if (status === "paused") return 1
    if (status === "stopped") return 2
    return 3
}

function visibleGuests(guests, nameFilter, hideStopped, showTemplates) {
    var needle = String(nameFilter || "").trim().toLowerCase()
    var out = asArray(guests).filter(function(g) {
        if (g.template && !showTemplates) return false
        if (hideStopped && g.status === "stopped") return false
        if (needle === "") return true
        var hay = (g.name + " " + g.vmid + " " + g.node + " " + g.tags).toLowerCase()
        return hay.indexOf(needle) !== -1
    })
    out.sort(function(a, b) {
        var r = statusRank(a.status) - statusRank(b.status)
        return r !== 0 ? r : a.vmid - b.vmid
    })
    return out
}

function summary(nodes, guests) {
    var real = asArray(guests).filter(function(g) { return !g.template })
    var running = real.filter(function(g) { return g.status === "running" }).length
    var online = asArray(nodes).filter(function(n) { return n.status === "online" }).length
    return {
        nodesTotal: asArray(nodes).length,
        nodesOnline: online,
        total: real.length,
        running: running,
        stopped: real.filter(function(g) { return g.status === "stopped" }).length
    }
}

// ------------------------------------------------------------- actions

// Keys must avoid h j k l x and space: the panel's key catcher takes those for
// itself (vim arrows, delete, activate) and never passes them on as text keys.
var ACTIONS = {
    start:    { op: "start",    key: "s", label: "Start",      glyph: "󰐊" },
    shutdown: { op: "shutdown", key: "d", label: "Shutdown",   glyph: "󰐥" },
    reboot:   { op: "reboot",   key: "r", label: "Reboot",     glyph: "󰑐" },
    resume:   { op: "resume",   key: "u", label: "Resume",     glyph: "󰐊" },
    console:  { op: "console",  key: "c", label: "Console",    glyph: "󰆍" },
    spice:    { op: "spice",    key: "v", label: "SPICE",      glyph: "󰍹" },
    snapshot: { op: "snapshot", key: "p", label: "Snapshot",   glyph: "󰄀" },
    stop:     { op: "stop",     key: "f", label: "Force stop", glyph: "󰓛", danger: true, confirm: true }
}

// What can sensibly be done to this guest right now, in display order.
function guestActions(g) {
    if (!g || g.template) return []
    var pick = function(names) {
        return names.map(function(n) { return ACTIONS[n] })
    }
    if (g.lock !== "")
        return g.status === "running" ? pick(["console"]) : []
    if (g.status === "running")
        return pick(["shutdown", "reboot", "console", "spice", "snapshot", "stop"])
    if (g.status === "paused")
        return pick(["resume", "console", "stop"])
    if (g.status === "stopped")
        return pick(["start", "snapshot"])
    return []
}

function findAction(g, op) {
    var list = guestActions(g)
    for (var i = 0; i < list.length; i++)
        if (list[i].op === op) return list[i]
    return null
}

function opForKey(key) {
    var k = String(key || "").toLowerCase()
    for (var name in ACTIONS)
        if (ACTIONS[name].key === k) return ACTIONS[name].op
    return ""
}

// What Enter does on the selected guest.
function defaultOp(g) {
    if (!g) return ""
    if (g.status === "stopped") return "start"
    if (g.status === "paused") return "resume"
    if (g.status === "running") return "console"
    return ""
}

// One-click power button on a guest row: start when stopped, graceful
// shutdown when running, resume when paused. Never the confirm-first stop.
function powerAction(g) {
    var list = guestActions(g)
    var want = g && g.status === "running" ? "shutdown"
        : (g && g.status === "paused" ? "resume" : (g && g.status === "stopped" ? "start" : ""))
    for (var i = 0; i < list.length; i++)
        if (list[i].op === want) return list[i]
    return null
}

// The inline Console button on a card, when the guest can open one.
function consoleAction(g) {
    return findAction(g, "console")
}

// What the open card still offers once the inline buttons have the power and console ops.
function rowActions(g) {
    var power = powerAction(g)
    return guestActions(g).filter(function(a) {
        return a.op !== "console" && (!power || a.op !== power.op)
    })
}

function guestGlyph(type) {
    return type === "lxc" ? "󰆧" : "󰢹"
}

function guestLabel(type) {
    return type === "lxc" ? "CT" : "VM"
}

// ---------------------------------------------------------- ssh settings

var SSH_USER_RE = /^[A-Za-z0-9_][A-Za-z0-9._-]*$/
var DOMAIN_LABEL_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/

function validSshUser(user) {
    return SSH_USER_RE.test(String(user || ""))
}

// Blank is fine (no domain); otherwise a hostname-like suffix, with or without a leading dot.
function validDomain(domain) {
    var d = String(domain || "").trim().replace(/^\.+/, "")
    return d === "" || DOMAIN_LABEL_RE.test(d)
}

// Same text the host setting accepts: a name, an address, host:port or a URL.
function validHost(text) {
    var h = hostParts(text, 8006).host
    return h !== "" && /^[\]\[A-Za-z0-9._:-]+$/.test(h)
}

function validPort(value) {
    var s = String(value === undefined || value === null ? "" : value).trim()
    if (!/^[0-9]+$/.test(s)) return false
    var n = Number(s)
    return n >= 1 && n <= 65535
}

// The user ssh logs in as: the guest's own override, else the default, else root.
function sshUserFor(guest, defaultUser, overrides) {
    var own = guest && overrides && typeof overrides === "object" ? overrides[guest.name] : ""
    own = String(own || "").trim()
    if (own !== "") return own
    var d = String(defaultUser || "").trim()
    return d !== "" ? d : "root"
}

// The override map with one guest's user set, or removed when blank. Never
// changes the map it is given. { ok: false } when the user or guest is no good.
function setSshUser(overrides, guestName, user) {
    var name = String(guestName || "")
    var u = String(user || "").trim()
    if (name === "" || (u !== "" && !validSshUser(u))) return { ok: false, map: overrides || {} }
    var map = {}
    var src = overrides && typeof overrides === "object" ? overrides : {}
    for (var k in src) if (k !== name) map[k] = src[k]
    if (u !== "") map[name] = u
    // keep a stable order: existing guests first, the edited one in place or last
    var ordered = {}
    for (var key in src) {
        if (key === name) { if (u !== "") ordered[key] = u }
        else ordered[key] = src[key]
    }
    if (u !== "" && !(name in ordered)) ordered[name] = u
    return { ok: true, map: ordered }
}

// ----------------------------------------------------------------- accent

// The theme palette colours that can stand in for the theme's own accent, in
// the order the picker shows them.
var ACCENT_NAMES = ["blue", "cyan", "green", "magenta", "yellow", "red", "orange"]

// name -> "#rrggbb" for every quoted hex colour in a theme's colors.toml.
function parsePalette(text) {
    var palette = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
        var m = lines[i].match(/^\s*([a-z_]+)\s*=\s*"(#[0-9a-fA-F]{6})"/)
        if (m) palette[m[1]] = m[2]
    }
    return palette
}

// "theme" followed by whichever accent colours the palette has.
function accentChoices(palette) {
    var list = ["theme"]
    for (var i = 0; i < ACCENT_NAMES.length; i++)
        if (palette && palette[ACCENT_NAMES[i]] !== undefined) list.push(ACCENT_NAMES[i])
    return list
}

// The palette colour for a choice, or null when the theme's own accent applies
// ("theme", or a colour this theme does not define).
function accentColor(choice, palette) {
    if (choice && choice !== "theme" && palette && palette[choice] !== undefined) return palette[choice]
    return null
}

// -------------------------------------------------------------- key help

var ACTION_NOTES = {
    shutdown: "graceful",
    console: "follows the console mode",
    spice: "always SPICE"
}

// Rows for the key reference in settings. Action rows come from ACTIONS and
// guestActions, so the list cannot drift from what the keys really do.
function keyHelp() {
    var rows = []
    for (var name in ACTIONS) {
        var a = ACTIONS[name]
        var states = ["stopped", "running", "paused"].filter(function(status) {
            return guestActions({ status: status, lock: "", template: false })
                .some(function(x) { return x.op === a.op })
        })
        var extra = a.confirm ? "press twice" : ACTION_NOTES[name]
        rows.push({
            key: a.key.toUpperCase(),
            label: a.label,
            note: states.join(" or ") + (extra ? " · " + extra : "")
        })
    }
    rows.push({ key: "↑ ↓", label: "Select a guest", note: "opens its row" })
    rows.push({ key: "← →", label: "Switch tabs", note: "Guests, Keys, Settings" })
    rows.push({ key: "Enter", label: "Default action", note: "start, console or resume" })
    rows.push({ key: "G", label: "Refresh", note: "" })
    rows.push({ key: "O", label: "Open the web UI", note: "" })
    rows.push({ key: "T", label: "Set up token and certificate", note: "opens a terminal" })
    rows.push({ key: "Esc", label: "Close the panel", note: "" })
    return rows
}

// The version in manifest.json text, or "" when it cannot be read.
function manifestVersion(text) {
    try {
        var v = JSON.parse(String(text || "")).version
        return v === undefined || v === null ? "" : String(v)
    } catch (e) {
        return ""
    }
}

// -------------------------------------------------------------- console

var CONSOLE_MODES = ["browser", "spice", "terminal"]

// Where Console opens. An explicit choice wins; the older preferSpice flag is the fallback.
function consoleMode(mode, preferSpice) {
    var m = String(mode || "")
    if (CONSOLE_MODES.indexOf(m) !== -1) return m
    return preferSpice === true || preferSpice === "true" ? "spice" : "browser"
}

// user@name[.domain] for ssh, or "" when any part could be read as an ssh option
// or host trick. The guest's name is the address, so it has to resolve.
function sshTarget(guest, user, domain) {
    if (!guest) return ""
    var u = String(user || "").trim() || "root"
    var d = String(domain || "").trim().replace(/^\.+/, "")
    var name = String(guest.name || "")
    var label = /^[A-Za-z0-9][A-Za-z0-9._-]*$/
    if (!/^[A-Za-z0-9_][A-Za-z0-9._-]*$/.test(u) || !label.test(name)) return ""
    if (d !== "" && !label.test(d)) return ""
    return u + "@" + name + (d !== "" ? "." + d : "")
}

// ----------------------------------------------------------- panel settings

// Spacing multiplier chosen in settings.
function densityScale(name) {
    if (name === "compact") return 0.61
    if (name === "roomy" || name === "comfortable") return 0.83
    return 0.71
}

// Text size multiplier chosen in settings, applied on top of the density's.
function fontSizeScale(name) {
    if (name === "small") return 0.85
    if (name === "large") return 1.07
    return 0.95
}

// Settings written from the panel arrive as booleans; hand-edited JSON may use strings.
function settingBool(value, fallback) {
    if (value === true || value === "true") return true
    if (value === false || value === "false") return false
    return fallback
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        parseStatus: parseStatus, parseResult: parseResult,
        formatBytes: formatBytes, formatPercent: formatPercent, formatUptime: formatUptime,
        fraction: fraction, usageLevel: usageLevel,
        hostParts: hostParts, urlHost: urlHost, webUiUrl: webUiUrl, consoleUrl: consoleUrl,
        visibleGuests: visibleGuests, summary: summary,
        guestActions: guestActions, findAction: findAction, opForKey: opForKey,
        defaultOp: defaultOp, powerAction: powerAction, rowActions: rowActions,
        consoleMode: consoleMode, sshTarget: sshTarget,
        validSshUser: validSshUser, validDomain: validDomain, validHost: validHost, validPort: validPort,
        sshUserFor: sshUserFor, setSshUser: setSshUser,
        keyHelp: keyHelp, parsePalette: parsePalette, accentChoices: accentChoices, accentColor: accentColor, manifestVersion: manifestVersion,
        consoleAction: consoleAction,
        guestGlyph: guestGlyph, guestLabel: guestLabel,
        densityScale: densityScale, fontSizeScale: fontSizeScale, settingBool: settingBool,
        ACTIONS: ACTIONS
    }
}
