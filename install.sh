#!/bin/bash
# Installs the parts of the Taildrop plugin that live outside the plugin
# folder. `omarchy plugin add` copies the folder and enables the overlay but
# never runs plugin code, so these are a separate, visible step:
#
#   install.sh            copy the Nautilus "Send with Taildrop" menu item
#                         into place, restart Nautilus, and print the keybind
#                         lines to add to ~/.config/hypr/bindings.lua
#   install.sh --remove   take the Nautilus item out again
#
# The keybind is printed rather than written: bindings.lua is yours, and the
# key may already mean something to you.

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
plugin_id=$(jq -r .id "$here/manifest.json")
ext_dir="${XDG_DATA_HOME:-$HOME/.local/share}/nautilus-python/extensions"
ext_file="$ext_dir/taildrop.py"

restart_nautilus() {
  # Extensions load at startup; a running Nautilus keeps the old set.
  if pgrep -x nautilus >/dev/null; then
    nautilus -q 2>/dev/null || true
    echo "Restarted Nautilus so the menu item loads."
  fi
}

if [[ ${1:-} == --remove ]]; then
  if [[ -f $ext_file ]]; then
    rm -f "$ext_file"
    echo "Removed $ext_file"
    restart_nautilus
  else
    echo "Nautilus item was not installed."
  fi
  exit 0
fi

if ! python3 -c 'import gi; gi.require_version("Nautilus", "4.1")' 2>/dev/null; then
  echo "nautilus-python is not installed; skipping the Nautilus menu item." >&2
  echo "  sudo pacman -S nautilus-python" >&2
else
  mkdir -p "$ext_dir"
  install -m 0644 "$here/nautilus/taildrop.py" "$ext_file"
  echo "Installed Nautilus menu item: $ext_file"
  restart_nautilus
fi

cat <<KEYBIND

Add to ~/.config/hypr/bindings.lua (pick any free key):

  o.bind("SUPER + SHIFT + T", "Send via Taildrop", "omarchy-shell shell toggle $plugin_id")

Optional, so the sheet pops without the compositor's layer fade like the
other Omarchy overlays:

  hl.layer_rule({ match = { namespace = "omarchy-taildrop" }, no_anim = true, animation = "none" })

Hyprland picks the change up on save.
KEYBIND
