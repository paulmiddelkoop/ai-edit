import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "components"

// Draws only: rewrites go through Service.qml, everything else is a call into
// bin/ai-edit.
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string aiEditBin: decodeURIComponent(String(Qt.resolvedUrl("bin/ai-edit")).replace(/^file:\/\//, ""))

  property bool opened: false
  // pick, busy, diff or error
  property string mode: "pick"
  property var actions: []
  property var config: ({})
  property bool compose: true
  // Nothing to paste over: compose mode has no window, a terminal's
  // selection is only a highlight (a paste would land at the cursor), and
  // text selected outside a text field cannot be replaced at all. The
  // result is copied instead.
  property bool copyOnly: true
  property bool promptOpen: false
  property string busyLabel: ""
  // The actions applied so far: a letter in the result runs the next one on
  // that result, so "improve, then translate" is two steps rather than a
  // combined action.
  property var steps: []
  // What the next step works on and the steps that produced it; kept apart
  // from the mode so a failed step can be retried on the same text.
  property string chainInput: ""
  property var doneSteps: []
  property bool chaining: false
  property bool promptOnResult: false
  // The results before the one shown, so Backspace goes back a step.
  property var history: []
  property string shownLabel: ""
  // After a result the actions are hidden; ? brings them back for a next
  // step on that result.
  property bool showNext: false
  // The selection bar in the action list. On a result it stays off until an
  // arrow key or the pointer moves it, so Enter keeps pasting.
  property int selectedIndex: 0
  property bool cursorActive: false
  property point lastPointer: Qt.point(-1, -1)
  // The running action asked for its result rather than a diff ("diff":
  // false, as for translations).
  property bool runWantsResult: false
  // config.compact hides the actions and the key hints once their letters
  // are known; the letters keep working and ? shows everything again.
  property bool expanded: true
  property bool pasteWhenDone: false
  property var segments: []
  property string errorText: ""
  property int runId: 0

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color accent: Color.accent
  property color inserted: "#a6e3a1"
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int contentSpacing: Style.spacing.md
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int cardWidth: Math.min(Style.space(config.width || 560), panel.width - Style.gapsOut * 2)
  property int textMaxHeight: Math.round(panel.height * 0.4)
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  property var selectedBorderSpec: Border.surfaceSpec("menu", "selected-border", Color.menu.selectedBorder, 0)
  readonly property int actionRowHeight: Math.max(Style.space(50), Style.font.body + Style.spacing.rowPaddingX * 2)
  readonly property int actionRowPeek: Math.round(root.actionRowHeight * 0.55)

  function open(payloadJson) {
    root.opened = true
    root.mode = "pick"
    root.promptOpen = false
    root.segments = []
    root.steps = []
    root.chainInput = ""
    root.doneSteps = []
    root.history = []
    root.chaining = false
    root.promptOnResult = false
    root.errorText = ""
    editor.text = ""
    root.selectedIndex = 0
    root.cursorActive = true
    actionScroll.contentY = 0
    themeColors.reload()
    stateProc.running = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // A comparison still running belongs to an older run; it is stopped, and
  // each run gets its own process, so its run number cannot change under it.
  property var compares: []
  function stopCompares() {
    for (var i = 0; i < root.compares.length; i++)
      if (root.compares[i].running) root.compares[i].running = false
  }

  function close() {
    root.opened = false
    root.runId++
    runProc.running = false
    root.stopCompares()
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "ai-edit")
  }

  function loadState(raw) {
    var state
    try { state = JSON.parse(raw) } catch (e) {
      root.fail("AI Edit could not read its state")
      return
    }
    root.config = state.config || {}
    root.actions = state.actions || []
    root.expanded = root.config.compact !== true
    var service = root.shell && typeof root.shell.serviceFor === "function" ? root.shell.serviceFor("ai-edit") : null
    if (service)
      service.keepWarm([root.config.model].concat(root.actions.map(function(a) { return a.model })),
        root.config.idle_timeout, root.config.agent, root.config.fast)
    var session = state.session || {}
    root.compose = session.source !== "selection"
    root.copyOnly = root.compose || session.terminal === true || session.editable === "no"
    editor.text = session.text || ""
    if (root.compose) editor.forceActiveFocus()
    else keyCatcher.forceActiveFocus()
  }

  function actionForKey(letter) {
    for (var i = 0; i < root.actions.length; i++)
      if (root.actions[i].key === letter) return root.actions[i]
    return null
  }

  readonly property var rows: root.actionForKey("c") !== null ? root.actions
    : root.actions.concat([{ key: "c", label: "Custom prompt…", custom: true }])

  function activateRow(index, shift) {
    var row = root.rows[index]
    if (!row) return
    if (row.custom) root.handleKey({ key: Qt.Key_C, modifiers: 0 })
    else root.runAction(row, shift)
  }

  function moveCursor(delta) {
    var last = root.rows.length - 1
    if (last < 0) return
    var index = root.cursorActive ? root.selectedIndex + delta : (delta < 0 ? last : 0)
    root.selectedIndex = Math.max(0, Math.min(last, index))
    root.cursorActive = true
    actionScroll.ensureVisible(root.selectedIndex)
  }

  // Rows scrolling under a pointer that stands still must not move the bar.
  function pointAt(index, position) {
    if (position.x === root.lastPointer.x && position.y === root.lastPointer.y) return
    root.lastPointer = position
    root.selectedIndex = index
    root.cursorActive = true
  }

  function runAction(action, shift) {
    var preview = action.preview !== false
    if (shift) preview = !preview
    root.runWantsResult = action.diff === false
    root.startRun(action.id, action.label || action.id, action.instruction, action.model, !preview)
  }

  function runPrompt(instruction, shift) {
    if (!instruction.trim()) return
    // A free instruction is usually a bigger change (shorter, another tone),
    // where a diff is mostly red and green.
    root.runWantsResult = true
    var preview = root.config.preview !== false
    if (shift) preview = !preview
    var label = instruction.trim().replace(/\s+/g, " ")
    root.startRun("-", label.charAt(0).toUpperCase() + label.slice(1), instruction, root.config.model, !preview)
  }

  function startRun(id, label, instruction, model, paste) {
    if (root.mode === "busy") return
    var chain = root.doneSteps.length > 0 && (root.mode !== "pick" || root.promptOnResult)
    var input = chain ? root.chainInput : editor.text
    if (!input.trim()) {
      root.fail("Nothing to rewrite: type or paste some text first.")
      return
    }
    root.promptOpen = false
    root.promptOnResult = false
    root.showNext = false
    root.chaining = chain
    root.steps = (chain ? root.doneSteps : []).concat([label])
    root.busyLabel = label
    root.pasteWhenDone = paste
    root.mode = "busy"
    keyCatcher.forceActiveFocus()
    root.runId++
    var run = root.runId
    var service = root.shell && typeof root.shell.serviceFor === "function" ? root.shell.serviceFor("ai-edit") : null
    if (service) {
      service.rewrite(model || root.config.model || "sonnet", instruction, input, function(text) {
        if (run !== root.runId) return
        root.stopCompares()
        var compare = compareComponent.createObject(root, { ownRun: run, input: JSON.stringify({ original: input, result: text }) })
        if (compare) root.compares = root.compares.concat([compare])
      }, function(error) {
        root.finishRun(run, 1, "", error)
      })
      return
    }
    // Without the service (a shell that has not loaded it) the CLI runs a
    // cold agent: slower, same result.
    runProc.ownRun = run
    runProc.input = input
    runProc.environment = id === "-" ? { "AI_EDIT_INSTRUCTION": instruction } : { "AI_EDIT_INSTRUCTION": null }
    runProc.command = [root.aiEditBin, "run", id, "--diff"]
    runProc.running = true
  }

  function finishRun(run, code, out, err) {
    if (run !== root.runId || !root.opened) return
    if (code !== 0) {
      root.fail(err.trim().replace(/^ai-edit: /, "") || "The rewrite failed")
      return
    }
    if (root.pasteWhenDone) {
      root.deliver(root.copyOnly ? "copy" : "insert", false)
      return
    }
    var segments
    try { segments = JSON.parse(out) } catch (e) {
      root.fail("The diff could not be read")
      return
    }
    if (root.chaining)
      root.history = root.history.concat([{ segments: root.segments, label: root.shownLabel,
        chainInput: root.chainInput, doneSteps: root.doneSteps, wantsResult: root.shownWantsResult }])
    root.segments = segments
    root.shownLabel = root.busyLabel
    root.shownWantsResult = root.runWantsResult
    root.chainInput = root.resultText
    root.doneSteps = root.steps
    root.mode = "diff"
    root.cursorActive = false
    textScroll.contentY = 0
  }

  function accept() {
    root.deliver(root.copyOnly ? "copy" : "insert", true)
  }

  function copyResult() {
    root.deliver("copy", true)
  }

  // The text shown goes along on stdin: after going back a step it is not
  // the last result, which is all result.txt holds.
  function deliver(command, shown) {
    root.dismiss()
    if (!shown) {
      Quickshell.execDetached([root.aiEditBin, command])
      return
    }
    deliverProc.input = root.resultText
    deliverProc.command = [root.aiEditBin, command, "-"]
    deliverProc.running = true
  }

  function fail(message) {
    root.errorText = message
    root.mode = "error"
    textScroll.contentY = 0
    keyCatcher.forceActiveFocus()
  }

  function hint(message) {
    var agent = ["codex", "opencode"].indexOf(root.config.agent) >= 0 ? root.config.agent : "claude"
    var name = { claude: "Claude Code", codex: "Codex", opencode: "opencode" }[agent]
    var command = agent
    var login = agent === "opencode" ? "opencode auth login" : agent
    if (/usage.limit|rate.limit|limit reached/i.test(message))
      return "The " + (agent === "claude" ? "Claude" : name) + " usage limit is reached. Try again later."
    if (/not installed/i.test(message))
      return "Install " + name + " and log in with: " + login
    if (/log ?in|auth|credential|401/i.test(message))
      return "Log in to " + name + " with: " + login
    if (/did not answer|exited|could not be started|still starting/i.test(message))
      return "Check that " + name + " works: run " + command + " in a terminal"
    return ""
  }

  // One step back: from an error to the last result, from a result to the
  // one before it, from the first result to the original text.
  function goBack() {
    if (root.mode === "diff" && root.history.length > 0) {
      var step = root.history[root.history.length - 1]
      root.history = root.history.slice(0, -1)
      root.segments = step.segments
      root.shownLabel = step.label
      root.chainInput = step.chainInput
      root.doneSteps = step.doneSteps
      root.shownWantsResult = step.wantsResult
    } else if (!(root.mode === "error" && root.doneSteps.length > 0)) {
      root.backToPick()
      return
    }
    root.mode = "diff"
    root.showNext = false
    root.cursorActive = false
    textScroll.contentY = 0
    keyCatcher.forceActiveFocus()
  }

  function backToPick() {
    root.showNext = false
    root.cursorActive = true
    root.mode = "pick"
    root.segments = []
    root.steps = []
    root.chainInput = ""
    root.doneSteps = []
    root.history = []
    root.chaining = false
    root.promptOnResult = false
    keyCatcher.forceActiveFocus()
  }

  // A result that keeps less than this share of the original is shown as
  // plain text: as a diff it would be all red and green. Only a fallback for
  // actions that do not say: Dutch and English share enough words ("dit is
  // een test") to fool it, so translations say "diff": false themselves.
  readonly property real plainBelow: 0.4
  readonly property string resultText: {
    var text = ""
    for (var i = 0; i < root.segments.length; i++)
      if (root.segments[i].op !== "del") text += root.segments[i].text
    return text
  }
  property bool shownWantsResult: false
  readonly property bool resultOnly: {
    if (root.shownWantsResult) return true
    var kept = 0, original = 0
    for (var i = 0; i < root.segments.length; i++) {
      var segment = root.segments[i]
      if (segment.op === "equal") kept += segment.text.length
      if (segment.op !== "ins") original += segment.text.length
    }
    return original > 0 && kept / original < root.plainBelow
  }

  readonly property var hints: root.mode === "busy" ? [["Esc", "cancel"]]
    : root.mode === "diff" ? (root.showNext && root.cursorActive ? [["↵", "run"], ["y", "copy"]]
        : root.copyOnly ? [["↵", "copy"]] : [["↵", "paste"], ["y", "copy"]])
        .concat([["?", root.showNext ? "hide actions" : "actions"], ["⌫", "back"], ["Esc", "close"]])
    : root.mode === "error" ? [["⌫", "back"], ["Esc", "close"]]
    : editor.activeFocus ? [["Tab", "choose action"], ["Esc", "close"]]
    : [["⇧", root.copyOnly ? "copy without preview" : "paste without preview"], ["Tab", "edit"], ["Esc", "close"]]

  function leaveEditor() {
    if (editor.text.trim()) keyCatcher.forceActiveFocus()
  }

  function letterOf(event) {
    if (event.key >= Qt.Key_A && event.key <= Qt.Key_Z)
      return String.fromCharCode(event.key).toLowerCase()
    return ""
  }

  // Keys for every state but the text fields. Returns whether it was used.
  function handleKey(event) {
    var shift = (event.modifiers & Qt.ShiftModifier) !== 0
    var other = event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)

    if (event.key === Qt.Key_Escape) {
      root.dismiss()
      return true
    }
    if (root.mode === "busy") return true
    if (other) return false
    // A held Enter would start a run and then accept its result unseen.
    if (event.isAutoRepeat && event.key !== Qt.Key_Up && event.key !== Qt.Key_Down) return true

    if (actionBox.visible) {
      if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
        root.moveCursor(event.key === Qt.Key_Up ? -1 : 1)
        return true
      }
      if (root.cursorActive && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Right)) {
        root.activateRow(root.selectedIndex, shift)
        return true
      }
    }

    if (root.mode === "diff") {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
        root.accept()
        return true
      }
      if (event.key === Qt.Key_Y && !shift) {
        root.copyResult()
        return true
      }
    }
    if ((event.key === Qt.Key_Backspace || event.key === Qt.Key_Left) && root.mode !== "pick") {
      root.goBack()
      return true
    }
    if (event.key === Qt.Key_Question) {
      // On a result the actions are hidden by default; ? shows them there.
      if (root.mode === "diff") {
        root.showNext = !root.showNext
        root.cursorActive = false
        root.selectedIndex = 0
        actionScroll.contentY = 0
      }
      else root.expanded = !root.expanded
      return true
    }
    if (event.key === Qt.Key_Tab && root.mode === "diff") return true
    if (event.key === Qt.Key_Tab) {
      root.backToPick()
      editor.forceActiveFocus()
      return true
    }

    var letter = root.letterOf(event)
    if (!letter) return false
    var action = root.actionForKey(letter)
    if (action) {
      root.runAction(action, shift)
      return true
    }
    if (letter === "c") {
      root.promptOnResult = root.doneSteps.length > 0 && root.mode !== "pick"
      if (!root.promptOnResult) root.mode = "pick"
      root.promptOpen = true
      promptField.text = ""
      Qt.callLater(function() { promptField.forceActiveFocus() })
      return true
    }
    return false
  }

  Process {
    id: stateProc
    command: [root.aiEditBin, "state"]
    stdout: StdioCollector { id: stateOut; waitForEnd: true }
    stderr: StdioCollector { id: stateErr; waitForEnd: true }
    onExited: function(code) {
      if (!root.opened) return
      if (code === 0) root.loadState(stateOut.text)
      else root.fail(stateErr.text.trim() || "AI Edit could not read its state")
    }
  }

  Process {
    id: deliverProc
    property string input: ""
    stdinEnabled: true
    onStarted: {
      write(input)
      stdinEnabled = false
    }
    onExited: stdinEnabled = true
  }

  Process {
    id: runProc
    property int ownRun: 0
    property string input: ""
    stdinEnabled: true
    stdout: StdioCollector { id: runOut; waitForEnd: true }
    stderr: StdioCollector { id: runErr; waitForEnd: true }
    onStarted: {
      write(input)
      stdinEnabled = false
    }
    onExited: function(code) {
      stdinEnabled = true
      root.finishRun(runProc.ownRun, code, runOut.text, runErr.text)
    }
  }

  Component {
    id: compareComponent

    Process {
      id: compare
      property int ownRun: 0
      property string input: ""
      command: [root.aiEditBin, "compare"]
      stdinEnabled: true
      running: true
      stdout: StdioCollector { id: compareOut; waitForEnd: true }
      stderr: StdioCollector { id: compareErr; waitForEnd: true }
      onStarted: {
        write(input)
        stdinEnabled = false
      }
      onExited: function(code) {
        root.compares = root.compares.filter(function(other) { return other !== compare })
        root.finishRun(compare.ownRun, code, compareOut.text, compareErr.text)
        Qt.callLater(compare.destroy)
      }
    }
  }

  // The shell's palette has no green; the theme's own colors file does.
  FileView {
    id: themeColors
    path: Color.currentThemePath + "/colors.toml"
    printErrors: false
    onLoaded: {
      var raw = text()
      var match = raw.match(/^\s*green\s*=\s*["']?(#[0-9A-Fa-f]{6})/m) || raw.match(/^\s*color2\s*=\s*["']?(#[0-9A-Fa-f]{6})/m)
      if (match) root.inserted = match[1]
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "ai-edit"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: content.implicitHeight + card.contentTopInset + card.contentBottomInset
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) { event.accepted = root.handleKey(event) }
      }

      Column {
        id: content
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: card.contentTopInset
        anchors.leftMargin: card.contentLeftInset
        anchors.rightMargin: card.contentRightInset
        spacing: root.contentSpacing

        // Header in the style of Omarchy's own overlays ("Go…" in the menu):
        // a muted line saying what is happening, no product name.
        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            id: stateLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            // A long custom prompt is cut off early: the text is what matters.
            width: Math.min(implicitWidth, parent.width * 0.6)
            textFormat: Text.PlainText
            text: root.mode === "busy" ? root.busyLabel + "…"
              : root.mode === "diff" ? root.shownLabel
              : root.mode === "error" ? "Something went wrong"
              : "Edit…"
            color: root.foreground
            opacity: 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }

          // While a rewrite runs, a short accent line glides under the header.
          Item {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.bottom
            anchors.topMargin: Math.round(root.contentSpacing / 2) - 1
            height: Math.max(1, Style.space(2))
            clip: true
            visible: root.mode === "busy"

            Rectangle {
              id: glider
              width: parent.width * 0.28
              height: parent.height
              color: root.accent
              opacity: 0.8

              NumberAnimation on x {
                running: root.mode === "busy"
                loops: Animation.Infinite
                from: -glider.width
                to: glider.parent.width
                duration: 1100
                easing.type: Easing.InOutQuad
              }
            }
          }
        }

        // The text: a quote with an accent rule. Editable in pick, the diff
        // or result afterwards, the message on an error.
        Item {
          id: textBlock
          width: parent.width
          height: Math.min(Math.max(shown.implicitHeight, Style.font.title * 2), root.textMaxHeight)
          readonly property bool showsResult: root.mode === "diff" || (root.mode === "busy" && root.chaining)
          readonly property Item shown: showsResult ? diffText
            : root.mode === "error" ? errorColumn : editor

          Rectangle {
            width: Math.max(2, Style.space(2))
            height: parent.height
            color: root.mode === "error" ? Color.urgent : root.accent
            opacity: editor.activeFocus || root.mode !== "pick" ? 0.9 : 0.45
          }

          Flickable {
            id: textScroll
            anchors.fill: parent
            // In line with the text of the action rows.
            anchors.leftMargin: Border.left(root.selectedBorderSpec) + Style.space(18)
            contentWidth: width
            contentHeight: textBlock.shown.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            function ensureVisible(r) {
              if (contentY >= r.y) contentY = r.y
              else if (contentY + height <= r.y + r.height) contentY = r.y + r.height - height
            }

            TextEdit {
              id: editor
              visible: !textBlock.showsResult && (root.mode === "pick" || root.mode === "busy")
              width: textScroll.width
              wrapMode: TextEdit.Wrap
              readOnly: root.mode === "busy"
              color: root.foreground
              opacity: root.mode === "busy" ? 0.45 : 1
              selectionColor: Style.selectionFill
              selectedTextColor: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              onCursorRectangleChanged: textScroll.ensureVisible(cursorRectangle)

              Keys.priority: Keys.BeforeItem
              Keys.onPressed: function(event) {
                var shift = (event.modifiers & Qt.ShiftModifier) !== 0
                var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
                if (event.key === Qt.Key_Escape) {
                  root.dismiss()
                  event.accepted = true
                } else if (event.key === Qt.Key_Tab) {
                  root.leaveEditor()
                  event.accepted = true
                } else if (editor.text === "" && ((ctrl && event.key === Qt.Key_V) || (shift && event.key === Qt.Key_Insert))) {
                  // Pasting into the empty field is the whole edit: go
                  // straight to the actions.
                  leaveAfterPaste.restart()
                }
              }

              Timer {
                id: leaveAfterPaste
                interval: 60
                onTriggered: root.leaveEditor()
              }
            }

            Text {
              visible: editor.visible && editor.text === ""
              textFormat: Text.PlainText
              text: "Type or paste text…"
              color: root.foreground
              opacity: 0.35
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }

            DiffText {
              id: diffText
              visible: textBlock.showsResult
              opacity: root.mode === "busy" ? 0.45 : 1
              width: textScroll.width
              segments: root.segments
              resultOnly: root.resultOnly
              insertedColor: root.inserted
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }

            Column {
              id: errorColumn
              visible: root.mode === "error"
              width: textScroll.width
              spacing: Style.spacing.md

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.errorText
                color: Color.urgent
                wrapMode: Text.Wrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
              }

              Text {
                width: parent.width
                visible: text !== ""
                textFormat: Text.PlainText
                text: root.hint(root.errorText)
                color: root.foreground
                opacity: 0.6
                wrapMode: Text.Wrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }
        }

        // Drawn as the kit's TextField, but on a TextEdit: an editable
        // TextInput reads the whole clipboard on every clipboard change to
        // update canPaste, through Qt's Wayland reader that has no size
        // limit or overall deadline. TextEdit only looks at the offered types.
        BorderSurface {
          id: promptBox
          visible: root.promptOpen
          width: parent.width
          height: promptField.height + topPadding + bottomPadding + borderTop + borderBottom
          leftPadding: Style.spacing.controlPaddingX
          rightPadding: Style.spacing.controlPaddingX
          topPadding: Style.spacing.inputPaddingY
          bottomPadding: Style.spacing.inputPaddingY
          borderSpec: Border.controlSpec(promptField.activeFocus ? "focus" : "normal", Color.foreground, Color.accent)
          color: Style.controlFill(promptField.activeFocus, false, Color.foreground, Color.accent)
          radius: Style.cornerRadius

          Text {
            x: promptField.x
            y: promptField.y
            width: promptField.width
            visible: promptField.text === "" && promptField.preeditText === ""
            textFormat: Text.PlainText
            text: "Tell AI Edit what to do with the text"
            color: Qt.darker(Color.foreground, 1.6)
            elide: Text.ElideRight
            font: promptField.font
          }

          TextEdit {
            id: promptField
            x: promptBox.contentLeftInset
            y: promptBox.contentTopInset
            width: promptBox.width - promptBox.contentLeftInset - promptBox.contentRightInset
            textFormat: TextEdit.PlainText
            wrapMode: TextEdit.Wrap
            color: Color.foreground
            selectionColor: Style.selectionFillFor(Color.foreground, Color.accent)
            selectedTextColor: Color.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            Keys.priority: Keys.BeforeItem
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                root.promptOpen = false
                root.promptOnResult = false
                keyCatcher.forceActiveFocus()
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.runPrompt(promptField.text, (event.modifiers & Qt.ShiftModifier) !== 0)
                event.accepted = true
              }
            }
          }
        }

        Item {
          id: actionBox
          width: parent.width
          // As in Omarchy's menu: when not every row fits, the list ends in
          // the middle of a row, which tells the eye there is more. The share
          // of the screen keeps the card, with the text at its tallest, on a
          // low screen.
          height: {
            var step = root.actionRowHeight + Style.spacing.xs
            var all = root.rows.length * step - Style.spacing.xs
            var available = Math.min(6 * step + root.actionRowPeek, Math.round(panel.height * 0.36))
            if (all <= available) return all
            var full = Math.max(1, Math.floor((available - root.actionRowPeek) / step))
            return full * step + root.actionRowPeek
          }
          // After a run the result is what matters; ? brings the actions
          // back.
          visible: root.mode === "diff" ? root.showNext : !textBlock.showsResult && root.expanded
          opacity: root.mode === "busy" ? 0.3 : 1
          enabled: root.mode !== "busy"

          Flickable {
            id: actionScroll
            anchors.fill: parent
            contentWidth: width
            contentHeight: actionList.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            // Keeps the next row peeking past the selection, as the menu does.
            function ensureVisible(index) {
              var top = index * (root.actionRowHeight + actionList.spacing)
              var bottom = top + root.actionRowHeight
              var reach = root.actionRowPeek + actionList.spacing
              var last = root.rows.length - 1
              var from = index > 0 ? top - reach : top
              var to = index < last ? bottom + reach : bottom
              if (to > contentY + height) contentY = Math.min(to - height, Math.max(0, contentHeight - height))
              if (from < contentY) contentY = Math.max(from, 0)
            }

            Column {
              id: actionList
              width: actionScroll.width
              spacing: Style.spacing.xs

              Repeater {
                model: root.rows
                delegate: ActionRow {
                  required property var modelData
                  required property int index
                  width: actionList.width
                  height: root.actionRowHeight
                  key: modelData.key || ""
                  label: modelData.label || modelData.id
                  direct: modelData.preview === false
                  // In the text field Enter is a new line, not this row.
                  selected: root.cursorActive && index === root.selectedIndex && !editor.activeFocus
                  foreground: root.foreground
                  selectedBackground: root.selectedBackground
                  selectedText: root.selectedText
                  selectedBorderSpec: root.selectedBorderSpec
                  fontFamily: root.fontFamily
                  onPointed: function(position) { root.pointAt(index, position) }
                  onActivated: function(shift) { root.activateRow(index, shift) }
                }
              }
            }
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: Math.min(Style.space(28), parent.height / 2)
            visible: opacity > 0
            opacity: actionScroll.contentHeight > actionScroll.height
              ? Math.max(0, Math.min(1, actionScroll.contentY / height))
              : 0
            gradient: Gradient {
              GradientStop { position: 0; color: root.background }
              GradientStop { position: 1; color: Util.alpha(root.background, 0) }
            }
          }

          Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Math.min(Style.space(28), parent.height / 2)
            visible: opacity > 0
            opacity: actionScroll.contentHeight > actionScroll.height
              ? Math.max(0, Math.min(1, (actionScroll.contentHeight - actionScroll.height - actionScroll.contentY) / height))
              : 0
            gradient: Gradient {
              GradientStop { position: 0; color: Util.alpha(root.background, 0) }
              GradientStop { position: 1; color: root.background }
            }
          }
        }

        Flow {
          width: parent.width
          spacing: Style.spacing.huge

          Repeater {
            // In the text field ? is just a character; promise only what works there.
            model: root.expanded || (root.mode === "diff" && root.showNext) ? root.hints : editor.activeFocus ? [["Tab", "choose action"]] : [["?", "actions"]]
            delegate: Row {
              required property var modelData
              spacing: Style.spacing.md

              Text {
                textFormat: Text.PlainText
                text: modelData[0]
                color: root.foreground
                opacity: 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                textFormat: Text.PlainText
                text: modelData[1]
                color: root.foreground
                opacity: 0.45
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }
          }
        }
      }
    }
  }
}
