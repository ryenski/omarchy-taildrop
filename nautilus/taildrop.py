# Nautilus context-menu item: "Send with Taildrop".
#
# Hands the selected files to the Omarchy Taildrop overlay, which opens with
# them loaded so the user only has to pick a device. Modelled on Omarchy's
# own localsend.py extension. Installed by install.sh into
# ~/.local/share/nautilus-python/extensions/.

import json
import os
import shutil

from gi import require_version

require_version("Nautilus", "4.1")

from gi.repository import GObject, Gio, Nautilus

PLUGIN_ID = "ryenski.taildrop"
PLUGIN_MANIFEST = os.path.join(
    os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
    "omarchy", "plugins", PLUGIN_ID, "manifest.json",
)


class SendWithTaildropAction(GObject.GObject, Nautilus.MenuProvider):
    def _resolve_command(self):
        # This file outlives `omarchy plugin remove`, so check on every menu
        # that the plugin is still installed rather than offering an item
        # that summons nothing. omarchy-shell and tailscale come from the
        # Omarchy session environment; a Nautilus started outside it (or a
        # machine without Tailscale) simply gets no item either.
        if not os.path.isfile(PLUGIN_MANIFEST):
            return None
        omarchy_shell = shutil.which("omarchy-shell")
        if not omarchy_shell or not shutil.which("tailscale"):
            return None
        return [omarchy_shell, "shell", "summon", PLUGIN_ID]

    def _selected_paths(self, files):
        paths = []

        for file in files:
            location = file.get_location()
            if not location:
                continue

            path = location.get_path()
            if path and path not in paths:
                paths.append(path)

        return paths

    def _make_item(self, paths):
        label = "Send with Taildrop" if len(paths) == 1 else "Send selected with Taildrop"
        item = Nautilus.MenuItem(
            name="TaildropNautilus::send_with_taildrop",
            label=label,
            icon="send-to-symbolic",
        )
        item.connect("activate", self._on_activate, paths)
        return item

    def _on_activate(self, _menu, paths):
        command = self._resolve_command()
        if not command:
            return

        payload = json.dumps({"files": paths, "source": "nautilus"})
        Gio.Subprocess.new(command + [payload], Gio.SubprocessFlags.NONE)

    def get_file_items(self, *args):
        files = args[0] if len(args) == 1 else args[1]
        paths = self._selected_paths(files)

        if not paths or not self._resolve_command():
            return []

        return [self._make_item(paths)]
