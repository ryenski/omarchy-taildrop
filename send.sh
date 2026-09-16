#!/bin/bash
# Shell side of the Taildrop overlay. The QML runs these subcommands and reads
# their stdout, so each one is also usable from a terminal.
#
#   send.sh stage-clipboard [--no-primary]
#       Copy what the user most likely wants to send into a staging file and
#       describe it as one JSON line:
#         {"kind":"text","source":"selection"|"clipboard","path":…,"chars":N,"preview":"…"}
#         {"kind":"image","source":"clipboard","path":…,"mime":"image/png","bytes":N}
#         {"kind":"none"}        nothing usable on either the selection or the clipboard
#         {"kind":"sensitive"}   a password manager marked the clipboard; refused
#       Order: highlighted text (primary selection), then a clipboard image,
#       then clipboard text. --no-primary skips the highlight.
#
#   send.sh send --target <dns-or-host> [--label <short name>] <file>...
#       Send each file in turn with `tailscale file cp`, reporting on stdout
#       as tab-separated lines:
#         begin  <count>  <label>
#         file   <i>  <basename>  <bytes>
#         progress  <i>  <pct>  <sent>            e.g. 42.6  2.03MiB
#         done   <i>
#         fail   <i>  <message>
#         end    <ok-count>  <failed-count>
#       and posting one notification at the end. Exit 0 when everything was
#       sent, 1 when any file failed, 2 on bad arguments.
#
#   send.sh stage-image [--back N]
#       Stage an image from Omarchy's clipboard history: the newest one, or
#       the Nth before it. Screenshots land there too, so this is "the last
#       image I copied or captured" even after copying text since. Same JSON
#       as stage-clipboard plus index/total/capturedAt; {"kind":"none"} when
#       the history has no images.
#
#   send.sh pick [--target <dns-or-host>]
#       Run the system file chooser, then summon the overlay again with the
#       chosen files (and the target, so the same tile stays under the
#       cursor). The overlay closes itself before calling this: it holds
#       exclusive keyboard focus on the overlay layer, which would leave the
#       chooser dialog underneath and unfocusable. Cancelling the chooser
#       summons the overlay back in clipboard mode.
#
#   send.sh setup [--remove]
#       First-run setup, run by the overlay each time the shell loads it.
#       Keeps the Nautilus "Send with Taildrop" item in sync with the copy
#       in this folder (restarting Nautilus when it changed, since it only
#       loads extensions at startup), and -- once ever -- appends the SUPER+SHIFT+T keybind
#       to ~/.config/hypr/bindings.lua when nothing binds the overlay yet and
#       the key is free. Idempotent and quiet unless it changes something.
#       --remove takes the Nautilus item out again (the keybind is yours to
#       delete; it is never touched after the first run).
#
# Staging lives under $XDG_RUNTIME_DIR so it is per-user, tmpfs, and gone at
# logout. The file is named clipboard.<ext> so the receiver sees that name.

set -o pipefail

STAGE_DIR="${XDG_RUNTIME_DIR:-/tmp}/omarchy-taildrop"
PLUGIN_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ID=$(jq -r '.id // empty' "$PLUGIN_DIR/manifest.json" 2>/dev/null)
: "${PLUGIN_ID:=ryenski.taildrop}"

usage() {
  sed -n '2,51p' "$0" >&2
  exit 2
}

# Prints the mime types on offer for the given selection (--primary or empty),
# or nothing when that selection is empty.
list_types() {
  wl-paste $1 --list-types 2>/dev/null || true
}

has_text() {
  grep -q '^text/' <<<"$1" || grep -qx 'UTF8_STRING' <<<"$1" || grep -qx 'STRING' <<<"$1"
}

# The first image mime we can hand to Taildrop as-is, preferring PNG.
image_mime() {
  local mime
  for mime in image/png image/jpeg image/webp image/gif image/bmp image/tiff; do
    if grep -qx "$mime" <<<"$1"; then
      echo "$mime"
      return 0
    fi
  done
  return 1
}

reset_stage() {
  rm -rf "$STAGE_DIR"
  mkdir -p "$STAGE_DIR"
  chmod 700 "$STAGE_DIR"
}

# Writes the text on the given selection to clipboard.txt. Fails when the
# selection holds nothing but whitespace, which is what a stale or empty
# highlight looks like.
stage_text() {
  local selection="$1" source="$2" file="$STAGE_DIR/clipboard.txt"
  if ! timeout 2s wl-paste $selection --type text --no-newline >"$file" 2>/dev/null \
    || [[ -z $(tr -d '[:space:]' <"$file" | head -c 1) ]]; then
    rm -f "$file"
    return 1
  fi
  jq -cn --arg source "$source" --arg path "$file" \
    --argjson chars "$(wc -m <"$file")" \
    --arg preview "$(head -c 400 "$file" | tr -s '[:space:]' ' ' | head -c 120)" \
    '{kind:"text", source:$source, path:$path, chars:$chars, preview:$preview}'
}

stage_image() {
  local mime="$1" ext file
  ext=${mime#image/}
  [[ $ext == jpeg ]] && ext=jpg
  file="$STAGE_DIR/clipboard.$ext"
  if ! timeout 5s wl-paste --type "$mime" >"$file" 2>/dev/null || [[ ! -s $file ]]; then
    rm -f "$file"
    return 1
  fi
  jq -cn --arg path "$file" --arg mime "$mime" --argjson bytes "$(stat -c %s "$file")" \
    '{kind:"image", source:"clipboard", path:$path, mime:$mime, bytes:$bytes}'
}

HISTORY_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/clipboard-history.json"

stage_image() {
  local back=0 total=0 index=0 line path mime captured ext file
  local -a entries=()

  while (( $# )); do
    case "$1" in
      --back) back="${2:-0}"; shift 2 ;;
      *) usage ;;
    esac
  done
  [[ $back =~ ^[0-9]+$ ]] || usage

  # Newest first, one entry per line; skip images whose file has since been
  # pruned from the cache.
  if [[ -f $HISTORY_FILE ]]; then
    while IFS=$'\t' read -r path mime captured; do
      [[ -f $path ]] && entries+=("$path"$'\t'"$mime"$'\t'"$captured")
    done < <(jq -r '.[] | select(.type == "image" and (.path // "") != "")
                        | [.path, (.mime // "image/png"), (.capturedAt // "")] | @tsv' "$HISTORY_FILE" 2>/dev/null)
  fi
  total=${#entries[@]}
  if (( total == 0 )); then
    echo '{"kind":"none"}'
    return 0
  fi

  # Stepping past the oldest wraps around to the newest.
  index=$(( back % total ))
  IFS=$'\t' read -r path mime captured <<<"${entries[$index]}"

  ext=${mime#image/}
  [[ $ext == jpeg ]] && ext=jpg
  reset_stage
  file="$STAGE_DIR/clipboard.$ext"
  cp -- "$path" "$file" || { echo '{"kind":"none"}'; return 0; }

  jq -cn --arg path "$file" --arg mime "$mime" --arg captured "$captured" \
    --argjson bytes "$(stat -c %s "$file")" --argjson index "$index" --argjson total "$total" \
    '{kind:"image", source:"history", path:$path, mime:$mime, bytes:$bytes, index:$index, total:$total, capturedAt:$captured}'
}

stage_clipboard() {
  local use_primary=1 types primary_types mime
  [[ ${1:-} == --no-primary ]] && use_primary=0

  types=$(list_types "")
  if grep -qx 'x-kde-passwordManagerHint' <<<"$types"; then
    echo '{"kind":"sensitive"}'
    return 0
  fi

  reset_stage

  if (( use_primary )); then
    primary_types=$(list_types --primary)
    if has_text "$primary_types" && stage_text --primary selection; then
      return 0
    fi
  fi

  if mime=$(image_mime "$types") && stage_image "$mime"; then
    return 0
  fi

  if has_text "$types" && stage_text "" clipboard; then
    return 0
  fi

  echo '{"kind":"none"}'
}

emit() {
  local IFS=$'\t'
  printf '%s\n' "$*"
}

notify() {
  # Best effort: the transfer outcome is already reported on stdout.
  omarchy-notification-send -g "󰒊" "$@" >/dev/null 2>&1 || true
}

# Runs `tailscale file cp` for one file. Tailscale only draws its progress
# meter on a terminal, so give it a pty through util-linux `script` and turn
# the carriage-return-separated redraws into progress lines. Without `script`
# the transfer still happens, just without percentages.
send_one() {
  local index="$1" file="$2" target="$3"
  local -a cmd=(tailscale file cp --update-interval=250ms -- "$file" "$target:")
  local chunk line last_pct="" message="" status

  if command -v script >/dev/null; then
    local quoted
    quoted=$(printf '%q ' "${cmd[@]}")
    while IFS= read -r -d $'\r' chunk || [[ -n $chunk ]]; do
      # The subshell's exit code rides on its last line.
      if [[ $chunk == *__exit=* ]]; then
        status=${chunk##*__exit=}
        status=${status%%[^0-9]*}
        chunk=${chunk%__exit=*}
      fi
      # Strip cursor-control sequences and stray newlines from the redraw.
      chunk=$(sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' <<<"${chunk//$'\n'/ }")
      [[ -n ${chunk// /} ]] || continue
      if [[ $chunk =~ [[:space:]]([0-9.]+[KMGT]?i?B)[[:space:]]+[0-9.]+[KMGT]?i?B/s[[:space:]]+([0-9]+(\.[0-9]+)?)%[[:space:]]+ETA ]]; then
        [[ ${BASH_REMATCH[2]} == "$last_pct" ]] && continue
        last_pct=${BASH_REMATCH[2]}
        emit progress "$index" "$last_pct" "${BASH_REMATCH[1]}"
      else
        message=$chunk
      fi
    done < <(script -qefc "$quoted" /dev/null 2>&1; echo "__exit=$?")
    [[ $status =~ ^[0-9]+$ ]] || status=1
  else
    message=$("${cmd[@]}" 2>&1)
    status=$?
  fi

  message=$(sed -E 's/^[0-9]{4}\/[0-9]{2}\/[0-9]{2} [0-9:]+ //' <<<"$message" | tr -s '[:space:]' ' ')
  message=${message## }
  message=${message%% }

  if (( status == 0 )); then
    emit done "$index"
    return 0
  fi
  emit fail "$index" "${message:-Transfer failed}"
  return 1
}

send_files() {
  local target="" label="" file index=0 ok=0 failed=0 what last_error=""
  local -a files=()

  while (( $# )); do
    case "$1" in
      --target) target="${2:-}"; shift 2 ;;
      --label) label="${2:-}"; shift 2 ;;
      --) shift; files+=("$@"); break ;;
      -*) usage ;;
      *) files+=("$1"); shift ;;
    esac
  done

  [[ -n $target && ${#files[@]} -gt 0 ]] || usage
  [[ -n $label ]] || label=${target%%.*}

  for file in "${files[@]}"; do
    if [[ ! -f $file || ! -r $file ]]; then
      echo "send.sh: not a readable file: $file" >&2
      exit 2
    fi
  done

  emit begin "${#files[@]}" "$label"
  for file in "${files[@]}"; do
    emit file "$index" "${file##*/}" "$(stat -c %s -- "$file")"
    if send_one "$index" "$file" "$target"; then
      ((ok++))
    else
      ((failed++))
    fi
    ((index++))
  done
  emit end "$ok" "$failed"

  if (( ${#files[@]} == 1 )); then
    what=${files[0]##*/}
  else
    what="${#files[@]} files"
  fi

  if (( failed == 0 )); then
    notify "Sent to $label" "$what"
    return 0
  fi
  if (( ok == 0 )); then
    notify -u critical "Could not send to $label" "$what"
  else
    notify -u critical "Sent $ok of ${#files[@]} files to $label" "$failed failed"
  fi
  return 1
}

summon() {
  omarchy-shell shell summon "$PLUGIN_ID" "$1" >/dev/null
}

pick_files() {
  local target="" picked status=0
  local -a files=()

  while (( $# )); do
    case "$1" in
      --target) target="${2:-}"; shift 2 ;;
      *) usage ;;
    esac
  done

  picked=$(omarchy-file-select --title "Send with Taildrop" --multiple) || status=$?

  case $status in
    0)
      # One path per line; jq builds the array so odd characters survive.
      readarray -t files <<<"$picked"
      summon "$(jq -cn --arg target "$target" \
        '{files: $ARGS.positional, source: "chooser", target: $target}' --args "${files[@]}")"
      ;;
    1)
      summon "$(jq -cn --arg target "$target" '{target: $target}')"
      ;;
    *)
      notify -u critical "Could not open the file chooser" "Taildrop needs the desktop file portal"
      summon "$(jq -cn --arg target "$target" '{target: $target}')"
      return 1
      ;;
  esac
}

EXT_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nautilus-python/extensions"
EXT_FILE="$EXT_DIR/taildrop.py"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-taildrop"
BINDINGS="${XDG_CONFIG_HOME:-$HOME/.config}/hypr/bindings.lua"
BIND_KEY="SUPER + SHIFT + T"
BIND_COMMAND="omarchy-shell shell toggle $PLUGIN_ID"

setup_nautilus() {
  python3 -c 'import gi; gi.require_version("Nautilus", "4.1")' 2>/dev/null || return 1
  if [[ -f $EXT_FILE ]] && cmp -s "$PLUGIN_DIR/nautilus/taildrop.py" "$EXT_FILE"; then
    return 1
  fi
  mkdir -p "$EXT_DIR"
  install -m 0644 "$PLUGIN_DIR/nautilus/taildrop.py" "$EXT_FILE"
  # nautilus-python loads extensions once at startup, so a running Nautilus
  # keeps the old module (or none) until it restarts. Only on a real change,
  # which means install and update.
  if pgrep -x nautilus >/dev/null; then
    nautilus -q 2>/dev/null || true
    NAUTILUS_RESTARTED=1
  fi
}

# True when Hyprland already has SUPER+SHIFT+T bound to anything. modmask 65
# is SUPER (64) + SHIFT (1).
bind_key_taken() {
  hyprctl binds -j 2>/dev/null | jq -e '.[] | select(.modmask == 65 and (.key | ascii_downcase) == "t")' >/dev/null 2>&1
}

setup_keybind() {
  local marker="$STATE_DIR/keybind-offered"
  [[ -f $marker ]] && return 1
  [[ -f $BINDINGS ]] || return 1
  mkdir -p "$STATE_DIR"
  if grep -qF "$BIND_COMMAND" "$BINDINGS"; then
    touch "$marker"
    return 1
  fi
  if bind_key_taken; then
    touch "$marker"
    notify "Taildrop has no shortcut yet" "$BIND_KEY is already in use. Add a bind for: $BIND_COMMAND"
    return 1
  fi
  cat >>"$BINDINGS" <<LUA

-- Taildrop share sheet ($PLUGIN_ID plugin).
o.bind("$BIND_KEY", "Send via Taildrop", "$BIND_COMMAND")
hl.layer_rule({ match = { namespace = "omarchy-taildrop" }, no_anim = true, animation = "none" })
LUA
  touch "$marker"
}

setup() {
  local changed=()
  if [[ ${1:-} == --remove ]]; then
    if [[ -f $EXT_FILE ]]; then
      rm -f "$EXT_FILE"
      echo "Removed $EXT_FILE"
    fi
    return 0
  fi
  NAUTILUS_RESTARTED=0
  if setup_nautilus; then
    if (( NAUTILUS_RESTARTED )); then
      changed+=("Nautilus menu item installed (Nautilus was restarted to load it)")
    else
      changed+=("Nautilus menu item installed")
    fi
  fi
  setup_keybind && changed+=("$BIND_KEY added to ~/.config/hypr/bindings.lua")
  (( ${#changed[@]} )) || return 0
  printf '%s\n' "${changed[@]}"
  notify "Taildrop is set up" "$(printf '%s. ' "${changed[@]}")"
}

case "${1:-}" in
  stage-clipboard)
    shift
    stage_clipboard "$@"
    ;;
  send)
    shift
    send_files "$@"
    ;;
  stage-image)
    shift
    stage_image "$@"
    ;;
  pick)
    shift
    pick_files "$@"
    ;;
  setup)
    shift
    setup "$@"
    ;;
  *)
    usage
    ;;
esac
