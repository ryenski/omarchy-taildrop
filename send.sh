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
# Staging lives under $XDG_RUNTIME_DIR so it is per-user, tmpfs, and gone at
# logout. The file is named clipboard.<ext> so the receiver sees that name.

set -o pipefail

STAGE_DIR="${XDG_RUNTIME_DIR:-/tmp}/omarchy-taildrop"

usage() {
  sed -n '2,15p' "$0" >&2
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

case "${1:-}" in
  stage-clipboard)
    shift
    stage_clipboard "$@"
    ;;
  *)
    usage
    ;;
esac
