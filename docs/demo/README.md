# The README demos

Three GIFs, all real takes in a Gmail compose window with the shipped actions:

- `fix.gif` (top of the README): select, Super+E, F, the diff, Enter.
- `chain.gif` (next to chaining): Shorten a wordy to-do message, then C and
  "Use bullet points" on that result, Enter.
- `translate.gif` (next to the actions): a Spanish message, E, the English
  text, Enter.

```bash
docs/demo/record.sh /run/user/$UID/ai-edit-demo/fix fix       # about 25 s
docs/demo/record.sh /run/user/$UID/ai-edit-demo/chain chain   # about 35 s
docs/demo/record.sh /run/user/$UID/ai-edit-demo/translate translate   # about 20 s
CUT_TOP=40 CUT_BOTTOM=298 docs/demo/make-gif.sh /run/user/$UID/ai-edit-demo/fix "$PWD/docs/demo/fix.gif"
CUT_TOP=40 CUT_BOTTOM=298 docs/demo/make-gif.sh /run/user/$UID/ai-edit-demo/chain "$PWD/docs/demo/chain.gif"
CUT_TOP=40 CUT_BOTTOM=298 docs/demo/make-gif.sh /run/user/$UID/ai-edit-demo/translate "$PWD/docs/demo/translate.gif"
```

Before recording, open a Gmail compose pop-out (Shift+click Compose) from an
account that may be shown, with To empty and the cursor in the body. The
recording takes over the desktop for its duration: it moves your own
`~/.config/ai-edit/config.toml` aside so the shipped actions show, switches
to Tokyo Night (Omarchy's default), turns on do-not-disturb, floats the
pop-out above the overlay and pastes the text. It refuses a body that is not
empty. Afterwards it empties the body it filled and puts everything back,
the window's place and tiling included, also when it aborts. It aborts before any key that
would reach Gmail when the overlay is not open, and with To empty nothing can
be sent. A draft stays behind in Gmail; discard it.

The crop is the pop-out window, minus Zen's address bar (`CUT_TOP`) and the
empty space and toolbar below the overlay (`CUT_BOTTOM`), in logical pixels.
Check a frame of a new take before committing
(`ffmpeg -ss <t> -i raw.mp4 -frames:v 1 f.png`), and look at the whole loop
for anything private.

Choices, made on October 13, 2026:

- A real app everybody knows, not a mock-up; everyday texts, no jokes; the
  keys as keycaps (`caption.py`) on a strip below the picture, so they never
  cover the text or the overlay's hints.
- Short loops rather than one long one: the hero shows the core gesture
  and the diff; the second shows building on a result and steering it with
  your own words. Backspace and compose mode are left to the text.
- The texts were rehearsed against the real model: Fix gave the same three
  corrections every time. "Warmer, but still brief" invented a fun day out
  and grew the text; "Make it friendlier" did not.
- The real waiting time is kept; only the setup is cut.

Changed on October 16, 2026: the second loop shortened a message and then
made it longer again with "Make it friendlier", so its second step undid the
first, and a custom instruction shows plain text, so the viewer saw the text
swap without seeing why. It became Shorten, then "Use bullet points": each
step has a visible reason and the list shows what the instruction did. The
texts were rehearsed against Sonnet with the shipped instructions: the
wordy message gave the same shortened text twice (dropping "So basically",
"really", "which has to happen" and "and then also") and a three-item list;
a shorter wordy message barely changed, so it would show little. Translation
got a loop of its own rather than a third step: from Spanish, a language
most readers recognize, not Dutch, typed quickly without capitals, accents
or punctuation, so the loop also shows English that comes out clean; all
three runs gave the same sentences with small differences in wording. One short loop per point, not one long
one: a GIF has no controls, so a reader would wait for the part they want.

Pitfalls met on the way:

- Keys are sent with `hyprctl dispatch hl.dsp.send_key_state`, as
  `bin/ai-edit` does. wtype leaves its own keymap in the client, after which
  Zen read the compositor's Ctrl+C as another key; and `wtype -M ctrl plus`
  types p, l, u, s with Ctrl held (print, address bar, source, save).
- A result is ready when `result.txt` is newer than the key, not when it
  exists: the previous one stays while a new rewrite runs.
- The marks are placed on the video's own timeline from the moment the
  recorder stopped, since it starts filming a moment after it is launched.
- `palettegen` with `stats_mode=diff` dropped the green of the insertions;
  `stats_mode=full` keeps it.
