# Run with: python3 -m unittest discover -s test
#
# The extension imports gi/Nautilus at module load, which only exists inside
# a Nautilus process. Stand in for it with a fake module tree, then load the
# extension file directly so the tests do not need Nautilus installed.

import importlib.util
import json
import os
import sys
import tempfile
import types
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
EXTENSION = os.path.join(HERE, "..", "nautilus", "taildrop.py")


class FakeMenuItem:
    def __init__(self, name, label, icon):
        self.name, self.label, self.icon = name, label, icon
        self.handlers = {}

    def connect(self, signal, handler, *args):
        self.handlers[signal] = (handler, args)

    def activate(self):
        handler, args = self.handlers["activate"]
        handler(self, *args)


class FakeFile:
    def __init__(self, path):
        self._path = path

    def get_location(self):
        if self._path is None:
            return None
        return types.SimpleNamespace(get_path=lambda: self._path)


def install_fake_gi():
    gi = types.ModuleType("gi")
    gi.require_version = lambda *a: None
    repository = types.ModuleType("gi.repository")
    class GObjectBase:
        pass

    class MenuProviderBase:
        pass

    repository.GObject = types.SimpleNamespace(GObject=GObjectBase)
    repository.Gio = types.SimpleNamespace(
        Subprocess=types.SimpleNamespace(new=mock.Mock()),
        SubprocessFlags=types.SimpleNamespace(NONE=0),
    )
    repository.Nautilus = types.SimpleNamespace(MenuProvider=MenuProviderBase, MenuItem=FakeMenuItem)
    gi.repository = repository
    sys.modules["gi"] = gi
    sys.modules["gi.repository"] = repository
    return repository


def load_extension(config_home):
    with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": config_home}):
        spec = importlib.util.spec_from_file_location("taildrop_ext", EXTENSION)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
    return module


class NautilusExtensionTests(unittest.TestCase):
    def setUp(self):
        self.gi = install_fake_gi()
        self.config = tempfile.TemporaryDirectory()
        self.addCleanup(self.config.cleanup)
        self.manifest = os.path.join(self.config.name, "omarchy", "plugins", "ryenski.taildrop", "manifest.json")
        os.makedirs(os.path.dirname(self.manifest))
        with open(self.manifest, "w") as f:
            f.write("{}")
        self.module = load_extension(self.config.name)
        self.provider = self.module.SendWithTaildropAction()
        # Both binaries present unless a test says otherwise.
        self.which = mock.patch.object(
            self.module.shutil, "which",
            side_effect=lambda name: {"omarchy-shell": "/usr/bin/omarchy-shell", "tailscale": "/usr/bin/tailscale"}.get(name),
        )
        self.which.start()
        self.addCleanup(self.which.stop)

    def items(self, *paths):
        return self.provider.get_file_items(None, [FakeFile(p) for p in paths])

    def test_single_file_gets_the_singular_label(self):
        (item,) = self.items("/home/u/a.pdf")
        self.assertEqual(item.label, "Send with Taildrop")
        self.assertEqual(item.name, "TaildropNautilus::send_with_taildrop")

    def test_several_files_get_the_plural_label(self):
        (item,) = self.items("/home/u/a.pdf", "/home/u/b.png")
        self.assertEqual(item.label, "Send selected with Taildrop")

    def test_activation_summons_the_overlay_with_the_paths(self):
        (item,) = self.items("/home/u/a.pdf", "/home/u/b c.png")
        item.activate()
        self.gi.Gio.Subprocess.new.assert_called_once()
        argv, flags = self.gi.Gio.Subprocess.new.call_args.args
        self.assertEqual(argv[:4], ["/usr/bin/omarchy-shell", "shell", "summon", "ryenski.taildrop"])
        self.assertEqual(json.loads(argv[4]), {"files": ["/home/u/a.pdf", "/home/u/b c.png"], "source": "nautilus"})

    def test_duplicate_and_locationless_selections_are_dropped(self):
        (item,) = self.items("/home/u/a.pdf", "/home/u/a.pdf", None)
        item.activate()
        argv, _ = self.gi.Gio.Subprocess.new.call_args.args
        self.assertEqual(json.loads(argv[4])["files"], ["/home/u/a.pdf"])

    def test_no_selection_means_no_item(self):
        self.assertEqual(self.items(), [])
        self.assertEqual(self.items(None), [])

    def test_no_item_once_the_plugin_is_removed(self):
        os.remove(self.manifest)
        self.assertEqual(self.items("/home/u/a.pdf"), [])

    def test_no_item_without_tailscale_or_omarchy_shell(self):
        with mock.patch.object(self.module.shutil, "which", return_value=None):
            self.assertEqual(self.items("/home/u/a.pdf"), [])
        with mock.patch.object(self.module.shutil, "which",
                               side_effect=lambda n: "/usr/bin/omarchy-shell" if n == "omarchy-shell" else None):
            self.assertEqual(self.items("/home/u/a.pdf"), [])

    def test_nautilus_signature_variants(self):
        # nautilus-python has passed (files) and (window, files) over the years.
        files = [FakeFile("/home/u/a.pdf")]
        self.assertEqual(len(self.provider.get_file_items(files)), 1)
        self.assertEqual(len(self.provider.get_file_items(None, files)), 1)


if __name__ == "__main__":
    unittest.main()
