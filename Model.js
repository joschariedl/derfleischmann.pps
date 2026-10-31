// Pure logic for the Power Profile Switcher widget.
// No Qt/QML dependencies — unit-testable under node.

// Nerd Font icons (supplementary plane — stored as String.fromCodePoint)
var _SAVER_ICON = String.fromCodePoint(0xF032A)   // leaf (power-saver)
var _BALANCED_ICON = String.fromCodePoint(0xF029A) // plug (balanced)
var _PERF_ICON = String.fromCodePoint(0xF04C5)     // plug-connected (performance)

var PROFILES = [
  { id: "power-saver", label: "Power Saver", shortLabel: "Saver", icon: _SAVER_ICON, barIcon: _SAVER_ICON },
  { id: "balanced", label: "Balanced", shortLabel: "Balance", icon: _BALANCED_ICON, barIcon: _BALANCED_ICON },
  { id: "performance", label: "Performance", shortLabel: "Perf", icon: _PERF_ICON, barIcon: _PERF_ICON }
]

var DEFAULT_PROFILE = "balanced"

// ---- power-profiles-daemon D-Bus access ----
//
// Read/write the active profile over D-Bus with `busctl` (systemd's C client)
// rather than `powerprofilesctl`, which is a PYTHON script.
//
// Why: `powerprofilesctl get` starts a CPython interpreter that imports gi and
// talks to the system bus. On exit it races its own GDBus worker thread, which
// can re-enter the interpreter after teardown and dereference a NULL
// `PyThreadState->interp` -> SIGSEGV (see coredump 220978, 2026-10-02). Polling
// it every 2s made that rare race actually fire. `busctl` is a plain C binary
// with no interpreter to tear down, so the crash cannot occur -- and it is ~50x
// cheaper (2ms vs 109ms per call, i.e. ~78 min/day of interpreter startup saved).
//
// Both commands are argv arrays: no shell, no quoting to get wrong.
var PPD_SERVICE = "org.freedesktop.UPower.PowerProfiles"
var PPD_PATH = "/org/freedesktop/UPower/PowerProfiles"
var PPD_IFACE = "org.freedesktop.UPower.PowerProfiles"

function getProfileCommand() {
  return ["busctl", "--system", "get-property", PPD_SERVICE, PPD_PATH, PPD_IFACE, "ActiveProfile"]
}

function setProfileCommand(profile) {
  return ["busctl", "--system", "set-property", PPD_SERVICE, PPD_PATH, PPD_IFACE, "ActiveProfile", "s", String(profile)]
}

function profileById(id) {
  for (var i = 0; i < PROFILES.length; i++)
    if (PROFILES[i].id === id) return PROFILES[i]
  return null
}

function profileIcon(id) {
  var p = profileById(id)
  return p ? p.icon : "\u2261"
}

function barIcon(id) {
  var p = profileById(id)
  return p ? p.barIcon : "\u2261"
}

function profileLabel(id) {
  var p = profileById(id)
  return p ? p.label : id
}

function isValidProfile(id) {
  return profileById(id) !== null
}

// Normalize raw profile output into a known profile id, or null if unknown.
// Accepts every shape the D-Bus clients print, so swapping the reader out
// cannot silently break the widget:
//   busctl get-property   ->  s "power-saver"
//   gdbus call ... Get    ->  (<'power-saver'>,)
//   powerprofilesctl get  ->  power-saver
function normalizeProfile(raw) {
  if (raw === null || raw === undefined) return null
  var text = String(raw).replace(/^\s+|\s+$/g, "")
  if (text === "") return null

  // busctl prefixes the value with its D-Bus type signature: `s "value"`.
  var signed = /^[a-z]+\s+"([^"]*)"$/.exec(text)
  if (signed) text = signed[1]

  // gdbus wraps the value in a returned tuple, optionally tagged with its
  // D-Bus type: `(<'v'>,)`, `('v',)` or bare `'v'`.
  var tuple = /^\(?<?'([^']*)'>?,?\)?$/.exec(text)
  if (tuple) text = tuple[1]

  return isValidProfile(text) ? text : null
}

// Cycle to the next profile in the list.
function nextProfile(current) {
  for (var i = 0; i < PROFILES.length; i++) {
    if (PROFILES[i].id === current) {
      return PROFILES[(i + 1) % PROFILES.length].id
    }
  }
  return DEFAULT_PROFILE
}

// Parse the JSON text produced by `hyprctl activewindow -j`.
// Returns { class, title, contentType } or null on failure.
function parseActiveWindow(json) {
  if (!json || typeof json !== "string") return null
  var text = json.replace(/^\s+|\s+$/g, "")
  if (text === "" || text === "null") return null
  try {
    var obj = JSON.parse(text)
    if (obj && typeof obj === "object" && ("class" in obj || "contentType" in obj))
      return {
        class: String(obj.class || ""),
        title: String(obj.title || ""),
        contentType: String(obj.contentType || "").toLowerCase()
      }
  } catch (e) {}
  return null
}

// Find the first matching app rule for a given window class.
// Rules are { appClass, profile } objects. Matching is case-insensitive
// substring — "steam" matches "Steam", "steam_app_1234", etc.
function findMatchingRule(appClass, rules) {
  if (!appClass || !rules) return null
  var lower = appClass.toLowerCase()
  for (var i = 0; i < rules.length; i++) {
    var ruleClass = String(rules[i].appClass || "").toLowerCase()
    if (ruleClass !== "" && lower.indexOf(ruleClass) !== -1) return rules[i]
  }
  return null
}

// General (list-free) game detection for when gameDetect is enabled but no
// explicit rule matches. It relies on two signals that do NOT require a curated
// title list:
//   1. Hyprland's `contentType` on the focused window — games launched via
//      gamescope / Steam Play register a "game" content type, which Hyprland
//      also uses for direct-scanout/VRR on game windows.
//   2. A classes/titles mentioning "gamescope" (the wrapper that hosts such
//      games) or a Prodec/game host surface.
// Any game that registers a "game" content type or appears as a gamescope
// surface is caught automatically. For a specific window that somehow falls
// through, add an EXPLICIT app rule instead (rules take priority).
function isGameClass(win) {
  if (!win) return false
  if (!win.contentType && !win.class && !win.title) return false

  // The clean, OS-level signal: Hyprland flags game surfaces with a game
  // content type (gamescope / Steam Play set this).
  if (win.contentType === "game") return true

  // Fallback: a gamescope-hosted window. Gamescope surfaces/interfaces mention
  // "gamescope" in the class/title even when contentType isn't populated.
  var lower = (String(win.class || "") + " " + String(win.title || "")).toLowerCase()
  return lower.indexOf("gamescope") !== -1
}

// General (list-free) detection of whether a Steam game is RUNNING, from the
// output of `ps -eo pid=,ppid=,comm=` (also works with `ps -eo pid,ppid,comm`).
// A game is running iff the Steam client's process tree contains any process
// whose executable is not one of Steam's own client-helper binaries. This
// matches any real game binary (native Steam game, Proton/Wine, etc.) without
// a curated game list — the only list is Steam's OWN processes.
var STEAM_HELPERS = {
  "steam": true,
  "steam-runtime-l": true,
  "steam-runtime": true,
  "steamwebhelper": true,
  "srt-bwrap": true,
  "pv-adverb": true,
  "pressure-vessel": true,
  "reaper": true,
  "steam.sh": true,
  "steam_proxy": true,
  "steamerrorreporter": true,
  "checksum": true,
  "gameoverlayui": true
}

function steamGameRunning(psOutput) {
  if (!psOutput) return false
  // Locate the Steam client root PID.
  var steamPid = null
  var procs = []
  var lines = String(psOutput).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var t = lines[i].trim()
    if (!t) continue
    var m = t.split(/\s+/)
    if (m.length < 3) continue
    var pid = Number(m[0]), ppid = Number(m[1]), name = m[2] || ""
    if (isNaN(pid) || isNaN(ppid)) continue
    procs.push({ pid: pid, ppid: ppid, name: name })
    if (name === "steam" || name === "steam.exe") steamPid = pid
  }
  if (!steamPid) return false // Steam not running

  // Build child map and mark descendants of the Steam root.
  var children = {}
  for (var j = 0; j < procs.length; j++) {
    var p = procs[j]
    if (!children[p.ppid]) children[p.ppid] = []
    children[p.ppid].push(p.pid)
  }
  var desc = {}
  var stack = [steamPid]
  while (stack.length) {
    var cur = stack.pop()
    var kids = children[cur] || []
    for (var k = 0; k < kids.length; k++) {
      if (desc[kids[k]]) continue
      desc[kids[k]] = true
      stack.push(kids[k])
    }
  }

  // Any descendant that isn't a Steam-owned helper => a game is running.
  for (var n = 0; n < procs.length; n++) {
    var pr = procs[n]
    if (pr.pid === steamPid) continue
    if (desc[pr.pid] && !Object.prototype.hasOwnProperty.call(STEAM_HELPERS, pr.name)) {
      if (pr.name !== "") return true
    }
  }
  return false
}

// Parent-agnostic Steam-game detection, from `ps -eo pid=,ppid=,comm=,args=`.
// The descendant-of-steam approach fails because Steam RE-PARENTS the actual
// game processes out of the steam client tree during sustained play (only the
// brief launch scaffold stays under steam). This instead anchors on the ONE
// signal Steam itself makes reliable: every Steam-launched game runs under a
// `reaper`/launch wrapper whose arguments contain `AppId=<id>`. Locating that
// wrapper by command line works no matter who parents the game, so it catches
// the whole game lifetime.
function steamGameRunningByArgs(psOutput) {
  if (!psOutput) return false
  var lines = String(psOutput).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (/SteamLaunch\s+AppId=[0-9]+/.test(line)) return true
    if (/AppId=[0-9]+/.test(line) && /reaper|steam-launch-wrapper|_v2-entry-point/.test(line)) return true
  }
  return false
}

// ---- App-rule persistence helpers ----

function parseRules(json) {
  if (!json || typeof json !== "string") return []
  var text = json.replace(/^\s+|\s+$/g, "")
  if (text === "" || text === "[]") return []
  try {
    var arr = JSON.parse(text)
    if (!Array.isArray(arr)) return []
    var out = []
    for (var i = 0; i < arr.length; i++) {
      var r = arr[i]
      if (r && typeof r === "object" && "appClass" in r && "profile" in r) {
        var ac = String(r.appClass || "").replace(/^\s+|\s+$/g, "")
        if (ac !== "") out.push({ appClass: ac, profile: String(r.profile || DEFAULT_PROFILE) })
      }
    }
    return out
  } catch (e) {
    return []
  }
}

function serializeRules(rules) {
  if (!rules || rules.length === 0) return "[]"
  return JSON.stringify(rules)
}

function addRule(rules, appClass, profile) {
  var trimmed = String(appClass || "").replace(/^\s+|\s+$/g, "")
  if (trimmed === "") return rules
  var updated = rules.slice()
  updated.push({ appClass: trimmed, profile: profile || DEFAULT_PROFILE })
  return dedupeRules(updated)
}

function removeRule(rules, index) {
  if (index < 0 || index >= rules.length) return rules
  var updated = rules.slice()
  updated.splice(index, 1)
  return updated
}

function dedupeRules(rules) {
  var seen = {}
  var out = []
  for (var i = 0; i < rules.length; i++) {
    var key = String(rules[i].appClass || "").toLowerCase()
    if (key === "" || seen[key]) continue
    seen[key] = true
    out.push(rules[i])
  }
  return out
}

if (typeof module !== "undefined") {
  module.exports = {
    PROFILES: PROFILES,
    DEFAULT_PROFILE: DEFAULT_PROFILE,
    profileById: profileById,
    profileIcon: profileIcon,
    barIcon: barIcon,
    profileLabel: profileLabel,
    isValidProfile: isValidProfile,
    normalizeProfile: normalizeProfile,
    getProfileCommand: getProfileCommand,
    setProfileCommand: setProfileCommand,
    nextProfile: nextProfile,
    parseActiveWindow: parseActiveWindow,
    findMatchingRule: findMatchingRule,
    isGameClass: isGameClass,
   steamGameRunning: steamGameRunning,
   steamGameRunningByArgs: steamGameRunningByArgs,
   // GPU-hold tuning. GPU_FLOOR_PCT: amdgpu utilization above which a detected
   // game is considered "actively gaming" (idle measured ~0-2%). Reads are
   // polled ~every 0.8s; GPU_IDLE_RELEASE_STREAK is the consecutive sub-floor
   // reads before releasing the performance hold for a paused game.
   GPU_FLOOR_PCT: 10,
   GPU_IDLE_RELEASE_STREAK: 6,
    parseRules: parseRules,
    serializeRules: serializeRules,
    addRule: addRule,
    removeRule: removeRule,
    dedupeRules: dedupeRules
  }
}
