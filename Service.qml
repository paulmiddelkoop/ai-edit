import QtQuick
import Quickshell
import Quickshell.Io

// Keeps an agent process waiting per model inside omarchy-shell, so a rewrite
// costs only the API time. Each process answers one turn and is replaced at
// once, so no conversation builds up. The overlay calls rewrite().
//
// bin/ai-edit-agent speaks the same protocol for `ai-edit run`: keep
// userMessage, extractAnswer and the padding in step with it. Codex and
// opencode speak claude's protocol through bin/ai-edit-codex and
// bin/ai-edit-opencode.
Item {
  id: root

  property var shell: null

  readonly property string pluginDir: decodeURIComponent(String(Qt.resolvedUrl(".")).replace(/^file:\/\//, "").replace(/\/$/, ""))
  readonly property string workDir: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/ai-edit/agent"
  readonly property int turnTimeout: 60000
  readonly property int maxAge: 3600000
  readonly property int maxText: 4 * 1024 * 1024

  property string systemPrompt: ""
  // Set while the shell tears the service down: creating a process then
  // races the engine's teardown.
  property bool closing: false
  Component.onDestruction: root.closing = true
  property var models: []
  property string agent: "claude"
  property bool fast: false
  // Minutes without use after which the waiting processes are stopped to
  // free their memory; 0 keeps them. A busy process is never in idle.
  property int idleTimeout: 30
  property real lastUse: Date.now()
  // model -> the process waiting for that model's next turn
  property var idle: ({})

  function rewrite(model, instruction, text, done, fail) {
    if (root.closing) return
    var core = text.trim()
    if (!core) {
      fail("Nothing to rewrite")
      return
    }
    // As bin/ai-edit-agent: the agent reads the request as one line.
    if (text.length > root.maxText) {
      fail("The text is too large")
      return
    }
    if (!root.systemPrompt) {
      fail("AI Edit is still starting; try again in a moment")
      return
    }
    // The model drops the whitespace around a selection (the newline a
    // triple-click takes along); it goes back around the answer.
    var start = text.indexOf(core)
    root.lastUse = Date.now()
    var worker = root.take(model)
    if (!worker) {
      fail(root.agent + " could not be started")
      return
    }
    worker.turn(root.userMessage(instruction, core), {
      before: text.slice(0, start),
      after: text.slice(start + core.length),
      done: done,
      fail: fail
    })
  }

  // The models the actions use; the overlay passes them when it opens, so a
  // model added to the config is warm from the next rewrite on. Opening counts
  // as use: a process stopped for idleness starts while a letter is chosen.
  function keepWarm(list, idleTimeout, agent, fast) {
    if (typeof idleTimeout === "number" && idleTimeout >= 0) root.idleTimeout = idleTimeout
    root.lastUse = Date.now()
    if (agent && (agent !== root.agent || (fast === true) !== root.fast)) {
      root.agent = agent
      root.fast = fast === true
      root.sleep()
    }
    var unique = []
    for (var i = 0; i < list.length; i++)
      if (list[i] && unique.indexOf(list[i]) === -1) unique.push(list[i])
    root.models = unique
    var next = {}
    for (var model in root.idle) {
      if (unique.indexOf(model) >= 0) next[model] = root.idle[model]
      else if (root.idle[model]) root.idle[model].retire()
    }
    root.idle = next
    for (var j = 0; j < unique.length; j++) root.warm(unique[j])
  }

  function userMessage(instruction, text) {
    return JSON.stringify({
      type: "user",
      message: { role: "user", content: [{ type: "text", text: instruction + "\n\n<text>\n" + text + "\n</text>" }] }
    }) + "\n"
  }

  // Scanned from the end: a model that repeats the instruction back names
  // the tag before it answers. Without the tags the output is passed through.
  function extractAnswer(raw) {
    var end = raw.lastIndexOf("</rewrite>")
    if (end < 0) return raw
    var start = raw.lastIndexOf("<rewrite>", end)
    if (start < 0) return raw
    var inner = raw.slice(start + "<rewrite>".length, end)
    if (inner.charAt(0) === "\n") inner = inner.slice(1)
    if (inner.charAt(inner.length - 1) === "\n") inner = inner.slice(0, -1)
    return inner
  }

  function fresh(worker) {
    return worker && worker.running && !worker.busy && Date.now() - worker.bornAt < root.maxAge
      && worker.agent === root.agent && worker.fast === root.fast
  }

  function spawn(model) {
    if (root.closing) return null
    return workerComponent.createObject(root, { model: model, agent: root.agent, fast: root.fast })
  }

  function warm(model) {
    if (!root.systemPrompt || !model) return
    var current = root.idle[model]
    if (root.fresh(current)) return
    if (current) current.retire()
    var next = Object.assign({}, root.idle)
    next[model] = root.spawn(model)
    root.idle = next
  }

  function dormant() {
    return root.idleTimeout > 0 && Date.now() - root.lastUse >= root.idleTimeout * 60000
  }

  function sleep() {
    var waiting = root.idle
    root.idle = ({})
    for (var model in waiting) if (waiting[model]) waiting[model].retire()
  }

  function take(model) {
    var worker = root.idle[model]
    var next = Object.assign({}, root.idle)
    delete next[model]
    root.idle = next
    if (!root.fresh(worker)) {
      if (worker) worker.retire()
      worker = root.spawn(model)
    }
    root.warm(model)
    return worker
  }

  function forget(worker) {
    if (root.idle[worker.model] !== worker) return
    var next = Object.assign({}, root.idle)
    delete next[worker.model]
    root.idle = next
  }

  Component {
    id: workerComponent

    Process {
      id: proc

      property string model: ""
      property string agent: "claude"
      property bool fast: false
      property real bornAt: Date.now()
      property bool busy: false
      property var request: null
      property var stderrLines: []

      function turn(message, pending) {
        proc.busy = true
        proc.request = pending
        proc.timer.restart()
        proc.write(message)
      }

      function settle(error, answer) {
        if (!proc.busy) return
        proc.busy = false
        proc.timer.stop()
        var pending = proc.request
        proc.request = null
        if (error) pending.fail(error)
        else pending.done(pending.before + answer + pending.after)
      }

      function handle(line) {
        var event
        try { event = JSON.parse(line) } catch (e) { return }
        if (!event || event.type !== "result") return
        var result = event.result || ""
        if (event.is_error || event.subtype !== "success") {
          proc.settle(result || event.subtype || proc.agent + " reported an error")
        } else {
          var answer = root.extractAnswer(result)
          if (!answer.trim()) proc.settle(proc.agent + " returned nothing")
          else proc.settle("", answer)
        }
        // Its replacement is already waiting.
        proc.stop(false)
      }

      // Closing stdin ends the agent after a turn and SIGTERM ends it otherwise;
      // one that ignores both is killed, or it would sit outside the pool
      // holding its memory.
      function stop(terminate) {
        proc.stdinEnabled = false
        if (terminate) proc.running = false
        proc.killTimer.restart()
      }

      function retire() {
        proc.stop(true)
      }

      property Timer killTimer: Timer {
        interval: 5000
        onTriggered: if (proc.running) proc.signal(9)
      }

      property Timer timer: Timer {
        interval: root.turnTimeout
        onTriggered: {
          proc.settle(proc.agent + " did not answer within " + Math.round(root.turnTimeout / 1000) + " s")
          proc.stop(true)
        }
      }

      command: proc.agent === "codex" || proc.agent === "opencode"
        ? [root.pluginDir + "/bin/ai-edit-" + proc.agent, proc.model].concat(proc.fast ? ["--fast"] : [])
        : ["claude", "-p",
          "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
          "--no-session-persistence",
          "--restricted", "--tools", "",
          "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
          "--model", proc.model,
          "--system-prompt", root.systemPrompt]
      // An empty directory, so no project CLAUDE.md is picked up; thinking off,
      // since on a rewrite it adds seconds.
      workingDirectory: root.workDir
      environment: ({ "MAX_THINKING_TOKENS": "0" })
      stdinEnabled: true
      running: true

      stdout: SplitParser {
        onRead: function(line) { proc.handle(line) }
      }
      stderr: SplitParser {
        onRead: function(line) {
          var trimmed = line.trim()
          if (trimmed && !/^at /.test(trimmed))
            proc.stderrLines = proc.stderrLines.concat([trimmed.slice(0, 300)]).slice(-20)
        }
      }

      onExited: function(code) {
        proc.killTimer.stop()
        proc.settle(proc.stderrLines.join(" ") || proc.agent + " exited with status " + code)
        root.forget(proc)
        Qt.callLater(proc.destroy)
      }
    }
  }

  // Replaces waiting processes that died or are older than an hour (auth and
  // updates are picked up when the agent starts), or stops them after
  // idleTimeout minutes without use.
  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: {
      if (root.dormant()) {
        root.sleep()
        return
      }
      for (var i = 0; i < root.models.length; i++) root.warm(root.models[i])
    }
  }

  FileView {
    path: root.pluginDir + "/system-prompt.txt"
    printErrors: false
    onLoaded: {
      root.systemPrompt = text().trim()
      makeWorkDir.running = true
    }
  }

  Process {
    id: makeWorkDir
    command: ["mkdir", "-p", root.workDir]
    onExited: config.running = true
  }

  Process {
    id: config
    command: [root.pluginDir + "/bin/ai-edit-config"]
    stdout: StdioCollector { id: configOut; waitForEnd: true }
    onExited: function(code) {
      var list = ["sonnet"]
      var idleTimeout, agent, fast
      if (code === 0) {
        try {
          var settings = JSON.parse(configOut.text)
          list = [settings.config.model].concat(settings.actions.map(function(a) { return a.model }))
          idleTimeout = settings.config.idle_timeout
          agent = settings.config.agent
          fast = settings.config.fast
        } catch (e) {}
      }
      root.keepWarm(list, idleTimeout, agent, fast)
    }
  }
}
