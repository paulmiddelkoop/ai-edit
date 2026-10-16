#!/bin/bash
# Records one README demo clip in a Gmail compose pop-out, then puts the theme,
# notifications, config, window, focus and clipboard back. Writes raw.mp4 and
# marks (each key's time in the video, and its caption) to the directory given.
#
# Before: a Gmail compose pop-out ("New Message") with an empty To field, from
# an account that may be shown, with the cursor in its body.
# Usage: docs/demo/record.sh <work dir> fix|chain|translate
set -u
OUT=$(mkdir -p "${1:?work dir}" && cd "$1" && pwd)
CLIP=${2:?clip: fix, chain or translate}
S=$(cd "$(dirname "$0")/../.." && pwd)/bin/ai-edit
ST=$XDG_RUNTIME_DIR/ai-edit
USER_CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}/ai-edit/config.toml
case $CLIP in
  fix) MSG="Sorry for teh late reply. Lets meet tomorow at 3 if that works for you." ;;
  chain) MSG="So basically, before the party we really still need to book the venue, which has to happen by Friday, then send out all the invitations by Monday, and then also confirm the final guest count by Wednesday." ;;
  translate) MSG="hola alex perdona el retraso el informe estara listo el jueves pero todavia me faltan las cifras de ventas de marzo me las puedes mandar mañana" ;;
  *) echo "unknown clip $CLIP"; exit 2 ;;
esac
# The compose window, in logical pixels, centred over the overlay so the
# text sits just above it and one crop holds both.
WIN_W=720 WIN_H=760

now() { date +%s.%N; }
# Keys go through the compositor, as bin/ai-edit sends them: wtype leaves its
# own keymap behind in the client, after which those keys arrive as others.
key() {
  hyprctl dispatch "hl.dsp.send_key_state({ mods = '$1', key = '$2', state = 'down' })" >/dev/null
  pause 0.03
  hyprctl dispatch "hl.dsp.send_key_state({ mods = '$1', key = '$2', state = 'up' })" >/dev/null
  pause 0.08
}
type_text() {
  local text=$1 i c
  for ((i = 0; i < ${#text}; i++)); do
    c=${text:i:1}
    case $c in
      ' ') key '' space ;;
      [A-Z]) key SHIFT "${c,}" ;;
      *) key '' "$c" ;;
    esac
  done
}
mark() { printf '%s|%s\n' "$(now)" "$1" >>"$OUT/marks.wall"; }
overlay() { hyprctl layers -j | jq -e '[.. | objects | select(.namespace? == "ai-edit")] | length > 0' >/dev/null; }
on_compose() { [[ $(hyprctl activewindow -j | jq -r .address) == "$W" ]]; }
abort() { echo "ABORT: $*"; exit 1; }
pause() { python3 -c "import time; time.sleep($1)"; }
# A rewrite is done when the overlay has stored a result newer than the key.
wait_result() {
  local since=$1
  for _ in $(seq 300); do
    if [[ -s $ST/result.txt ]] && awk -v m="$(stat -c %.Y "$ST/result.txt")" -v s="$since" 'BEGIN { exit !(m > s) }'; then
      pause 0.4
      return 0
    fi
    pause 0.1
  done
  return 1
}

W=$(hyprctl clients -j | jq -r '[.[] | select(.title | test("^(New Message|Compose)"; "i"))] | if length == 1 then .[0].address else "" end')
[[ -n $W ]] || abort "no single Gmail compose pop-out (title starting with New Message)"
back=$(hyprctl activewindow -j | jq -r .address)
THEME_BACK=$(omarchy theme current | tr '[:upper:] ' '[:lower:]-')
SAVE=$(mktemp -d "$XDG_RUNTIME_DIR/ai-edit-demo.XXXXXX") || abort "no private directory"
types=$(wl-paste -l 2>/dev/null); t=$(head -1 <<<"$types")
if [[ -n $t ]] && ! wl-paste -n -t "$t" >"$SAVE/clipboard"; then rm -rf "$SAVE"; abort "the clipboard could not be saved"; fi
sensitive=""; grep -qx 'x-kde-passwordManagerHint' <<<"$types" && sensitive=--sensitive
DND_BACK=$(omarchy-shell notifications dndState)
read -r FLOAT_BACK AT_BACK SIZE_BACK < <(hyprctl clients -j |
  jq -r --arg w "$W" '.[] | select(.address == $w) | "\(.floating) \(.at | join(",")) \(.size | join(","))"')
pasted=""
rec=""

restore() {
  # The recorder stops first, or it would film the user's own windows coming back.
  if [[ -n $rec ]]; then kill -INT "$rec" 2>/dev/null; wait "$rec" 2>/dev/null; fi
  omarchy-shell shell hide ai-edit >/dev/null
  hyprctl dispatch "hl.dsp.focus({ window = 'address:$W' })" >/dev/null; pause 0.4
  # Empty the body again, so no draft with the demo text stays behind; only
  # text this script put there, in a body that was empty before.
  if [[ -n $pasted ]] && on_compose; then key CTRL a; key '' BackSpace; fi
  if [[ $FLOAT_BACK == false ]]; then
    hyprctl dispatch "hl.dsp.window.float({ action = \"disable\" })" >/dev/null
  else
    hyprctl dispatch "hl.dsp.window.resize({ x = ${SIZE_BACK%,*}, y = ${SIZE_BACK#*,} })" >/dev/null
    hyprctl dispatch "hl.dsp.window.move({ x = ${AT_BACK%,*}, y = ${AT_BACK#*,} })" >/dev/null
  fi
  [[ -e $SAVE/config.toml || -L $SAVE/config.toml ]] && mv "$SAVE/config.toml" "$USER_CONFIG"
  omarchy-shell notifications setDnd "$DND_BACK" >/dev/null
  omarchy theme set "$THEME_BACK" >/dev/null 2>&1
  hyprctl dispatch "hl.dsp.focus({ window = 'address:$back' })" >/dev/null
  if [[ -n $t ]]; then wl-copy -t "$t" $sensitive <"$SAVE/clipboard" >/dev/null 2>&1; else wl-copy --clear; fi
  rm -rf "$SAVE"
}
trap restore EXIT
trap 'exit 1' INT TERM
rm -f "$OUT/marks.wall" "$OUT/marks" "$OUT/raw.mp4"

# The shipped actions, not the user's own; moved back by restore.
[[ -e $USER_CONFIG || -L $USER_CONFIG ]] && mv "$USER_CONFIG" "$SAVE/config.toml"
[[ $("$S" actions | jq -r 'map(.key) | join("")') == fise ]] || abort "the shipped actions did not load"
# Tokyo Night is Omarchy's default theme, so the overlay looks as it does out of the box.
omarchy theme set tokyo-night >/dev/null 2>&1; pause 6
omarchy-shell notifications setDnd on >/dev/null

monitor=$(hyprctl monitors -j | jq -c '.[] | select(.focused)')
read -r MON MX MY MW MH < <(jq -r '[.name, .x, .y, (.width / .scale | floor), (.height / .scale | floor)] | @tsv' <<<"$monitor")
WX=$((MX + (MW - WIN_W) / 2)) WY=$((MY + MH / 2 - 330))
hyprctl dispatch "hl.dsp.focus({ window = 'address:$W' })" >/dev/null; pause 0.4
on_compose || abort "the compose window has no focus"
[[ $(hyprctl activewindow -j | jq -r .floating) == true ]] || hyprctl dispatch 'hl.dsp.window.float({ action = "enable" })' >/dev/null
hyprctl dispatch "hl.dsp.window.resize({ x = $WIN_W, y = $WIN_H })" >/dev/null
hyprctl dispatch "hl.dsp.window.move({ x = $WX, y = $WY })" >/dev/null
pause 0.5

key CTRL a; pause 0.3
"$S" capture
[[ -z $(jq -r .text "$ST/session.json") ]] || abort "the body is not empty"
pasted=1
printf "%s" "$MSG" | wl-copy --sensitive >/dev/null 2>&1; pause 0.3; key CTRL v; pause 0.5
key CTRL a; pause 0.3
"$S" capture
[[ $(jq -r .text "$ST/session.json") == "$MSG" && $(jq -r .editable "$ST/session.json") == yes ]] ||
  abort "the body did not hold the message"
# The take starts unselected, so the viewer sees Ctrl+A select the text.
key '' End
hyprctl dispatch "hl.dsp.cursor.move_to_corner({ corner = 0 })" >/dev/null
hyprctl clients -j | jq -c --arg w "$W" '.[] | select(.address == $w) | {at, size}' >"$OUT/window.json"
printf '%s\n' "$monitor" >"$OUT/monitor.json"

wf-recorder -o "$MON" -r 30 -f "$OUT/raw.mp4" >/dev/null 2>&1 & rec=$!
pause 2
on_compose || abort "focus moved"
mark "ctrl-a|Select text|Ctrl A"; key CTRL a; pause 1.2
mark "super-e|Open AI Edit|Super E"; "$S" open; pause 1.6
# Keys go to the overlay only; without it they would reach Gmail.
overlay || abort "overlay did not open"
case $CLIP in
  fix)
    mark "f|Fix|F"; since=$(now); key '' f
    wait_result "$since" || abort "no result"
    pause 3.5
    overlay || abort "overlay closed"
    mark "enter|Paste back|Enter"; key '' Return; pause 3.2
    ;;
  chain)
    mark "s|Cut the filler|S"; since=$(now); key '' s
    wait_result "$since" || abort "no result"
    pause 3
    overlay || abort "overlay closed"
    mark "c|Make it easy to scan|C"; key '' c; pause 0.5
    type_text "Use bullet points"; pause 0.5
    mark "enter1|Apply|Enter"; since=$(now); key '' Return
    wait_result "$since" || abort "no result"
    pause 3
    overlay || abort "overlay closed"
    mark "enter2|Paste back|Enter"; key '' Return; pause 3.2
    ;;
  translate)
    mark "e|Translate to English|E"; since=$(now); key '' e
    wait_result "$since" || abort "no result"
    pause 3.5
    overlay || abort "overlay closed"
    mark "enter|Paste back|Enter"; key '' Return; pause 3.2
    ;;
esac
stop=$(now)
kill -INT "$rec"; wait "$rec" 2>/dev/null; rec=""
# wf-recorder starts filming a moment after it is launched; the end of the
# file is the moment it stopped, so the marks are placed from there.
duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT/raw.mp4")
awk -F'|' -v stop="$stop" -v dur="$duration" '{ printf "%.2f|%s|%s|%s\n", $1 - (stop - dur), $2, $3, $4 }' \
  "$OUT/marks.wall" >"$OUT/marks"
printf '%.2f|end||\n' "$duration" >>"$OUT/marks"
cat "$OUT/marks"
