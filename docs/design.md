# AI Edit: edit text with AI in Omarchy

Select text anywhere, press Super+E (E for edit), press one letter. About a
second later the overlay shows what changed; Enter pastes it over the
selection, Esc keeps the original. Shift and the letter skips the preview and
pastes straight away.

This document records the design and what was measured while building it
(Omarchy 4, Hyprland 0.56.2, October 2026), so decisions do not have to be
rediscovered.

## Name

Called Spell until October 10, 2026. The name kept reading as the verb "to
spell": in the overlay header and in the Super+K keybindings overview. Paul
wanted a name that says what it does; "AI Edit" does, matches the header
"Edit…", and is free among Omarchy plugins, where Reword, Rephrase, Text
Transform, Recast and OmaPen are taken. Plugin id, commands, service and
config directory follow it: `ai-edit`, `ai-edit-agent`, `~/.config/ai-edit`.

## Why not an existing tool

Nothing on Linux does this well (market check, October 2026):

- Kerlig (macOS) has no Linux version.
- Writing Tools (2.5k stars) is X11 only; the native Wayland PR has been open
  for almost a year.
- The Omarchy plugins (OmaPen, omarchy-text-transform, omarchy-wordsmith,
  omarchy-typewriter, Recast) all run the agent CLI cold, so a rewrite takes
  3 to 8 seconds, and none of them shows a diff before replacing the text.
- ZyntaxAI has a word diff but is a two-month-old hobby fork without Claude
  support.

OmaPen (https://github.com/vladimirstempel/omapen, MIT) is the reference for
the Wayland plumbing: its `bin/omapen` documents every pitfall of capturing a
selection and pasting back on Hyprland. Read it before writing `bin/ai-edit`, and
credit it in the README. Its UI (bar widget, button grid, Alt+digit shortcuts)
is not what AI Edit wants.

## Three promises

1. **Fast**: about one second from keystroke to result. The agent is started
   ahead of time and waits for the next selection.
2. **See the change**: a word-level diff before anything is pasted.
3. **No API key**: uses the coding agent Omarchy already has (Claude Code or Codex);
   an Anthropic API key is an optional alternative backend.

README wording for the third point: "Uses the coding agent Omarchy already
has (Claude Code by default), so there is no API key to set up. An Anthropic
API key can be configured instead." Do not frame it as free or unlimited
Claude.

## Architecture

```
Super+E ─▶ bin/ai-edit open ─▶ capture selection ─▶ summon overlay
                                                      │ letter
                    Service.qml (warm claude) ◀───────┘
                                 │ result
                     bin/ai-edit compare ─▶ overlay shows diff
                                                      │ Enter
                           bin/ai-edit insert ◀─────────┘ (paste over selection)
```

Three parts, each testable from a terminal without the shell:

- `bin/ai-edit`: bash. Everything that touches the compositor, the clipboard and
  the files. Subcommands: `open`, `compose`, `capture`, `run <id> [--insert]`,
  `compare`, `diff`, `insert`, `copy`, `selftest`.
- `Service.qml`: the warm Claude pool, a `service` plugin inside omarchy-shell.
- `bin/ai-edit-agent`: one rewrite by a fresh agent, for `ai-edit run` from a
  terminal.
- `bin/ai-edit-codex`: Codex behind claude's stream-json protocol, so the
  pool and `ai-edit-agent` treat both agents alike (see Codex backend).
  `bin/ai-edit-opencode` does the same for opencode, with
  `lib/opencode-guard.ts` loaded into its server (see opencode backend).
- `AiEdit.qml` plus `components/`: the overlay. Draws only; every action is a
  call into `bin/ai-edit` or the service.

State lives in `$XDG_RUNTIME_DIR/ai-edit/`: `session.json` (text, source,
window address, xwayland, terminal), `original.txt`, `result.txt`,
`diff.json`.

The pool was first a Python `systemd --user` service behind a Unix socket
(the design below). On October 10, 2026 it moved into the shell, the way
Omarchy's own background work runs (notifications, idle, battery): no
service to install or enable, and no 18 MB Python process next to the 233 MB
Claude Code process that does the real work. Rewrites through it took 1.27
to 1.31 s end to end, as before. The cost: the first rewrite after a shell
restart waits for a fresh claude, and `ai-edit run` from a terminal no
longer has a warm one (2 s). Rust was considered for the old service and
rejected: it would have saved the 18 MB only and needed prebuilt binaries
for ARM and x86, since `omarchy plugin add` does not build anything.

### The warm agent (measured)

`claude -p` cold takes 3 to 5 s on haiku, of which 2 to 3 s is Node start-up,
auth and session set-up, not the model. A process started with
`--input-format stream-json --output-format stream-json --verbose` and left
waiting answers a rewrite in **1.0 to 1.6 s** on haiku (measured three turns in a
row, and 1.1 s for a first turn in a process started 4 s earlier). Idle RSS is
about 240 MB. An early Codex test took 7 to 8 s with gpt-6.1-sol and rejected
the requested mini models on the subscription used. That did not establish
Codex's minimum latency; the app-server comparison below supersedes the
conclusion that Codex is unsuitable.

Measured again with the finished pool (claude 2.1.295, haiku 5.5):
the local part of a turn (socket, pool, jq, Python) is about 0.1 s; the rest
is the API, which varied from 1.0 to 1.6 s with requests spaced a few seconds
apart and from 1.2 to 3.0 s on other runs of ten in a row. A replacement
process started 1 to 2 s earlier is as fast as one that has waited a minute.
Haiku 5.5 thinks 110 to 160 tokens per turn whatever `MAX_THINKING_TOKENS=0`,
`CLAUDE_CODE_DISABLE_THINKING=1` or `CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=1`
say. Sonnet through the pool took 1.3 to 1.6 s, as fast as haiku, which is
why sonnet became the default model (it was also the only model reliable on
very short sentences in Paul's OmaPen measurements of October 5). A cold
`ai-edit run` without the service took 2.0 s.

Design of the pool (written for the Python service; Service.qml keeps the
same behaviour):

- Keeps **one idle claude process per model** named in the prompts (usually
  just haiku, maybe sonnet). Each process serves **exactly one turn**: after
  the result its stdin is closed and a fresh one is started immediately. No
  context ever accumulates, nothing to clear.
- Spawn command, from the working `omapen-claude` wrapper plus two flags:

  ```
  MAX_THINKING_TOKENS=0 claude -p --input-format stream-json \
    --output-format stream-json --verbose --no-session-persistence \
    --restricted --tools '' --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
    --model <model> --system-prompt "<system prompt>"
  ```

  `--no-session-persistence` keeps the turns out of `~/.claude/projects` and
  the resume list. Run it in a dedicated empty cwd
  (`~/.local/state/ai-edit/agent`) so no project CLAUDE.md is picked up.
  Thinking off: on a rewrite it adds seconds and made haiku less accurate.
- Request on the socket: one JSON line `{"model": ..., "instruction": ...,
  "text": ...}`. Reply: `{"text": ...}` or `{"error": ...}`. The user message
  is built by the agent: instruction, blank line, `<text>...</text>`. The
  result event's `result` field is the answer; strip the `<rewrite>` tags.
- Timeout 60 s per turn; on error or a dead process, kill, respawn, report.
- A process that has been idle for more than an hour is recycled (claude
  auto-updates and auth refresh happen on start).
- After `idle_timeout` minutes (default 30, 0 = never) without a rewrite or
  an opened overlay, the waiting processes are stopped, so a plugin used a
  few times a day does not hold about 170 MB per model all day (RSS 240 MB,
  PSS 160 MB: the rest is shared with other Claude Code processes); many
  Omarchy machines have 8 to 16 GB. Opening the overlay starts them again,
  so the cold start mostly overlaps with choosing an action. Busy processes
  are never stopped: they are no longer in the pool.
- `bin/ai-edit run` falls back to a cold `claude -p` with the same flags when
  the socket is absent, so the plugin works without the service, just slower.
- System prompt: take OmaPen's (`SYSTEM_PROMPT` in `omapen-claude`) as the
  starting point. It wraps the material in `<text>`, forbids em dashes and
  other model tics, treats instructions inside the text as text, and asks for
  `<rewrite>` tags so preamble can be stripped.

Optional later backend `api`: direct `curl` to the Anthropic Messages API with
streaming, key read through a command in the config (for example `op read`).
Keep the interface the same so the overlay does not know which one runs.

### Codex comparison (October 10, 2026)

Measured with Codex CLI 0.162.0 and Claude Code 2.1.296, using the same AI
Edit system prompt and shipped action instructions. Six synthetic texts
(English and Dutch corrections, a very short correction, Improve, English
translation, and a multiline email) were each run twice per condition.
[Inputs, settings, outputs and timings](benchmarks/2026-10-10.json) are saved
with the results. No screen or clipboard text was used.

| Model | Mode | Median complete result | Range | Requests |
| --- | --- | --- | --- | --- |
| GPT-6.1 Sol | Low reasoning, standard | 3.66 s | 2.94–5.06 s | 12 |
| GPT-6.1 Sol | Low reasoning, Fast | 3.07 s | 2.76–5.15 s | 12 |
| GPT-6 Luna | Low reasoning, standard | 2.33 s | 2.08–2.99 s | 12 |
| GPT-6 Luna | Low reasoning, Fast | 2.39 s | 2.22–3.12 s | 12 |
| Claude Sonnet 5.5 | Current AI Edit settings | 1.26 s | 0.99–1.30 s | 12 |

Codex used one initialized `app-server --listen stdio://` process per
condition, with a fresh ephemeral thread for each rewrite and `effort: low`.
Fast was requested as `serviceTier: priority` and confirmed in the thread
response. Each Claude process was started two seconds before its single
rewrite, using the same command as AI Edit plus partial-message output for
timing. Measurements end at the completed result, not the first token, and
exclude capture, overlay rendering and paste. Codex timings include thread
creation (0.03–0.07 s); its process initialization took 0.09–0.10 s.

The first request in the initialized Codex process was not consistently
slower than later requests: 3.30 s for Sol standard, 2.90 s for Sol Fast,
2.20 s for Luna standard and 2.41 s for Luna Fast. This run gives no evidence
that keeping the process alive alone removes several seconds of latency.

**Context limitation:** the Codex requests contained 8,473–8,517 input
tokens. Although project document loading, MCP, app integrations and several
tools were disabled, `codex debug prompt-input` showed that global
`AGENTS.md`, skill listings, permissions, collaboration and multi-agent
instructions still entered the context. `project_doc_max_bytes = 0` did not
remove global instructions. Disabling additional capabilities and host skill
discovery reduced one diagnostic request to 5,641 input tokens and 2.56 s
(Sol Fast), but did not produce a prompt-only request. An empty `instructions`
override also did not remove global instructions in the context diagnostic.
Claude's requests contained 916–964 input tokens including cache reads and
writes, with no tools. The providers use different tokenizers.

These are measurements of the tested integrations, not a controlled ranking
of model inference speed. All Codex calls completed without tool calls or
reported reasoning tokens. The spelling fixes were correct in this small
sample. Luna used curly apostrophes despite the prompt and, in both Fast
Improve outputs, changed a proposed Thursday meeting into a decision to move
it. Sonnet's Improve output retained some repetition. This is not a broad
quality evaluation.

Sol Fast's median was about 16% lower in this run; Luna showed no benefit.
Conditions ran sequentially, without randomized interleaving, so server load
and caching may affect the comparison. Codex is a viable backend candidate,
but matching the current Claude latency remains unproven. The follow-up
below removes the personal instructions and coding-tool context.

#### Follow-up: isolated rewrite context

The reproducible [Codex benchmark](benchmarks/codex-benchmark) runs the same
six synthetic texts twice, without loading personal Codex configuration.
It requires Linux, `bwrap`, existing file-based Codex authentication and a
cached model catalog. Tested with Codex CLI 0.162.0.

```sh
python3 docs/benchmarks/codex-benchmark gpt-6.1-sol --output /tmp/codex-standard.json
python3 docs/benchmarks/codex-benchmark gpt-6.1-sol --tier priority --output /tmp/codex-fast.json
```

A private mount namespace masks the entire Codex configuration directory
with temporary storage and exposes only the existing `auth.json`, read-only.
Global `AGENTS.md`, `AGENTS.override.md`, symlinks, plugins and user settings
are therefore absent regardless of their size. The real directory and
environment variables are unchanged; credentials are not copied into the
benchmark artifacts. The remaining filesystem is read-only except for the
temporary benchmark directory. This is a benchmark setup, not a production
authentication solution: it cannot save refreshed credentials.

Feature flags alone did not remove the coding tools selected by the model
catalog. A temporary catalog preserves the requested model but switches its
local tool mode to `direct` and multi-agent version to `v1`, removes patch
and experimental tool capabilities, and replaces its default instructions
with AI Edit's system prompt. Shell, agents, apps, skills, hooks, planning
and user-input tools are disabled. These catalog overrides are specific to
the tested CLI and require revalidation after upgrades.

Before inference, the script checks `codex debug prompt-input` and refuses
to run if anything other than the synthetic input and Codex's short
permissions message appears. The latter is 341 characters and is retained.
Actual requests contained **544–588 input tokens**, about 93% fewer than the
initial comparison. No tools, reasoning tokens or cached input tokens were
reported in these 24 requests.

| GPT-6.1 Sol, low reasoning | Median complete result | Range | Requests |
| --- | --- | --- | --- |
| Standard, isolated context | 3.58 s | 2.92–4.32 s | 12 |
| Fast, isolated context | 2.88 s | 2.45–3.17 s | 12 |

[Settings, context checks, outputs and timings](benchmarks/2026-10-10-isolated.json)
are saved alongside the original measurements. Conditions ran sequentially,
standard then Fast, with one initialized server per condition and a fresh
ephemeral thread per request. Process initialization took 0.08 s and thread
setup 0.007–0.028 s. The reported duration includes thread setup, but excludes
process initialization, the context check and screen capture or paste.

The context problem is resolved for this benchmark, including the previously
unbounded global instructions. Latency is still multiple seconds: compared
with the earlier 3.66 s standard and 3.07 s Fast medians, the improvement is
small and cannot be separated from server-load variation in these sequential
runs. This does not establish that Codex matches Claude's earlier 1.26 s
median. AI Edit's live backend remains Claude Code; the Codex backend below
followed.

### Codex backend (October 16, 2026)

`agent = "claude" | "codex"` picks the agent. Left out, AI Edit uses claude
when it is on the PATH and codex when only that is: Claude is about twice as
fast (below). Following `omarchy default agent` was the first version; Paul
chose speed over it the same day. Models are per agent:
the default is sonnet for Claude and gpt-6.1-sol for Codex, and a Claude model
name with Codex (or a `gpt-` name with Claude) is a config error, so a config
written for one agent fails clearly on the other.

`bin/ai-edit-codex` is a bridge: it starts `codex app-server`, initializes
it, then reads one claude stream-json user message and answers with a claude
result event, starting a fresh ephemeral thread for that turn. Service.qml
keeps it waiting like a claude process (one per model, one turn each, the
same timeouts, idle stop and replacement), and `ai-edit-agent` runs it for a
terminal rewrite. A JSON-RPC client in QML was the alternative; the bridge
keeps the pool unchanged and is testable without the shell
(`tests/codex-test` against `tests/fake-codex`). A waiting Codex costs about
120 MB RSS (bridge 26 MB, app-server 93 MB) against about 240 MB for claude.
The server gets `PR_SET_PDEATHSIG`, so a bridge the pool kills takes it along.

Isolation for production, replacing the benchmark's bwrap mount: Codex runs
with `CODEX_HOME=$XDG_RUNTIME_DIR/ai-edit/codex`, which holds only a symlink to
the user's `auth.json`, the reduced model catalog and Codex's own state.
Codex 0.163 saves `auth.json` by truncating and writing the existing path
(`codex-rs/login/src/auth/storage.rs`), so a token it refreshes goes through
the link into the user's file and the user's own Codex stays logged in; a
copy would leave the user with a rotated-out refresh token. Keyring storage
is keyed on the home's path and cannot be shared this way, so the bridge sets
`cli_auth_credentials_store = "file"`. The runtime directory keeps Codex's
logs and databases off disk; none of them held the text in a check.

The catalog overrides (direct tool mode, no coding tools, AI Edit's system
prompt as base instructions) still depend on the Codex version. Before the
first server of a new Codex version, catalog or settings, the bridge runs
`codex debug prompt-input` and refuses to start when anything other than the
probe text and the permissions message would be sent. The result is
remembered per version and settings, since the check costs about a second.
The codex path is not resolved: under mise it is a shim, and resolving it
runs mise itself.

The separate home does not leave out `/etc/codex/config.toml` (found by the
security review on October 16). An MCP server configured there would start
with the app-server and give a prompt injection in the text a tool that runs
without approval; the bridge only sees the call when it has run. So each
start lists the effective servers with `codex mcp list --json`, switches each
off by name (`mcp_servers.<name>.enabled = false`; an empty `mcp_servers`
table does not override them), lists again to confirm, and after
initializing asks `mcpServerStatus/list` and refuses when any server offers
tools.

Model choice, measured with the isolated benchmark on Codex 0.163.0, low
effort (the lowest every candidate offers), six synthetic texts twice per
condition, run sequentially ([results](benchmarks/2026-10-16-models.json)):

| Model | Tier | Median | Range |
| --- | --- | --- | --- |
| GPT-6.1 Sol | standard | 3.24 s | 2.74–3.76 s |
| GPT-6.1 Sol | Fast | 2.74 s | 2.27–5.06 s |
| GPT-6 Luna | standard | 2.83 s | 2.15–4.56 s |
| GPT-6 Luna | Fast | 2.59 s | 2.12–3.98 s |
| GPT-5.6 Luna | Fast | 2.59 s | 2.02–3.04 s |
| GPT-6 Astra | Fast | 3.08 s | 2.66–3.99 s |

Sol was correct and consistent on every sample. Both Lunas again turned the
proposal in the Improve sample ("can we do Thursday instead?") into a
decision to move the meeting, GPT-6 Luna dropped "still" from the
translation and once used a curly apostrophe. Astra was slower without
better output. Fast saved Sol about half a second, as on October 10, and a
rewrite is about 570 tokens, so its extra usage is small: the default is
gpt-6.1-sol with Fast on, `fast = false` to save usage. Codex stays about
twice as slow as Claude (1.26 s), which the README says.

### opencode as a backend (October 16, 2026)

Research only: can opencode 2.0.31 be a third agent behind the same bar
(warm, isolated, comparable latency)? Measured with
[opencode-benchmark](benchmarks/opencode-benchmark), the same six synthetic
texts twice per condition, one server per condition, a fresh session per
rewrite ([results](benchmarks/2026-10-16-opencode.json)):

```sh
python3 docs/benchmarks/opencode-benchmark openai/gpt-6.1-sol --output /tmp/opencode-standard.json
python3 docs/benchmarks/opencode-benchmark openai/gpt-6.1-sol-fast --output /tmp/opencode-fast.json
```

| GPT-6.1 Sol, low effort | Median | Range | Input tokens |
| --- | --- | --- | --- |
| opencode, standard | 3.22 s | 2.63–16.64 s | 237–289 |
| opencode, Fast | 2.72 s | 2.40–6.10 s | 237–289 |
| Codex isolated, standard (above) | 3.24 s | 2.74–3.76 s | 544–588 |
| Codex isolated, Fast (above) | 2.74 s | 2.27–5.06 s | 544–588 |

The medians match Codex's to the hundredth: the agent adds nothing that
shows, and the remaining seconds are the model behind the ChatGPT login.
Each run had one outlier (16.6 s and 6.1 s) whose cause was not recorded.
The first rewrite of a fresh server was 0.3 to 0.7 s slower than the
median. Outputs equalled Codex's Sol outputs in substance, with no tools,
reasoning tokens or extra model calls. Claude could not be compared:
opencode has no Claude subscription login, only an Anthropic API key.

**Warm mode.** `opencode serve --stdio` is not a stdio protocol: it starts
the v2 HTTP API on localhost, prints `{"url": ...}` and exits when stdin
closes, which suits a bridge. The server requires a password
(`OPENCODE_PASSWORD`, basic auth). A rewrite is four calls:
`POST /api/session` (agent, model with variant, title, directory),
`POST /api/session/{id}/prompt`, `POST /api/experimental/session/{id}/wait`,
`GET /api/session/{id}/message?type=assistant`, then `DELETE` the session.
Setup took 0.13 s and a session 0.03 s. One server serves any number of
sessions, so unlike claude and Codex a session gives the fresh context and
the process can stay. There is no ephemeral session: messages go to the
SQLite database until the session is deleted.

**Context.** Configuration, plugins, skills and AGENTS.md come from the
config and data directories, so a server with its own `XDG_*` directories,
`HOME`, `OPENCODE_DISABLE_PROJECT_CONFIG=1` and `OPENCODE_DISABLE_CLAUDE_CODE=1`
loads none of the user's. CLAUDE.md is not read by v2. Settings come in
`OPENCODE_CONFIG_CONTENT`: an agent whose `system` is AI Edit's prompt
replaces opencode's own, a deny-all permission rule removes every tool
definition from the request (not only their use), and a given session
title skips the title request. Built-in plugins are removed by ID
(`-opencode.prompt.identity`, `-opencode.tools`,
`-opencode.config.instruction`). What config cannot remove is the date and
`<env>` block (working directory, platform, git, temp directory) that
opencode appends to every system prompt. `/etc/opencode` is always read; it
is admin-managed, not personal.

There is no `debug prompt-input`. A plugin does that work instead, and more
precisely: its `context` hook sees the system parts, tool definitions and
messages right before dispatch, drops everything after AI Edit's prompt, and
throws when there is a tool, another message or another prompt; a throw
sends nothing (tested: no request, no assistant message). Its `http.request`
hook sees the final body (zstd-compressed on the ChatGPT route). In all 24
requests the body held `instructions` equal to the system prompt, one user
message, no tools, `store: false`, reasoning low and opencode's
`text.verbosity: low`. Input was 237–289 tokens, half of Codex's isolated
request. The benchmark records sizes and shapes, not text. A production
bridge would send a probe text whose `context` hook throws after checking,
so the check costs no request, and refuse to use a server whose plugin did
not answer.

**Credentials.** There is nothing to link. Logins live in the `credential`
table of `opencode.db`, refreshed in place; `auth.json` is only read once by
a migration on an existing database. The benchmark therefore points
`OPENCODE_DB` at the user's own database: nothing is copied and a refresh
lands where the user's opencode reads it, but every rewrite is written into
that file on disk until its session is deleted, and SQLite may keep deleted
pages or WAL frames. That breaks the rule that text stays in
`$XDG_RUNTIME_DIR`. The alternatives each break something else: a copied
credential in an in-memory database (`OPENCODE_DB=:memory:`) can rotate the
user's refresh token away; an AI Edit login of its own needs a persistent
database, again on disk, or a new login every boot. Only an API key from the
environment (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`) with an in-memory
database keeps both credentials and text off disk, and that is pay-per-token,
not the subscription. ChatGPT's own login ("Sign in with ChatGPT", token
sharing) registers a client per sign-in, separate from Codex's login.

**Memory.** A waiting server is one process (the mise wrapper execs into
it): 157 MB RSS (136 MB PSS) when fresh, about 300 MB (280 MB PSS) once a
rewrite has loaded the provider code. That is more than claude (240 MB) and
Codex (120 MB). Starting a server per rewrite, as the pool does now, would
keep it at 157 MB but pay the first-rewrite cost each time.

**Verdict.** Feasible as a warm backend in latency (`serve --stdio`, Fast,
about 2.7 s, the same as Codex), and its context can be isolated more
tightly than Codex's and checked before sending. It brings nothing Codex
does not already give AI Edit on the same subscription, costs more memory,
and cannot keep the text off disk with a subscription login. Not worth
building now; it would become interesting for API-key use (any provider,
in memory) or for models only opencode reaches. Paul chose to build it the
same day, opt-in; see the next section.

Open risks: the plugin API (`context`, `http.request`) is v2 and new, and
the guard must fail closed if it ever stops loading; Fast is requested
(`service_tier: priority`) and was faster, yet the response reported the
`default` tier; the two outliers; and the token-sharing route's limits
(`subscription_sharing_*` errors) are separate from Codex's.

### opencode backend (October 16, 2026)

`agent = "opencode"` with a `provider/model` (default `openai/gpt-6.1-sol`).
It is never picked automatically, because of the database below: the README
says so where it explains what happens to the text, and AGENTS.md records it
as the one exception to the rule that text stays in `$XDG_RUNTIME_DIR`. Any
model opencode is logged in to works, since the guard sits before the
provider; only GPT-6.1 Sol is measured.

`bin/ai-edit-opencode` is a bridge like `ai-edit-codex`: it starts
`opencode serve --stdio` on localhost with a random password, waits for one
claude stream-json message, runs it as one session (create, prompt, wait,
read, delete) and answers with a claude result event, so Service.qml and
`ai-edit-agent` only needed the command. `--fast` picks the model's `-fast`
variant when opencode has one; effort is the lowest variant offered (`none`,
`minimal` or `low`). Every rewrite starts a server, as with Codex, which
keeps the pool unchanged; one long-lived server with a session per rewrite
would save the start but needs a pool of its own. A waiting bridge holds
about 315 MB RSS: the server grows from 157 to 285 MB once the probe below
has loaded the provider code, and the bridge is 31 MB.

Isolation without touching the XDG directories: under mise, `opencode` is a
wrapper that runs mise, which reads them too. `OPENCODE_CONFIG_DIR` points at
`$XDG_RUNTIME_DIR/ai-edit/opencode/config`, holding only the guard; every
other `OPENCODE_*` variable of the user is dropped except `OPENCODE_DB`.
Checked live with a plugin and an AGENTS.md in the user's config directory:
a plain server loaded the plugin, which saw the request; the bridge's did
not. Settings come in `OPENCODE_CONFIG_CONTENT` as in the research above.

`lib/opencode-guard.ts` is the `context` hook from the research: only AI
Edit's prompt stays in the system part, and a request with tools, other
messages, another agent or another prompt throws, which sends nothing. It
writes its verdict, without the text, to a status file the bridge names.
Before a server is used the bridge sends a probe text; the guard checks it
and throws, so the check costs no request. No verdict, or an answer to the
probe, means the guard is not loaded and the bridge refuses to start. A
refusal on a real rewrite reaches the overlay as an error. The guard depends
on opencode's v2 plugin API; the probe makes a change there fail closed.

The database, measured with a synthetic marker in the user's `opencode.db`:
13 copies in the WAL after the turn, 15 after deleting the session (rows
gone, bytes not), and after a checkpoint none in the WAL but 3 in free pages
of the main file, in no live row. opencode deletes without `secure_delete`,
so the text stays until SQLite reuses those pages. `VACUUM` after each
rewrite would remove it but rewrites the user's whole database while their
own opencode may be using it; deleting the rows ourselves with
`secure_delete` would bypass opencode's schema. Neither is done. A bridge
killed during a turn leaves its session; the next bridge deletes rewrite
sessions in AI Edit's working directory older than a turn can last.

### Capture and insert (measured)

How the chord reaches the focused window depends on the window:

| Window | Copy | Paste | Why |
| --- | --- | --- | --- |
| Terminal (`terminal` tag from Omarchy's `apps/terminals.lua`) | `send_key_state` Ctrl+Insert | `send_key_state` Shift+Insert | Ctrl+C is interrupt. Omarchy configures foot, kitty, alacritty and ghostty with Ctrl+Insert / Shift+Insert for exactly this; its own Super+C/V use them |
| XWayland (`xwayland: true` in `hyprctl activewindow -j`), e.g. Slack via `slack-x11` | `send_key_state` Ctrl+C | `send_key_state` Ctrl+V | wtype presses never arrive: XWayland keeps its keymap and the keycode means something else. Verified: wtype, `sendshortcut` and ydotool all copied nothing, `send_key_state` copied the selection |
| Everything else | `send_key_state` Ctrl+C, fall back to wtype if it fails | same with V | Hyprland's own path first; OmaPen used wtype because `send_shortcut` resolves keys against the layout (fails on Cyrillic). Measure which works on Paul's US layout and keep wtype as the fallback |

`send_key_state` is Hyprland's dispatcher, down and up split with a short
pause, exactly as `/usr/share/omarchy/default/hypr/bindings/clipboard.lua`
does. From a shell under the Lua config the call is:

```
hyprctl dispatch "hl.dsp.send_key_state({ mods = 'CTRL', key = 'C', state = 'down' })"
sleep 0.05
hyprctl dispatch "hl.dsp.send_key_state({ mods = 'CTRL', key = 'C', state = 'up' })"
```

`send_key_state` was then measured for every kind of window, so there is no
wtype fallback: Chromium on Wayland and on XWayland copied on the first press
(capture 0.2 s) and pasted (insert 0.75 s, most of it the fixed waits); foot
pasted on Shift+Insert. The very first attempt on a fresh Wayland Chromium
window copied nothing and left its text area empty; it did not happen again
in later runs and is not explained. Copying a selection out of foot was not
automated (a selection needs the mouse).

Paul's own Super+H presses (October 9, 2026) settled the retry loop: in
Brave, Slack (XWayland) and foot the first synthetic copy landed every time,
with Super still physically held, because `send_key_state` sends its own
modifiers. With the 0.9 s retry budget an empty selection took 1.03 s to open
the overlay. Capture now presses once and waits up to 250 ms for the
clipboard: 0.13 s with a selection, 0.35 s without. That also made the
Super+Shift+H compose chord unnecessary.

Rules carried over from OmaPen, each learned the hard way there:

- Clear the clipboard first, so a copy that holds a `text/*` type is the
  answer and an empty clipboard means nothing is selected. (OmaPen pressed
  again for ~900 ms because its wtype chord merged with the held Super;
  `send_key_state` does not, see above.)
- Save the clipboard before and restore it after, through a file and with its
  MIME type, never through a bash variable (NUL bytes in images).
- Never read PRIMARY as a fallback: it holds the last selection made anywhere.
  Nothing copied means nothing selected: open the overlay with an empty field
  to type into (compose mode).
- Never pass captured text as a command-line argument; it shows in `/proc`.
  Use files and stdin.
- Before pasting, focus the recorded window address (`hl.dsp.focus`), wait
  ~250 ms, paste, wait ~400 ms, then restore the clipboard.
- Undo in the application brings the original back; AI Edit keeps nothing.

### Config

One file, `~/.config/ai-edit/config.toml`, read by `bin/ai-edit-config`
(Python's `tomllib`). The plugin's own `config.toml` holds the defaults with
comments and doubles as the template to copy. Settings in the user file
override the defaults key by key; `[[action]]` tables, when present, replace
the shipped actions as a whole. TOML because it allows comments and
multi-line instructions and matches Omarchy's own theme files; Paul found two
JSON files (`config.json` plus `prompts.json`, the first design) clumsy and
old-fashioned.

```toml
model = "sonnet"
preview = true
compact = false
width = 560
idle_timeout = 30

[[action]]
key = "f"
label = "Fix"
instruction = """
Correct spelling, grammar and punctuation only. ..."""
```

An action's id, for `ai-edit run <id>`, is its label in lower case (the key
works too). The shipped actions suit most people (Fix, Improve, Shorten,
English; tone changes are left to the custom prompt, chosen with Paul and
Codex for the README demo on October 13, 2026).

`preview` is the default; an action may override it; Shift inverts whichever
applies. `model` is the default for actions without one. Translations keep
the preview: Paul wants to read them before they are pasted, as plain text
(`diff = false`) rather than as a diff that would be all red and green.

### Overlay

Omarchy plugin of kind `overlay` (like `omarchy.emojis` and
`omarchy.clipboard` in `/usr/share/omarchy/shell/plugins`), summoned with
`omarchy-shell shell summon ai-edit '<json>'`. Study those two for the manifest,
the `PanelWindow` with `WlrLayer.Overlay` and exclusive keyboard focus, and how
they take theme colours and spacing from `qs.Commons` / `qs.Ui`. Centered on
the focused monitor, width from config, no bar icon.

One window, four states:

- **pick**: the captured text (editable, scrolls) and the action list, each
  with its key letter; `c` opens a free prompt field. In compose mode the
  text field is empty and focused.
- **busy**: the action name and a subtle pulse. No spinner theatre; it lasts
  a second.
- **diff**: word-level diff of original versus result. Deleted words red with
  strikethrough, inserted words green, unchanged plain; line breaks kept.
  Enter pastes, Esc closes, `y` copies, Backspace (or ←) goes one step back:
  to the previous result of a chain, from the first to the original. A letter runs that action on the result, so combinations such as
  "improve, then translate" are two visible steps instead of combined actions;
  the header names only the last step (the whole chain distracted). The action
  list is hidden here, the result is what matters; `?` shows it for a next
  step ("A-Z next step" asked people to remember the letters).
- **error**: the message and the hint (service not running, limit reached).

The action list is one column that looks like Omarchy's keybindings menu
(Super+K), with the menu's fonts, sizes and margins: "f → Fix" in one colour
(a dimmed letter looked nicer but not the same), a dimmed `↵` where the menu
puts its `›`, for actions without preview, and the menu's selection bar, moved by the arrow keys and the pointer; Enter (or →) runs the
selected action, Shift inverts its preview. On a result the bar stays off
until an arrow key or the pointer moves it, so Enter keeps pasting. The list
scrolls after about six rows instead of growing the card, ending in a
faded half row as the menu does, and the key hints
below it are plain dimmed text. It replaced a two-column grid of tiles with
key caps on October 10, 2026: with many actions the grid got busy. There is
no search field: the letter is the search, and a second editable field would
clash with the text field.

The actions and key hints help while AI Edit is new and are noise after that.
`"compact": true` in the config hides both, leaving the text and a small "?
actions" that shows them again; the letters keep working. Paul preferred a
setting to an automatic count of opens.

Keys everywhere: Esc closes, Shift+letter runs and pastes without preview.
Compose mode has no window to paste into, so Enter copies instead. The same
holds for terminals, found in use: a terminal selection is only a highlight,
so Shift+Insert put the result after the text instead of over it. And in a
pane whose program takes the mouse (Claude Code under herdr) the drag selects
in that program, not in foot, so Ctrl+Insert copies nothing; Shift+drag makes
foot select.

Paul also noticed that a paste over text outside a text field (a web page,
a sent message) does nothing, so the result was lost. Wayland has no call
for "is the focus in a text field", but fcitx5 keeps an input context per
text field, for Wayland and X11 clients alike, and its DebugInfo marks the
focused one (`focus:1`); selected page text has none. Measured in Chromium
on Wayland and XWayland, with and without Chromium's IME flag. Capture
records the answer, and when it is "no" Enter copies; without fcitx5 the
answer is unknown and AI Edit pastes as before. Twice now the very first copy
in a freshly opened Chromium window caught nothing; repeated in the same
window it worked every time (0.13 s).

As built: letters act while the action list has the keyboard; Tab moves into
the text field and back (Enter there is a new line, as in any text field;
an earlier "Enter means done" felt wrong to Paul), and a paste
into the empty field goes straight to the actions. Esc in the free prompt field
closes only that field. The overlay sends the text it shows to `ai-edit run
<id> --diff` on stdin, so an edit in the field is what gets rewritten; a free
prompt runs as `ai-edit run -` with the instruction in `AI_EDIT_INSTRUCTION`.

Both fields are `TextEdit`s, also the prompt, which is drawn like the
kit's `TextField`. An editable `TextInput` (what `TextField` builds on) reads
the full clipboard text on every clipboard change to update `canPaste`, and
since the overlay stays loaded it did so all the time, through Qt's Wayland
reader, which has a one-second timeout per chunk but no size limit or overall
deadline: a clipboard owner could stall or exhaust the shell. `TextEdit` only
checks the offered types, so the clipboard is read only on an actual paste.
(Found in the marketplace review of 0.2.0, Qt 6.11/6.12.)

The diff is computed by `bin/ai-edit diff` (Python `difflib` on words with
whitespace tokens kept) and written as `diff.json`, a list of
`{"op": "equal|del|ins", "text": ...}` segments the QML renders.

## Open points

- Whether the result should stream into the overlay. At ~1 s a full result is
  fine; streaming makes the diff jump.
- A bar widget is deliberately absent. If a status indicator for the agent
  service is ever wanted, it is a separate, optional kind.
- An action as a Hyprland binding, so Super+Shift+F is Fix without the
  overlay's letter (raised October 10, 2026). `ai-edit capture && ai-edit run
  fix --insert` does it from a terminal, but not from a binding: `run` reads
  the selection only when stdin is a terminal, it takes the cold path (the
  warm pool lives in the shell) and a failure shows nothing. Preferred shape:
  `ai-edit open <id>` captures, summons the overlay and starts that action
  at once, so busy, diff, error and the warm pool are reused; `preview =
  false` pastes after the "Fix…" line, otherwise the diff waits for Enter.
  The binding then lists itself in Super+K.
- More agents than Claude and Codex: each needs a way to wait warm for one
  turn behind the stream-json protocol, as `bin/ai-edit-codex` does.
- Whether AI Edit could be part of Omarchy itself (raised October 10, 2026).
  The overlay needs no change: the shell's own overlays (emojis, clipboard,
  reminders) are QML plugins like this one, and Super+K is walker, not QML.
  What would change is the backend: core would follow `omarchy-default-agent`
  (eleven agents) with a wrapper per agent for the non-interactive call and
  the system-prompt flag; the `<text>`/`<rewrite>` convention lives in the
  prompt and ports as is. The warm pool is Claude-specific, so the "about a
  second" promise holds only where an agent keeps a process waiting (Codex
  app-server: 2.3 s median on Luna, see the comparison above; agents without
  such a mode fall back to a cold call). Config would move under
  `~/.config/omarchy`. Plan: first make the plugin agent-agnostic (`backend`
  follows the default agent, `ai-edit-<agent>` wrappers, warm where possible)
  and measure per agent; with that in hand, proposing it upstream is DHH's
  call, and the plugin system exists for exactly this.
