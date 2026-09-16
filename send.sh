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
#   send.sh pick [--target <dns-or-host>]
#       Run the system file chooser, then summon the overlay again with the
#       chosen files (and the target, so the same tile stays under the
#       cursor). The overlay closes itself before calling this: it holds
#       exclusive keyboard focus on the overlay layer, which would leave the
#       chooser dialog underneath and unfocusable. Cancelling the chooser
#       summons the overlay back in clipboard mode.
#
# Staging lives under $XDG_RUNTIME_DIR so it is per-user, tmpfs, and gone at
# logout. The file is named clipboard.<ext> so the receiver sees that name.

set -o pipefail

STAGE_DIR="${XDG_RUNTIME_DIR:-/tmp}/omarchy-taildrop"
PLUGIN_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN_ID=$(jq -r '.id // empty' "$PLUGIN_DIR/manifest.json" 2>/dev/null)
: "${PLUGIN_ID:=io.github.ryenski.taildrop}"

usage() {
  sed -n '2,35p' "$0" >&2
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

case "${1:-}" in
  stage-clipboard)
    shift
    stage_clipboard "$@"
    ;;
  send)
    shift
    send_files "$@"
    ;;
  pick)
    shift
    pick_files "$@"
    ;;
  *)
    usage
    ;;
esac
