import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

BarWidget {
  id: root
  moduleName: "derfleischmann.pps"

  // ---- Persisted settings
  readonly property string appRulesRaw: setting("appRules", "[]")
  readonly property bool autoSwitch: setting("autoSwitch", false)
  readonly property bool gameDetect: setting("gameDetect", false)
  readonly property string lastManualProfile: setting("lastManualProfile", Model.DEFAULT_PROFILE)
  readonly property var parsedRules: Model.parseRules(appRulesRaw)

  // ---- Transient state (not persisted)
  // currentProfile is the DISPLAYED / decision-base profile. It's not stored in
  // settings — it starts at the default, is written optimistically by
  // applyProfile (so the icon + logic react to our own actions immediately) and
  // re-synced to the REAL system state by the poller (so external changes and
  // the actual boot profile also show up).
  property string currentProfile: Model.DEFAULT_PROFILE
  property bool popupOpen: false
  property bool autoSwitched: false
  property string autoSwitchTarget: ""
  property bool addingRule: false
  property string newRuleAppClass: ""
  property string newRuleProfile: Model.DEFAULT_PROFILE
  // True while any Steam game process is running (list-free Steam-tree check).
  // Set by steamGameProc; consulted by handleAutoSwitch so games that don't
  // report a "game" content type (native/Proton titles, no gamescope) still
  // switch to performance.
  property bool steamGameActive: false
  // GPU-hold state: while a game is detected, gpuBusyPct reflects the latest
  // amdgpu utilization and gpuIdleStreak counts consecutive sub-floor reads.
  // A sustained idle streak lets handleAutoSwitch release performance for a
  // paused/suspended game instead of holding full clocks the whole run.
  property int gpuBusyPct: -1
  property int gpuIdleStreak: 0
  // True once the GPU-idle hold has been released (game treated as paused);
  // inhibits handleAutoSwitch from re-asserting performance until the GPU goes
  // busy again or the game ends.
  property bool gpuPaused: false

  readonly property string displayIcon: Model.barIcon(currentProfile)
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- Lifecycle

  function close() {
    popupOpen = false
  }

  function closeForPopoutSwitch() {
    popupOpen = false
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root, direction)
    return false
  }

  readonly property bool popoutSwitchClosing: false

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    for (var k in values) entry[k] = values[k]
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // ---- Profile switching

  function setProfile(profile) {
    if (!Model.isValidProfile(profile)) return
    applyProfile(profile)
    persistSettings({ lastManualProfile: profile })
    autoSwitched = false
    autoSwitchTarget = ""
  }

  function cycleProfile() {
    setProfile(Model.nextProfile(currentProfile))
  }

  // Applies a profile to the system. Optimistically updates the displayed
  // profile immediately (near-real-time feedback for our own actions); the
  // poller later confirms/corrects against the real system state.
  //
  // Reliable restart: the process is stopped then restarted every call, so a
  // rapid sequence of switches (e.g. rule A then restore B) never drops the
  // final command even if the previous one is still in flight — the last call
  // always wins.
  function applyProfile(profile) {
    if (!Model.isValidProfile(profile)) return
    if (currentProfile === profile) return
    currentProfile = profile
    setProfileProc.command = Model.setProfileCommand(profile)
    if (setProfileProc.running) setProfileProc.running = false
    setProfileProc.running = true
  }

  // Called by the system-profile poller. Re-syncs the displayed profile to the
  // REAL system state (picks up external changes too) and reconciles an
  // in-flight auto-switch restore if reality left our target.
  function applySystemProfile(profile) {
    if (!Model.isValidProfile(profile)) return
    if (profile === currentProfile) return
    currentProfile = profile

    // If the script had auto-switched and the system no longer reflects our
    // target (changed externally), stop expecting a restore to it.
    if (autoSwitched && autoSwitchTarget && profile !== autoSwitchTarget) {
      autoSwitched = false
      autoSwitchTarget = ""
    }
  }

  // ---- Auto-switch logic

  function toggleAutoSwitch() {
    var next = !root.autoSwitch
    persistSettings({ autoSwitch: next })
    if (!next) restoreManual()
  }

  function toggleGameDetect() {
    var next = !root.gameDetect
    persistSettings({ gameDetect: next })
    if (!next) restoreManual()
  }

  // Restore to the last manual profile if the system is currently on a profile
  // the script auto-applied. No-op if there's nothing to revert.
  function restoreManual() {
    if (!autoSwitched) return
    if (currentProfile === lastManualProfile) return
    autoSwitched = false
    autoSwitchTarget = ""
    applyProfile(lastManualProfile)
  }

  function startAddingRule() {
    addingRule = true
    newRuleAppClass = ""
    newRuleProfile = Model.DEFAULT_PROFILE
    Qt.callLater(function() { if (newRuleField) newRuleField.forceActiveFocus() })
  }

  function cancelAddingRule() {
    addingRule = false
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  function commitAddingRule() {
    var updated = Model.addRule(parsedRules, newRuleAppClass, newRuleProfile)
    persistSettings({ appRules: Model.serializeRules(updated) })
    addingRule = false
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
    reevaluateActiveWindow()
  }

  function removeRuleAt(index) {
    var updated = Model.removeRule(parsedRules, index)
    persistSettings({ appRules: Model.serializeRules(updated) })
    reevaluateActiveWindow()
  }

  function handleAutoSwitch(win) {
    if (!win) return

    var appClass = win.class
    var rule = appClass ? Model.findMatchingRule(appClass, parsedRules) : null
    if (rule) {
      autoSwitched = true
      autoSwitchTarget = rule.profile
      if (rule.profile !== currentProfile) applyProfile(rule.profile)
      return
    }

    if (gameDetect && (Model.isGameClass(win) || root.steamGameActive)) {
      // The GPU-idle hold is released (game paused) => don't re-assert
      // performance; stay on the restored profile until the GPU is busy again.
      if (root.gpuPaused) return
      // Switching on is UNCONDITIONAL: any detected game goes to performance
      // immediately. The GPU read does NOT gate the switch (that caused missed
      // switches when the GPU was briefly idle at launch). The GPU is used only
      // to RELEASE the hold later: gpuBusyProc does that, not this function.
      autoSwitched = true
      autoSwitchTarget = "performance"
      if (currentProfile !== "performance") applyProfile("performance")
      return
    }

    if (autoSwitched) {
      autoSwitched = false
      autoSwitchTarget = ""
      gpuPaused = false
      // Restore to the last manual profile whenever the system is currently
      // on the target the script applied (rather than some manual profile).
      if (currentProfile !== lastManualProfile) applyProfile(lastManualProfile)
    }
  }

  // Re-evaluate the current window against rules/games; used after a rule is
  // added/removed so a focused app picks up the change without waiting for the
  // next poll tick.
  function reevaluateActiveWindow() {
    if (!activeWindowProc.running) activeWindowProc.running = true
  }

  // ---- Processes

  Process {
    id: setProfileProc
    command: ["bash", "-c", "echo ok"]
    stdout: SplitParser {
      onRead: function(line) {}
    }
  }

  // Reads the ACTUAL system power profile. This is the source of truth for
  // what the display shows and what restore compares against — it also picks
  // up profile changes made outside this plugin (e.g. by power-profiles-daemon
  // or the stock panel), keeping the icon in sync.
  //
  // Reads the D-Bus property directly with `busctl` (C) rather than
  // `powerprofilesctl` (Python) — see the note in Model.js: the Python CLI
  // intermittently segfaults on exit and is ~50x slower per call.
  Process {
    id: systemProfileProc
    command: Model.getProfileCommand()
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySystemProfile(Model.normalizeProfile(text))
    }
  }

  Process {
    id: activeWindowProc
    command: ["hyprctl", "activewindow", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var win = Model.parseActiveWindow(text)
        if (win) root.handleAutoSwitch(win)
      }
    }
  }

// List-free Steam-game detection: watches for Steam's own game-launch marker.
// Steam launches every game through a `reaper` wrapper whose arguments contain
// `SteamLaunch AppId=<id>`. Matching on that command-line marker is
// parent-agnostic — it works because Steam re-parents the real game processes
// OUT of the steam client tree during sustained play (the tree walk missed
// that). This marker is present for the whole game lifetime (verified in a real
// Cultic session) and needs no curated game list. Runs only while
// autoSwitch/gameDetect is enabled.
  Process {
    id: steamGameProc
    command: ["ps", "-eo", "pid=,ppid=,comm=,args="]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var previous = root.steamGameActive
        root.steamGameActive = Model.steamGameRunningByArgs(text)
        // Re-evaluate the window on state change so a profile switch/restore
        // happens as soon as a Steam game starts or stops, not on the next
        // focus change.
        if (root.steamGameActive !== previous) {
          if (!activeWindowProc.running) activeWindowProc.running = true
        }
      }
    }
  }

  // Reads current amdgpu utilization (0-100%) from the GPU's sysfs node. The
  // card index can vary across boots, so the card is resolved at runtime by
  // scanning for the one bound to the amdgpu driver. Only consulted while a
  // game is detected (see handleAutoSwitch); it drives the "active vs paused"
  // performance hold.
  Process {
    id: gpuBusyProc
    // Command resolves the amdgpu card at runtime (card index varies across
    // boots) and prints its gpu_busy_percent, or -1 if no amdgpu card is found.
    command: ["sh", "-c", "for c in /sys/class/drm/card*/device/gpu_busy_percent; do [ -r \"$c\" ] && grep -q amdgpu /sys/class/drm/$(basename $(dirname $(dirname $c)))/device/uevent 2>/dev/null && { cat \"$c\"; exit 0; }; done; echo -1"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var pct = parseInt(text.trim(), 10)
        if (isNaN(pct)) pct = -1
        root.gpuBusyPct = pct
        if (pct >= 0 && pct < Model.GPU_FLOOR_PCT) root.gpuIdleStreak++
        else root.gpuIdleStreak = 0

        var gameRunning = root.steamGameActive
        if (!gameRunning) {
          // Game ended: clear any pause state so the next launch starts clean.
          root.gpuPaused = false
          return
        }
        if (pct >= 0 && pct >= Model.GPU_FLOOR_PCT) {
          // GPU busy => actively gaming. If we were paused (hold released),
          // re-assert performance.
          if (root.gpuPaused) {
            root.gpuPaused = false
            root.autoSwitched = false
            root.autoSwitchTarget = ""
          }
          if (root.currentProfile !== "performance") applyProfile("performance")
          return
        }
        // GPU idle. Once sustained long enough, treat the game as paused and
        // release the performance hold directly (handleAutoSwitch stays halted
        // via gpuPaused until the GPU is busy again).
        if (root.gpuIdleStreak >= Model.GPU_IDLE_RELEASE_STREAK && !root.gpuPaused) {
          root.gpuPaused = true
          root.autoSwitched = false
          root.autoSwitchTarget = ""
          if (root.currentProfile !== lastManualProfile) applyProfile(lastManualProfile)
        }
      }
    }
  }

  // ---- System-profile polling — runs always so the displayed icon tracks
  //      the REAL profile even when changed outside this plugin. Short delay
  //      first run so the shell bindings have settled.
  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: {
      if (!systemProfileProc.running) systemProfileProc.running = true
    }
  }

  Timer {
    interval: 150
    running: true
    repeat: false
    onTriggered: {
      if (!systemProfileProc.running) systemProfileProc.running = true
    }
  }

  // ---- Auto-switch polling — runs whenever the feature is enabled,
  //      regardless of whether the popup is open. Short interval so window
  //      switches are picked up close to real-time.
  Timer {
    interval: 800
    running: root.autoSwitch || root.gameDetect
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!activeWindowProc.running) activeWindowProc.running = true
    }
  }

  // ---- Steam-game polling — same cadence, only while the feature is on.
  Timer {
    interval: 800
    running: root.autoSwitch || root.gameDetect
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!steamGameProc.running) steamGameProc.running = true
    }
  }

  // ---- GPU-utilization polling — same cadence. Only meaningful while a game
  //      is detected; drives whether the performance hold is kept (active) or
  //      released (paused/idle).
  Timer {
    interval: 800
    running: root.autoSwitch || root.gameDetect
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      if (!gpuBusyProc.running) gpuBusyProc.running = true
    }
  }

  // ---- Bar widget

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.displayIcon
    tooltipText: Model.profileLabel(root.currentProfile)

    onPressed: function(b) {
      if (b === Qt.RightButton) root.cycleProfile()
      else root.popupOpen = !root.popupOpen
    }
  }

  // ---- Compact overlay anchored to the bar icon.
  //      Uses KeyboardPanel (not PopupCard) so the TextField gets real
  //      keyboard focus — xdg-popups only receive keys after a click routes
  //      focus through their parent surface, which breaks text input here.
  KeyboardPanel {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.popupOpen
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(300))
    contentHeight: popup.fittedContentHeight(contentCol.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.addingRule
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
      id: contentCol
      anchors.fill: parent
      spacing: Style.space(8)

      // ---- Header: current profile
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(8)

        Text {
          anchors.baseline: headerLabel.baseline
          text: Model.profileIcon(root.currentProfile)
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.iconLarge
        }

        Text {
          id: headerLabel
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          text: Model.profileLabel(root.currentProfile).toUpperCase()
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }

        Text {
          visible: root.autoSwitched
          anchors.verticalCenter: parent.verticalCenter
          text: "\u21C4"
          color: Color.accent
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body

          PanelToolTip {
            visible: autoIconMouse.containsMouse
            text: "Auto-switched \u2014 will revert when app closes"
            fontFamily: root.contentFontFamily
          }

          MouseArea {
            id: autoIconMouse
            anchors.fill: parent
            hoverEnabled: true
          }
        }
      }

      // ---- Profile buttons
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(4)

        Repeater {
          model: Model.PROFILES

          Rectangle {
            required property var modelData
            property bool isActive: modelData.id === root.currentProfile
            property bool isHovered: btnMouse.containsMouse

            width: Style.space(72)
            height: Style.spacing.controlHeight
            radius: Style.cornerRadius
            color: isActive
              ? Style.controlFill(root.contentForeground)
              : isHovered
                ? Style.hoverFillFor(root.contentForeground, Color.accent)
                : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.06)
            border.width: isActive ? 0 : Style.spacing.hairline
            border.color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

            Row {
              anchors.centerIn: parent
              spacing: Style.space(4)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.icon
                color: isActive ? Color.accent : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.icon
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: modelData.shortLabel
                color: isActive ? Color.accent : Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: isActive
              }
            }

            MouseArea {
              id: btnMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.setProfile(modelData.id)
            }
          }
        }
      }

      // ---- Auto-switch toggle
      RowLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(4)
        anchors.rightMargin: Style.space(4)
        spacing: Style.space(6)

        Text {
          Layout.alignment: Qt.AlignVCenter
          text: "\u21C4"
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.icon
        }

        Text {
          id: autoLabel
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignVCenter
          textFormat: Text.PlainText
          text: "Auto-Switching"
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        ToggleSwitch {
          id: autoToggle
          Layout.alignment: Qt.AlignVCenter
          checked: root.autoSwitch
          onToggled: root.toggleAutoSwitch()
        }

        MouseArea {
          Layout.fillWidth: true
          Layout.fillHeight: true
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.toggleAutoSwitch()
        }
      }

      // ---- App rules (visible when auto-switch is on)
      Column {
        visible: root.autoSwitch
        width: parent.width
        spacing: Style.space(4)

        // Rules header
        Item {
          width: parent.width
          height: Style.spacing.controlHeight

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "RULES"
            color: Qt.darker(root.contentForeground, 1.5)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.letterSpacing: 1
            font.bold: true
          }

          PanelActionButton {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "+"
            tooltipText: "Add rule"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            onClicked: root.startAddingRule()
          }
        }

        // Existing rules
        Repeater {
          model: root.parsedRules

          Rectangle {
            required property var modelData
            required property int index

            width: parent.width
            height: Style.spacing.popupRowHeight
            radius: Style.cornerRadius
            color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.05)

            Row {
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(4)
              spacing: Style.space(4)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: modelData.appClass
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
                width: parent.width - arrowCol.width - removeBtn.width - Style.space(16)
              }

              Row {
                id: arrowCol
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "\u2192"
                  color: Qt.darker(root.contentForeground, 1.8)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  textFormat: Text.PlainText
                  text: Model.profileLabel(modelData.profile)
                  color: Color.accent
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
              }

              PanelActionButton {
                id: removeBtn
                anchors.verticalCenter: parent.verticalCenter
                iconText: "\u2715"
                tooltipText: "Remove"
                foreground: root.contentForeground
                fontFamily: root.contentFontFamily
                onClicked: root.removeRuleAt(index)
              }
            }
          }
        }

        // Add-rule row
        Rectangle {
          visible: root.addingRule
          width: parent.width
          height: visible ? Style.spacing.controlHeight : 0
          radius: Style.cornerRadius
          color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.06)
          border.width: Style.spacing.hairline
          border.color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.15)

          RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Style.space(6)
            anchors.rightMargin: Style.space(4)
            spacing: Style.space(3)

            TextField {
              id: newRuleField
              Layout.fillWidth: true
              Layout.fillHeight: true
              Layout.alignment: Qt.AlignVCenter
              verticalPadding: Style.spacing.xxs
              text: root.newRuleAppClass
              onTextChanged: root.newRuleAppClass = text
              placeholderText: "app class (e.g. firefox)"
              foreground: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall

              onAccepted: root.commitAddingRule()
              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Escape) { root.cancelAddingRule(); event.accepted = true }
                else if (event.key === Qt.Key_Tab) { root.commitAddingRule(); event.accepted = true }
              }
            }

            RowLayout {
              id: ruleProfileRow
              Layout.alignment: Qt.AlignVCenter
              spacing: Style.space(1)

              Repeater {
                model: Model.PROFILES

                Rectangle {
                  required property var modelData
                  property bool isRuleSelected: modelData.id === root.newRuleProfile

                  width: Style.space(22)
                  height: Style.space(22)
                  radius: Style.cornerRadius
                  color: isRuleSelected ? Color.accent : "transparent"
                  border.width: isRuleSelected ? 0 : Style.spacing.hairline
                  border.color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.15)

                  Text {
                    anchors.centerIn: parent
                    text: modelData.icon
                    color: isRuleSelected ? "#ffffff" : root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.newRuleProfile = modelData.id
                  }
                }
              }
            }

            PanelActionButton {
              id: commitRuleBtn
              Layout.alignment: Qt.AlignVCenter
              iconText: "\u2713"
              tooltipText: "Add"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onClicked: root.commitAddingRule()
            }

            PanelActionButton {
              id: cancelRuleBtn
              Layout.alignment: Qt.AlignVCenter
              iconText: "\u2715"
              tooltipText: "Cancel"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onClicked: root.cancelAddingRule()
            }
          }
        }

        // Empty state
        Text {
          visible: root.parsedRules.length === 0 && !root.addingRule
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          text: "No rules yet. + to add."
          color: Qt.darker(root.contentForeground, 1.8)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.caption
          topPadding: Style.space(2)
          bottomPadding: Style.space(2)
        }
      }

      // ---- Game detection toggle
      RowLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: Style.space(4)
        anchors.rightMargin: Style.space(4)
        spacing: Style.space(6)

        Text {
          Layout.alignment: Qt.AlignVCenter
          text: "\uec17"
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.icon
        }

        Text {
          id: gameLabel
          Layout.fillWidth: true
          Layout.alignment: Qt.AlignVCenter
          textFormat: Text.PlainText
          text: "Game-Detection"
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        ToggleSwitch {
          id: gameToggle
          Layout.alignment: Qt.AlignVCenter
          checked: root.gameDetect
          onToggled: root.toggleGameDetect()
        }

        MouseArea {
          Layout.fillWidth: true
          Layout.fillHeight: true
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.toggleGameDetect()
        }
      }
      }
    }
  }
}
