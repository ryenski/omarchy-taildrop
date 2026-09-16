# Omarchy Taildrop overlay plugin — plan

> **Status (2026-09-16):** all seven steps done; v1 verified end to end on this machine (keybind, highlight/clipboard/image, chooser, Nautilus, progress, retry, install-from-git). Follow-ups are listed at the end.

## Context

Omarchy already ships Taildrop plumbing: `omarchy-tailscale-send` (file chooser → `tailscale file cp`) reachable from the first-party `omarchy.tailscale` bar panel, and `omarchy-tailscale-receive.service` for the inbox. What's missing is a **share-sheet style UI** like LocalSend's: summon it with a keybind or from a Nautilus right-click, pick a device tile, and send either the clipboard (text → `clipboard.txt`, image → `clipboard.png`) or files. Tailscale provides this on macOS (Share menu) but nothing on Linux.

Why not just use LocalSend? Because LocalSend and Tailscale don't get along: with Tailscale enabled, devices don't show up in LocalSend's discovery list and you have to type the device's IP by hand. Taildrop already knows every device on the tailnet, works across networks (not just the LAN), and needs no pairing — so a Taildrop share sheet is a straight substitute for LocalSend on Omarchy. Omarchy even ships a LocalSend Nautilus menu item (`/usr/share/omarchy/default/nautilus-python/extensions/localsend.py`) which this plugin mirrors for Taildrop.

Outcome: a third-party Omarchy plugin `ryenski.taildrop` (kind `overlay`), developed in `~/Work/omarchy-taildrop`, installable with `omarchy plugin add`, plus a Nautilus context-menu item and a keybind. **Send-only** — receiving stays with the existing service.

Verified on this machine (Tailscale 1.102.3, operator = ryenski, no sudo needed):
- `tailscale file cp ~/Work/skills/README.md iphone:` delivered to the iPhone. ✅
- The stdin form (`echo … | tailscale file cp --name=… - iphone:`) exited silently and delivered nothing. ❌ → **always send real files; stage the clipboard to a temp file first.**
- `tailscale status --json` peers carry `TaildropTarget`: `1` = can receive now (iphone, pixel-7a, aperture), `5` = offline (macbooks, ipad, rpi, umbrel). `Self.CapMap` has the file-sharing cap. Offline here means the device really has Tailscale off (not iOS backgrounding).
- A peer that can't receive fails fast: `404 Not Found: unsupported peerapi path`. Just an error state.

## Decisions (from discussion)

| Decision | Choice |
|---|---|
| Plugin id | `ryenski.taildrop` (repo `github.com/ryenski/omarchy-taildrop`) |
| v1 scope | keybind-summoned overlay, clipboard send (text + image, prefer image), file chooser, Nautilus "Send with Taildrop", keybind |
| Deferred | drag-and-drop zone (no DnD onto layer-shell surfaces anywhere in the shell; unverified), multi-target send, inbox/receive UI |
| Keybind payload | **Highlighted text first, then clipboard.** On `SUPER+SHIFT+T` (payload `{}`), stage the primary selection (`wl-paste --primary`) as `clipboard.txt` if it holds non-empty text; otherwise the clipboard — `image/png` wins over text. The footer says which ("Selection · …" vs "Clipboard · …"); `c` forces the clipboard in case a stale highlight wins. Skip either source when `x-kde-passwordManagerHint` is present (as `plugins/clipboard/capture.sh` does). |
| Staging | staged at open into `$XDG_RUNTIME_DIR/omarchy-taildrop/clipboard.{png,txt}` so the footer shows exactly what will be sent and the send can't race a clipboard change |
| Peers | `TaildropTarget == 1` → tile; `== 5` → not shown, only counted ("N devices offline"; changed from dimmed tiles after use — they were clutter); anything else → hidden. Don't depend on the first-party Tailscale widget (third-party `serviceFor` can't reach it anyway, and it's a bar-widget, not a service) |
| Keybind | `SUPER + SHIFT + T` — free in `/usr/share/omarchy/default/hypr/bindings/*.lua` and `~/.config/hypr/bindings.lua` (`SUPER+CTRL+T` = btop, `SUPER+CTRL+S` = share menu, `SUPER+SHIFT+S` = user's Google Maps) |

## Repo layout — `~/Work/omarchy-taildrop`

```
manifest.json          id ryenski.taildrop, kinds ["overlay"], keepLoaded true,
                       entryPoints {"overlay": "Taildrop.qml"}, license MIT, version 0.1.0
Taildrop.qml           the overlay: Item root + PanelWindow, all UI state
Model.js               vendored subset of Omarchy's MIT Model.js (attribution header):
                       cleanDnsName, shortDnsName, displayHostName, isMullvadPeer, osIcon,
                       hasFileSharing, peerFromStatus + our own parseStatus/sortForGrid
send.sh                bash helper with subcommands: stage-clipboard | pick | send
nautilus/taildrop.py   Nautilus.MenuProvider → omarchy-shell summon with {"files": [...]}
install.sh             copies nautilus/taildrop.py → ~/.local/share/nautilus-python/extensions/,
                       runs `nautilus -q`, prints the keybind + layer-rule lines to add
dev.sh                 link | unlink | reload | watch | validate | lint | summon [json]
README.md  LICENSE (MIT)  .gitignore  preview.png (later)
```

Constraints: no symlinks anywhere inside the repo (`omarchy-plugin-validate:115` runs `find -type l`, `.git` excluded); `send.sh` committed executable. QML finds its own script via `Qt.resolvedUrl("send.sh")` with `file://` stripped (the public manifest hides `__sourceDir`). `omarchy plugin add` never runs plugin code, so the Nautilus extension and keybind are documented manual steps (`install.sh`).

## Dev loop

1. `git init ~/Work/omarchy-taildrop`.
2. `dev.sh link`: `ln -s ~/Work/omarchy-taildrop ~/.config/omarchy/plugins/ryenski.taildrop`. The registry scans `for sub in "$dir"/*/` (`/usr/share/omarchy/shell/services/PluginRegistry.qml:712`) which follows a symlinked dir; the entry-point containment check is string-based (`:124-132`); `omarchy plugin remove` explicitly supports unlinking.
3. **Code edits need a shell restart.** Verified in step 1: `rescanPlugins` (and the registry's own inotify reload) re-mounts plugins but re-instantiates the QML engine's *cached* compiled component — `Qt.clearComponentCache` isn't reachable from QML, so edits never show up, symlink or real dir. `dev.sh reload` = `omarchy-restart-shell` (~1.1 s, lock-aware); `dev.sh rescan` = `rescanPlugins` for manifest-only changes; `dev.sh watch` restarts on save. A restart kills an in-flight send during dev — fine.
4. `dev.sh validate` = `omarchy plugin validate ~/Work/omarchy-taildrop` (**real** path; the symlink itself trips `find -type l`). `dev.sh lint` = `/usr/lib/qt6/bin/qmllint -I /usr/share/omarchy/shell *.qml` (not on PATH).
5. `omarchy plugin enable ryenski.taildrop` (adds to `plugins[]` in `~/.config/omarchy/shell.json`), then `dev.sh summon '{}'`, `qs log` for errors.
6. Never run `omarchy plugin update` while linked (it would git-merge inside the dev repo and then validate the symlink path).

## Design

### Summon payload (`open(payloadJson)`)

```json
{}                                                     // keybind → clipboard mode
{"files": ["/abs/a.pdf", "/abs/b"], "source": "nautilus"}   // Nautilus / chooser → files mode
{"files": [...], "target": "iphone.<tailnet>.ts.net"}  // re-summon after chooser: preselect tile
```
Empty/invalid → `{}`. `omarchy-shell` already appends `{}` for a 3-arg `summon`/`toggle`; the payload arrives verbatim (`shell.qml:1152-1190`). A summon while open replaces the payload.

### Overlay UI — one screen

Modelled on `/usr/share/omarchy/shell/plugins/emojis/Emojis.qml`: plain `Item` root with host-injected `shell` / `manifest` / `omarchyPath`; duck-typed `open(payloadJson)`, `close()`, `opened`; `dismiss()` → `shell.hide(manifest.id)`. `PanelWindow` anchored all sides, `WlrLayershell.namespace: "omarchy-taildrop"`, `WlrLayer.Overlay`, `WlrKeyboardFocus.Exclusive`, `ExclusionMode.Ignore`; scrim `Rectangle { color: Color.menu.scrim }` with click-outside dismiss; centered `BorderSurface` card (`Border.surfaceSpec("menu","border",…)`, `Style.cornerRadius`, `Style.spacing.panelPadding`) with a swallow `MouseArea`; `keyCatcher` Item force-focused in `open()`.

```
┌──────────────────────────────────────────────┐
│ 󰒊  Send via Taildrop                     󰑐  │
│  Send to                                     │
│  ┌────────┐ ┌────────┐ ┌────────┐            │
│  │  iphone│ │pixel-7a│ │ macbook│  …         │  ← GridView of CursorSurface tiles
│  │   iOS │ │ android│ │ offline│            │     (Model.osIcon glyph, name; code 5 = dim)
│  └────────┘ └────────┘ └────────┘            │
│ ──────────────────────────────────────────── │
│ 󰅇 Clipboard · "hello from omarchy…"          │  ← payload footer: text preview / image thumb
│                        c clipboard  f files  │     (Image via Util.fileUrl) / "3 files · a, b…"
│             ↵ send   r refresh   esc close   │
└──────────────────────────────────────────────┘
```

`root.state`: `loading` → `choose` | `noTargets` (dim tiles + "Open Tailscale on the device — refreshes automatically") | `error` ("Tailscale is not running" / "Taildrop is disabled on this tailnet" / "Nothing to send" / "tailscale not installed"; `r` retries) → `sending` (per-file rows with progress bar + status glyph) → `done` (auto-close ≈1.5 s unless hovered; Enter/Esc) | `failed` (per-file message; `r` retries failed). `close()` only hides; an in-flight `send.sh` keeps running and still posts its notification.

Keys: use a plain `keyCatcher` with `Keys.priority: Keys.BeforeItem` (not `Ui/PanelKeyCatcher.qml`, which claims `h/j/k/l/x/space`). Arrows/Tab move across active tiles (skip dim, wrap); Enter/Space send; `c` re-stage from the clipboard only (`--no-primary`); `f` file chooser; `r` refresh; Esc dismiss (also mid-send). Hover moves the cursor so there's one highlight. Reuse `Ui/CursorSurface.qml` (hover/selected fills), `Ui/PanelActionButton.qml` (refresh), `Color.menu.*`, `Color.accent/muted`, `Style.font.*`, `Style.spacing.*`.

### Peers

`Process { command: ["tailscale","status","--json"]; stdout: StdioCollector { waitForEnd: true } }` (pattern `panels/tailscale/Service.qml:471-484`) on `open()` and every 3 s while `choose`/`noTargets`. Own `parseStatus`: drop self and Mullvad, keep code 1 (active) and 5 (offline, dim), hide others; sort online first then by name; `hasFileSharing(self)` gates the "disabled on this tailnet" error. Vendor `peerFromStatus`, `displayHostName` (handles the iPad's `HostName: "localhost"`), `osIcon` from `/usr/share/omarchy/shell/plugins/panels/tailscale/Model.js:32,50,99`.

### `send.sh` — the testable core

```
send.sh stage-clipboard [--no-primary]
   → one JSON line: {"kind":"image","source":"clipboard","path":…,"mime":"image/png","bytes":N}
                    {"kind":"text","source":"selection"|"clipboard","path":…,"chars":N,"preview":"first 120 chars"}
                    {"kind":"none"} | {"kind":"sensitive"}       (exit 0 always)
   order: 1) wl-paste --primary --list-types has text/* and --primary --no-newline is non-blank → selection
          2) wl-paste --list-types has image/png (jpeg/webp keep their ext) → image
          3) clipboard text → --no-newline
   --no-primary (the `c` key) skips step 1
   staged under $XDG_RUNTIME_DIR/omarchy-taildrop/, cleaned on next stage / after send

send.sh pick [--target <dns>]
   omarchy-file-select --title "Send with Taildrop" --multiple
   picked → omarchy-shell shell summon ryenski.taildrop '{"files":[…],"source":"chooser","target":…}'  (jq -n --args)
   exit 1 (cancel) → re-summon '{}' ; exit 2 → omarchy-notification-send -g 󰒊 -u critical "Could not open file chooser"

send.sh send --target <dns-or-ip> [--label <short>] [--name <sendAs>] <file>...
   per file, sequentially:  tailscale file cp --update-interval=250ms [--name X] -- "$f" "$target:" 2>&1
   stdout, tab-separated:   begin\t<count>\t<label>
                            file\t<i>\t<basename>\t<bytes>
                            progress\t<i>\t<pct>\t<sent>\t<total>   ← parsed from "  <name>: <sent> / <total> (<pct>%)"
                            done\t<i>  |  fail\t<i>\t<message>
                            end\t<ok>\t<failed>
   notification: -g 󰒊 "Sent to <label>" "<name | N files>"  or  -u critical "Could not send to <label>" "<msg>"
   exit 0 all ok / 1 some failed / 2 usage
```
`--name clipboard.png|txt` only for the staged clipboard file (mirrors `/usr/share/omarchy/bin/omarchy-tailscale-send:45-50` for the notification shape). QML consumes stdout with `SplitParser` → `line.split("\t")`; a `progress` line that doesn't parse leaves the row indeterminate. Error mapping lives in QML: `unsupported peerapi path` → "This device can't receive Taildrop".

### File chooser flow

The overlay holds exclusive keyboard focus on the Overlay layer, so the portal dialog (`omarchy-file-select` → `org.freedesktop.portal.FileChooser`) would sit underneath, unfocusable. So `f` = `dismiss()` + `Quickshell.execDetached([sendSh, "pick", "--target", dns])`; the script re-summons with a `files` payload — the same entry point Nautilus uses.

### Nautilus extension (`nautilus/taildrop.py`)

Copy the shape of `localsend.py` (`GObject.GObject, Nautilus.MenuProvider`, `_selected_paths`, `get_file_items(*args)` quirk). Offered only when `shutil.which("tailscale")` and `shutil.which("omarchy-shell")` (the systemd user environment carries `OMARCHY_PATH` and `/usr/share/omarchy/bin` on PATH, so dbus-activated Nautilus can run it). Label "Send with Taildrop" / "Send selected with Taildrop", `name="TaildropNautilus::send_with_taildrop"`, `icon="send-to-symbolic"`. Activate → `Gio.Subprocess.new(["omarchy-shell","shell","summon",PLUGIN_ID, json.dumps({"files": paths, "source": "nautilus"})])`. Installed to `~/.local/share/nautilus-python/extensions/taildrop.py` (dir exists, holds `localsend.py`), reload with `nautilus -q`.

### Keybind + layer rule (`~/.config/hypr/bindings.lua`, printed by `install.sh`)

```lua
o.bind("SUPER + SHIFT + T", "Send via Taildrop", "omarchy-shell shell toggle ryenski.taildrop")
-- optional: the shell's no-fade rule (default/hypr/apps/omarchy-shell.lua:10) is an anchored regex, so add ours
hl.layer_rule({ match = { namespace = "omarchy-taildrop" }, no_anim = true, animation = "none" })
```

## Implementation steps

1. **Scaffold + dev loop** — repo, `LICENSE`, `.gitignore`, `manifest.json`, `dev.sh`, minimal `Taildrop.qml` (Emojis clone: scrim + card + title, Esc dismiss). ✔ `dev.sh validate` + `lint` clean; `link`, `reload`, `omarchy plugin list` shows it; `enable`; `summon`/`hide` round-trip; `qs log` clean.
2. **Model.js + peers** — vendor helpers, own `parseStatus`, status Process + 3 s timer, tile grid, cursor/keys, states `loading/choose/noTargets/error`. ✔ tiles match `tailscale status`; toggle Tailscale off on the phone → tile dims within 3 s; `tailscale down` → error state.
3. **`send.sh stage-clipboard` + footer** — staging, preview chip, image thumbnail. ✔ from terminal `./send.sh stage-clipboard | jq .` for text, screenshot, empty, sensitive.
4. **`send.sh send` + sending UI** — loop, progress parser, notifications, `SplitParser` rows, `done`/`failed`, retry. ✔ terminal first: `./send.sh send --target iphone <5 MB file>` shows progress lines; `--target aperture` → fail path; then from the overlay: clipboard text → `clipboard.txt` on the phone, screenshot → `clipboard.png`.
5. **Files payload + chooser** — `open()` with `files`, `f` → `pick` → re-summon with target preselected. ✔ `dev.sh summon '{"files":["/etc/hostname"]}'`; cancel returns to clipboard mode; pick 2 files → both arrive.
6. **Nautilus + install.sh + keybind + README** (install via `omarchy plugin add`, extras, usage, removal). ✔ right-click single/multi (paths with spaces/quotes) → overlay opens with them; `SUPER+SHIFT+T` toggles; `omarchy menu keybindings --print` lists it.
7. **Install-from-git test + polish** — `dev.sh unlink`; `omarchy plugin add file:///home/ryenski/Work/omarchy-taildrop --enable --yes`; validate passes on the clone; remove; re-link. Theming pass vs. the emoji/clipboard overlays, `preview.png`, first commit.

## Verification (end-to-end)

- `omarchy plugin validate ~/Work/omarchy-taildrop` exits 0; `qmllint` clean; `omarchy plugin list` shows enabled.
- Keybind opens/closes; Esc, scrim click, `omarchy-shell shell hide …` all close; `isPluginOpen` consistent after two toggles.
- States: `loading→choose`; `tailscale down` → error; no online targets → `noTargets` with dim tiles; refresh flips tiles as devices come online.
- Highlight text in a terminal/browser, press the keybind → footer shows "Selection · …", Enter → `clipboard.txt` on iPhone with that text. Nothing highlighted: clipboard text → `clipboard.txt`; PNG → `clipboard.png`; both present → image; stale highlight + fresh copy → `c` switches to the clipboard; empty → "Nothing to send" but `f` still works.
- 1 file and 3 files: per-row progress advances; "Sent to iphone" / "3 files" notification.
- Failure: peer that rejects → red row + critical notification, `r` retries. Dismiss mid-transfer → transfer completes, notification still posts.
- Nautilus single/multi; `dev.sh reload` (shell restart) picks up QML edits; clean `omarchy plugin add`/`remove` on a copy.
- Works with the `omarchy.tailscale` bar widget disabled.

## Risks / open questions

- ~~Progress output format~~ Resolved in step 4: `tailscale file cp` draws its meter **only on a TTY**, as `\r`-separated redraws (`name  sent  rate  pct%  ETA`); nothing on stdout/stderr otherwise, and `--verbose` gives only "sending…/sent" lines. `send.sh` runs it under util-linux `script -qefc` to get percentages and parses the chunks (falls back to no percentages if `script` is missing).
- `Process.exited` can fire before `SplitParser` delivers the last stdout lines; the overlay settles the outcome from the row states after a short grace period rather than trusting the `end` line (bug found in step 4).
- Only code-1 peers are selectable, which sidesteps `file cp` blocking on an offline peer.
- Primary selection is sticky on Wayland: a highlight from minutes ago can outrank a fresh Ctrl+C. The footer preview makes this visible and `c` overrides; if it proves annoying in practice, flip the default order (clipboard first) — one-line change in `send.sh`.
- Non-PNG clipboard images keep their extension (`clipboard.jpg`); PNG preferred when offered.
- A Nautilus summon during `sending` is ignored except to raise the window (v1 limitation, documented).
- Receiver-side naming: repeated `clipboard.txt` sends get renamed by the receiver (Omarchy `--conflict=rename`; iOS Files dedupes itself).

## Follow-ups (out of v1)

Drag-and-drop zone; multi-target fan-out; inbox/receive UI; routing the first-party Tailscale panel's "send files" action to this overlay.
