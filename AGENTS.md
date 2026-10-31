# derfleischmann.pps — power-profile bar widget (Omarchy plugin)

Maintains the system power profile over D-Bus with three behaviors: manual
switching, per-app auto-switch rules, and game detection. This document
captures the architecture and hard-won pitfalls so future sessions can work
without re-deriving them.

## Files
- `manifest.json` — plugin manifest (id `derfleischmann.pps`, kind `bar-widget`).
- `BarWidget.qml` — the widget: bar icon, popup overlay, timers, processes, logic.
- `Model.js` — pure logic: profiles, icons, rules, window parsing. Node-testable
  (`node -e "const m=require('./Model.js'); ..."`).

## Key architecture
- **`currentProfile` is a MUTABLE runtime property**, not `readonly`. Seeded from
  the persisted setting; written optimistically by `applyProfile` for instant
  display feedback, and re-synced to the REAL system state by a poller reading
  the `ActiveProfile` D-Bus property via `busctl`. All display (icon, tooltip,
  popup, active highlight) reads this property.
- **`lastManualProfile`** is the restore target: the profile last chosen manually.
- `autoSwitched` + `autoSwitchTarget` are bookkeeping only (what the script last
  auto-applied); used to decide whether a restore is due and to cancel a pending
  restore if reality moved externally.

## Auto-switch flow
- System-profile poller: `busctl --system get-property …ActiveProfile` every 2s
  (always on) — keeps the icon synced with external changes.
- App poller: `hyprctl activewindow -j` every 800ms when `autoSwitch`/`gameDetect`
  is on. For the focused window (`parseActiveWindow` returns class/title/contentType):
  1. matching rule → apply that profile
  2. else game (via `isGameClass` OR `steamGameActive`) → force `performance`
  3. else if auto-switching was active → restore `lastManualProfile`
- Steam poller: `ps -eo pid=,ppid=,comm=,args=` every 800ms (same gate). Sets
  `steamGameActive` via `Model.steamGameRunningByArgs`; on a change it
  re-triggers the window poller so a Steam game start/stop switches/restores
  the profile without a focus change.
- **GPU "hold" (GPU boost only during a game, not a standalone trigger):** a
  `gpuBusyProc` poller reads the amdgpu card's `gpu_busy_percent` every 800ms
  (card resolved at runtime by scanning `/sys/class/drm/card*/` for the amdgpu
  driver — index varies across boots). The GPU is used ONLY to RELEASE the
  performance hold, never to switch performance on (Steam/window game detection
  switches on unconditionally — gating on GPU caused missed switches at launch
  when the GPU read was briefly idle). Behavior while a game is detected:
  GPU sub-floor for `GPU_IDLE_RELEASE_STREAK` (6) consecutive reads sets
  `gpuPaused`, restores `lastManualProfile`, and `handleAutoSwitch` returns
  early while `gpuPaused` (no re-assert); GPU `>= GPU_FLOOR_PCT` (10; idle reads
  ~0-2%) clears `gpuPaused` and re-asserts `performance`. When no game runs,
  `gpuPaused` is reset. GPU alone never warrants performance; only a busy GPU
  during an already-detected game re-engages it.
- **Game detection is GENERAL and LIST-FREE**, via TWO complementary signals, so
  no curated game-title list is needed:
  1. **Window content-type** (`Model.isGameClass(win)`): Hyprland's
     `contentType: "game"` (set by gamescope / Steam Play) falling back to a
     `gamescope` class/title match. Steam library UI/browsers/terminals are NOT
     matched.
  2. **Steam launch marker** (`Model.steamGameRunningByArgs(psOutput)` + the
     `steamGameProc` poller): every Steam game runs under a `reaper` wrapper
     whose command line contains `SteamLaunch AppId=<id>`. Matching that marker
     from `ps -eo pid=,ppid=,comm=,args=` is **parent-agnostic** and catches
     native Linux AND Proton/Windows Steam games (e.g. `CULTIC.exe` via
     `reaper SteamLaunch AppId=1684930`) that register no game content type and
     use no gamescope. Verified continuous across a full real play session.
   Both signals feed `handleAutoSwitch` through `steamGameActive`/`gpuPaused`
   so the profile switch and restore are coherent.
- `Model.steamGameRunning` (the OLD tree-walk detector) is retained but NOT used:
  it misses sustained play because **Steam re-parents the real game processes
  OUT of the steam client tree** (only the ~1-2s launch scaffold stays under
  steam). Do not switch back to it.
- Rules match `class` (WM_CLASS) case-insensitively, substring. Example values:
  `firefox`, `Steam`, `com.obsproject.Studio`. Look up with
  `hyprctl activewindow -j | jq -r '.class'`.

## Pitfalls (IMPORTANT — each caused a real bug)
1. **`PopupCard` cannot receive keyboard input for a TextField.** It's an xdg-popup;
   Qt only routes keys after a click routes focus through the parent surface. Use
   **`KeyboardPanel`** (layer-shell, `Exclusive`-prime keyboard focus) with a
   `PanelKeyCatcher{ blocked: ... }` whose `focusTarget` is the catcher, and
   `forceActiveFocus()` on the text field while editing. Stock reference:
   `weather/Panel.qml`, `clock/Panel.qml`.
2. **Never assign `null` to a QML `string` property** — must be `""`. A single
   occurrence crashes the whole `BarWidget.qml` silently (bar icon vanishes) with
   `Invalid property assignment: string expected`.
3. **Reliable Process restart:** to re-run a command that may still be in flight,
   do `proc.command = ...; if (proc.running) proc.running = false; proc.running = true;`
   (pattern from `Ui/MultiSelect.qml`). Only setting `running = true` when it's
   already running silently DROPS the new command — this caused auto-switch
   restores to be lost and the profile to stay stuck.
4. **Don't gate decisions on the slow polled value.** Base apply/restore decisions
   on optimistic `currentProfile`, let the poller confirm reality. Gating on the
   polled value caused stale-skip bugs.
5. **`RowLayout` needs `import QtQuick.Layouts`** for the popup's responsive rows.
6. **Nerd Font supplementary-plane icons** must use `String.fromCodePoint()`;
   plain `\u` only reads 4 hex digits. Icons: power-saver `U+F032A`, balanced
   `U+F029A`, performance `U+F04C5` (match stock `omarchy.power`).
7. **Never shell out to `powerprofilesctl` — it is a PYTHON script that
   segfaults on exit.** `powerprofilesctl get` starts CPython, imports `gi`, and
   talks to the system bus; on exit its GDBus worker thread can re-enter the
   interpreter after teardown and dereference a NULL `PyThreadState->interp`
   (`bind_gilstate_tstate`, `Python/pystate.c:330`). Confirmed on this machine:
   coredump 220978, 2026-10-02 18:25:13, `SIGSEGV` at address `0x1cd8`
   (= `offsetof(PyInterpreterState, runtime)`). The race is narrow, but polling
   every 2s (~43k calls/day) is enough to hit it, and each hit leaves a ~3 MB
   core. Use `busctl` (a C binary — no interpreter to tear down) via
   `Model.getProfileCommand()` / `Model.setProfileCommand()`. It is also ~50x
   cheaper: 2 ms vs 109 ms per call. Note that `normalizeProfile()` must then
   parse busctl's `s "profile"` output, not a bare profile id — it handles every
   client shape (see `Model.js`). Never reintroduce `bash -c "…"` wrappers for
   these: pass argv arrays.

## Reloading / verification
- Hot-reload a single plugin: `omarchy-shell shell rescanPlugins`.
- If a QML error is swallowed/ghost (bar icon gone, on-disk fix looks correct):
  the shell may serve a stale compiled component — **fully restart the shell**
  (`pkill -f "quickshell -n -p /usr/share/omarchy/shell"`; the
  `omarchy-launch-shell` wrapper relaunches it).
- Check for load errors: `journalctl --user | grep -iE "derfleischmann|failed"`.
- Validate Model.js: `node -e "const m=require('./Model.js'); /* test */"`.
- Verify registration: `omarchy-shell shell listPlugins`.

## Testing combo to sanity-check switching
Manual profile base × rule target × game detection × manual-override-during-auto
× rapid open→close→open should all converge to the correct profile. In
particular: set `power-saver` manually, open Firefox (rule → performance/balanced),
close it, confirm it restores to `power-saver` and the icon follows near-real-time.