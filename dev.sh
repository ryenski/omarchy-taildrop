#!/bin/bash
# Development helpers for the ryenski.taildrop Omarchy plugin.
#
#   dev.sh link       symlink this repo into ~/.config/omarchy/plugins and rescan
#   dev.sh unlink     remove the symlink and rescan
#   dev.sh reload     restart the shell so edited QML is recompiled (~1s)
#   dev.sh rescan     re-walk plugin dirs only (manifest changes; does NOT reload QML)
#   dev.sh watch      reload whenever a file in this repo changes
#   dev.sh validate   omarchy plugin validate (against the real repo path)
#   dev.sh lint       qmllint every .qml file against the shell's import path
#   dev.sh test       unit tests for Model.js (node --test) and the Nautilus extension (unittest)
#   dev.sh summon [json]   open the overlay with an optional payload
#   dev.sh hide       close the overlay
#
# The QML engine caches compiled components for the life of the shell process
# and `rescanPlugins` cannot evict them, so code edits only show up after a
# shell restart -- that is what `reload` does. Never run `omarchy plugin update`
# while linked.

set -euo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
id=$(jq -r .id "$repo/manifest.json")
link="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$id"
omarchy_path="${OMARCHY_PATH:-/usr/share/omarchy}"
qmllint=${QMLLINT:-/usr/lib/qt6/bin/qmllint}

rescan() { omarchy-shell shell rescanPlugins; }
reload() { omarchy-restart-shell; }

case "${1:-}" in
  link)
    if [[ -e $link && ! -L $link ]]; then
      echo "dev.sh: $link exists and is not a symlink; refusing" >&2
      exit 1
    fi
    ln -sfn "$repo" "$link"
    echo "linked $link -> $repo"
    rescan
    ;;
  unlink)
    [[ -L $link ]] && rm "$link" && echo "removed $link"
    rescan
    ;;
  reload)
    reload
    ;;
  rescan)
    rescan
    ;;
  watch)
    echo "watching $repo (ctrl-c to stop)"
    inotifywait -m -r -q -e close_write,create,delete,move \
      --exclude '(\.git|__pycache__)' --format '%w%f' "$repo" |
      while read -r changed; do
        echo "changed: ${changed#"$repo"/}"
        # Editors fire several events per save; let them settle, drain the
        # backlog, then restart once.
        sleep 0.3
        while read -r -t 0.2 _; do :; done
        reload
      done
    ;;
  validate)
    omarchy plugin validate "$repo"
    echo "manifest ok"
    ;;
  lint)
    # `qs.*` is Quickshell's runtime alias for the shell root, so give qmllint
    # an import dir where `qs` resolves. The shell's grouped-property
    # singletons (Color.menu.*, Style.font.*) still lint as bare QObjects and
    # PanelWindow as uncreatable -- the first-party overlays produce the same
    # noise -- so those classes are filtered; anything else is reported.
    imports="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-taildrop/qmlimports"
    mkdir -p "$imports"
    ln -sfn "$omarchy_path/shell" "$imports/qs"
    output=$("$qmllint" -I "$imports" "$repo"/*.qml 2>&1 || true)
    filtered=$(grep -E '^(Warning|Error)' <<<"$output" \
      | grep -Ev 'Unqualified access|not found on type "QObject"|Type PanelWindow is not creatable|QProcess::ExitStatus' || true)
    if [[ -n $filtered ]]; then
      echo "$filtered"
      exit 1
    fi
    echo "lint ok ($(grep -c '^Warning' <<<"$output" || true) known-noise warnings suppressed)"
    ;;
  test)
    node --test "$repo"/test/*.test.js
    python3 -m unittest discover -s "$repo/test"
    ;;
  summon)
    omarchy-shell shell summon "$id" "${2:-{\}}"
    ;;
  hide)
    omarchy-shell shell hide "$id"
    ;;
  *)
    sed -n '2,17p' "$0"
    exit 1
    ;;
esac
