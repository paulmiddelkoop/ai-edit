# AI Edit

**Your words, a little better. Right where you're typing.**

Fix a typo in Slack, untangle an email in Gmail or translate a message before
you send it. Select your text, press **Super+E** and choose an action. AI Edit
shows what changed; **Enter** puts the result back.

An [Omarchy](https://omarchy.org) plugin for the moments when you know what you
want to say and just want a hand saying it.

![Fixing typos in a Gmail message: select the text, press Super+E and F, review the red and green changes, press Enter to paste the corrected text](docs/demo/fix.gif)

- **Stay in your app.** Edit the text you're already writing, without opening
  a chat and copying the answer back.
- **Keep your voice.** Fix corrects mistakes; Improve clears up muddled
  sentences. Both are instructed to preserve your wording and tone.
- **See every edit.** Removed words are red, additions are green. Review the
  changes before accepting them, or skip the preview when you want to.
- **Feels like part of Omarchy.** Matches your theme and uses familiar
  keyboard controls. Press an action's letter, or use the arrow keys and Enter.
- **Fast.** Short rewrites typically take about one to two seconds with
  Claude, about three with Codex.
- **Uses the coding agent you already have.** Claude Code or Codex, with your
  existing subscription. No separate API key needed.

## Install

You'll need **Omarchy 4.0 or newer** and **Claude Code or Codex logged in**.
AI Edit uses the agent Omarchy is set to (`omarchy default agent`), or
Claude Code when that is another agent; `agent` in the config overrides it.
Run `claude` or `codex` once if you haven't signed in yet.

Install the plugin:

```bash
omarchy plugin add https://github.com/paulmiddelkoop/ai-edit --enable
```

Add this shortcut to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + E", "Edit text with AI", os.getenv("HOME") .. "/.config/omarchy/plugins/ai-edit/bin/ai-edit open")
```

Super+E is free in a default Omarchy setup; any other key works just as well,
as long as it runs `ai-edit open`.

**Try it:** select a sentence in a text field, press **Super+E**, then **f**
to fix it. Review the changes and press **Enter**.

### Remove

Delete the shortcut line from `bindings.lua` and run:

```bash
omarchy plugin remove ai-edit
rm -rf ~/.config/ai-edit ~/.local/state/ai-edit   # your config and the agent's working folder
```

## Choose an action

| Key | Action | What it does |
| --- | --- | --- |
| **f** | Fix | Correct spelling, grammar and punctuation. Keep your phrasing. |
| **i** | Improve | Untangle sentences and remove repetition. Keep your voice. |
| **s** | Shorten | Cut repetition and filler. Keep the details, requests and tone. |
| **e** | English | Translate into English, keeping the tone of the original. |
| **c** | Custom | Give your own instruction: "make it friendlier", "more formal" or "translate into Swedish". |

For translations and custom instructions, the preview shows the full result
without highlighting individual changes.

You can also build on a result. Shorten a message, then press **c** and type
"make it friendlier", or press **e** to translate it. **?** shows the actions
on a result and **Backspace** takes you back one step.

![Shortening a Gmail message with S, then pressing C and typing "Make it friendlier" to refine the shortened result before pasting it with Enter](docs/demo/steer.gif)

**Nothing selected?** Super+E opens an empty field. Type something and press
Tab, or paste your text, then choose an action. The result goes to your
clipboard. Text selected on a web page, in a sent message or in a terminal
also gets copied instead of pasted over.

## Keyboard shortcuts

These shortcuts apply when the actions or result have focus. In the text
field, type normally and press Tab to return to the actions.

| Key | What it does |
| --- | --- |
| Action letter | Run that action; on a result, run it on that result (Shorten, then English) |
| Shift+letter | Skip the preview and paste or copy the result |
| c | Write a custom instruction |
| Tab | Switch between the text and the actions, before an action runs |
| Enter | Accept the result: paste over your selection, or copy in clipboard mode |
| y | Copy the result |
| Backspace or ← | Go back one step |
| Esc | Close; in the custom instruction field, dismiss that field first |
| ? | Show or hide actions and key hints |

Shift inverts your preview setting, so it brings the preview back if you've
turned it off. After pasting, your application's Undo brings the original
text back.

In terminal programs that use the mouse, hold Shift while dragging to select
text with the terminal itself.

## Make it yours

The defaults work as they are. To change them, copy the [default config](config.toml):

```bash
mkdir -p ~/.config/ai-edit
cp ~/.config/omarchy/plugins/ai-edit/config.toml ~/.config/ai-edit/config.toml
```

Settings you leave out keep their defaults. Changes apply the next time you
open AI Edit.

| Setting | Default | What it does |
| --- | --- | --- |
| `agent` | Omarchy's | The coding agent that rewrites: `claude` or `codex`. Left out, the agent Omarchy is set to, or `claude` when that is another one. |
| `model` | per agent | Model for actions that don't name one. Claude: `sonnet` (default), `haiku` or `opus`. Codex: `gpt-6.1-sol` (default) or another model `codex` lists. |
| `fast` | `true` | Codex only: Fast mode, about half a second quicker per rewrite, at the cost of more of your plan's usage. |
| `preview` | `true` | Show the result before pasting it. Shift with the letter does the opposite. |
| `compact` | `false` | Hide the action list and key hints; the letters keep working and **?** shows them. |
| `width` | `560` | Width of the overlay. |
| `idle_timeout` | `30` | Minutes without a rewrite before the waiting agent process stops to free its memory (about 170 MB per model for Claude, 120 MB for Codex). The next rewrite then takes a few seconds longer. `0` keeps it ready all the time. |

### Your own actions

Each `[[action]]` table adds a letter to the list. For example:

```toml
[[action]]
key = "w"
label = "Warmer"
instruction = "Make the tone a little warmer and friendlier. Keep the meaning and the length."
```

Now **w** warms up your selection. If you define actions, your list replaces
the shipped one as a whole, so keep the ones you want from the copied config.

| Field | Required | What it does |
| --- | --- | --- |
| `key` | yes | One lowercase letter, unique. Keep **c** free for custom instructions. |
| `label` | yes | The name in the list and in the result's header. |
| `instruction` | yes | What to do with the text. Write it as you would to a careful editor: what to change and what to leave alone. Keeping the language, no preamble and no em dashes are already asked for. |
| `model` | no | Use this model for this action only. |
| `preview` | no | Overrides the global `preview` for this action. |
| `diff` | no | `false` previews plain text instead of what changed; right for translations. |
| `id` | no | Name for `ai-edit run <id>` from a terminal; by default the label in lower case. |

## What happens to your text

AI Edit sends the text you choose to Claude through Claude Code, or to OpenAI
through Codex, using your existing account and its usage limits. Each rewrite
starts fresh, with no conversation history, tools or MCP servers, and no saved
session. Codex runs in a separate home in your runtime directory that shares
only your login, so your Codex instructions, skills and plugins stay out of
the request; AI Edit checks this before each new Codex version is used.

Locally, text stays in your private runtime directory, never in command-line
arguments or AI Edit logs. AI Edit restores the clipboard after capturing
and pasting, and marks pasted results as sensitive so Omarchy's clipboard
history skips them. Choosing **Copy** deliberately puts the result on your
clipboard.

## Under the hood

A small shell script handles selection and paste, a service inside the
Omarchy shell keeps the agent ready (about 170 MB for Claude Code, 120 MB for
Codex, stopped after 30 minutes without use), and a QML overlay shows the
result. From a terminal, `ai-edit run` starts the agent fresh, which takes a
second or two longer.

See the [design notes](docs/design.md) for the architecture and measurements.
To run the tests without a compositor or agent requests:

```bash
bin/ai-edit selftest
tests/claude-test
tests/codex-test
```

## Roadmap

- **More coding agents.** The other agents Omarchy can set up, beyond Claude
  Code and Codex.
- **An action on its own key**, such as Super+Shift+F to fix the selection
  without opening the list first.

## Credits & license

The Wayland selection and paste handling builds on
[OmaPen](https://github.com/vladimirstempel/omapen) by stempelv. Its notes on
Hyprland saved a lot of rediscovery, and AI Edit's system prompt started from
OmaPen's (Copyright (c) 2026 stempelv, MIT License).

AI Edit is [MIT licensed](LICENSE).
