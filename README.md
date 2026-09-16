# Taildrop for Omarchy

A share sheet for [Tailscale Taildrop](https://tailscale.com/kb/1106/taildrop):
press a key, pick a device, and whatever you had highlighted, copied, or
selected in Nautilus lands on it.

Tailscale ships a share-menu extension for macOS but nothing like it for
Linux, and LocalSend does not get along with Tailscale (devices vanish from
its list; you end up typing IPs). This plugin is the substitute: Taildrop
already knows every device on your tailnet, works across networks, and needs
no pairing.

![preview](preview.png)

## Using it

There are two ways to open the sheet, and each arrives with something
already loaded to send. Pick a device, press **Enter**, done.

**`SUPER + SHIFT + T`** — loads the first of these that exists:

1. text you have highlighted anywhere (the primary selection)
2. an image on the clipboard — a screenshot you just took counts
3. text on the clipboard

**Right-click files in Nautilus → Send with Taildrop** — loads those files.

The footer of the sheet always shows what is loaded (with a preview or
thumbnail), so you can check before sending. To load something else
without closing the sheet:

| Key | Loads |
|---|---|
| **c** | the clipboard, ignoring any highlighted text |
| **i** | the most recent image from Omarchy's clipboard history, screenshots included — useful when you copied text since. Press **i** again for older ones. |
| **f** | files, via the system file chooser |

Other keys: arrows / Tab move between devices, **r** refreshes the device
list, **Esc** closes.

Text arrives on the other device as `clipboard.txt`, an image as
`clipboard.png` (or `.jpg` / `.webp`, matching what was copied); files keep
their names.

Only devices that can receive right now are shown; the rest are a count.
The list refreshes while the sheet is open, so a device appears as soon as
you open Tailscale on it.

Send-only. Receiving is already handled by Omarchy's
`omarchy-tailscale-receive` service, which drops incoming files into
`~/Downloads` and notifies you.

## Install

```bash
omarchy plugin add https://github.com/ryenski/omarchy-taildrop.git --enable
```

That's it. `omarchy plugin add` never runs plugin code, but the first time
the shell loads the overlay it sets up the two things that live outside the
plugin folder, and tells you so with a notification:

- the Nautilus **Send with Taildrop** menu item, copied into
  `~/.local/share/nautilus-python/extensions/` and kept in sync on updates.
  Nautilus only loads extensions at startup, so if it is running when the
  item is installed or changes, it gets restarted (`nautilus -q`);
- the keybind, appended **once** to `~/.config/hypr/bindings.lua` — only if
  nothing binds the overlay yet and `SUPER + SHIFT + T` is free. If the key
  is taken you get a notification instead, and you add a line by hand:

```lua
o.bind("SUPER + SHIFT + T", "Send via Taildrop", "omarchy-shell shell toggle ryenski.taildrop")
hl.layer_rule({ match = { namespace = "omarchy-taildrop" }, no_anim = true, animation = "none" })
```

The keybind is never touched again after that first run, so changing or
deleting it later sticks. `install.sh` runs the same setup by hand.

Requirements: `tailscale` on `PATH` with the operator set to your user
(`sudo tailscale set --operator=$USER`), Taildrop enabled for the tailnet,
`wl-clipboard`, `jq`, and `nautilus-python` for the context-menu item.
Progress percentages need util-linux `script` (present on Omarchy).

## Remove

```bash
~/.config/omarchy/plugins/ryenski.taildrop/install.sh --remove
omarchy plugin remove ryenski.taildrop
```

and delete the two lines from `bindings.lua`. If you only run
`omarchy plugin remove`, the Nautilus item notices the plugin is gone and
stops showing up; `install.sh --remove` just deletes the leftover file
(run it first, while the plugin folder still exists).

## How it works

`Taildrop.qml` is an `overlay` plugin for the Omarchy shell. It shells out to
`send.sh`, which does the parts that are easier to test from a terminal:

```
send.sh stage-clipboard [--no-primary]   → JSON describing what was staged
send.sh stage-image [--back N]           → an image from the clipboard history, newest first
send.sh send --target <dns> <file>...    → tab-separated progress lines, a notification
send.sh pick [--target <dns>]            → file chooser, then re-summons the overlay
send.sh setup [--remove]                 → first-run setup: Nautilus item, keybind
```

Devices come from `tailscale status --json`, using Tailscale's own
`TaildropTarget` grade: 1 gets a tile, 5 (offline) is counted, anything
else (another owner, no Taildrop support) is ignored.

## Develop

```bash
git clone https://github.com/ryenski/omarchy-taildrop.git ~/Work/omarchy-taildrop
cd ~/Work/omarchy-taildrop
./dev.sh link        # symlink into ~/.config/omarchy/plugins and rescan
omarchy plugin enable ryenski.taildrop
./dev.sh summon      # or with a payload: ./dev.sh summon '{"files":["/etc/hostname"]}'
./dev.sh reload      # after editing QML: restarts the shell (~1s)
./dev.sh validate && ./dev.sh lint
```

The shell caches compiled QML for the life of its process, so edits only
show up after `dev.sh reload` (`omarchy-restart-shell`). Never run
`omarchy plugin update` while linked.

## License

MIT. `Model.js` includes helpers from Omarchy's first-party Tailscale widget,
also MIT.
