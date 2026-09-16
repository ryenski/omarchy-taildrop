// Peer parsing for the Taildrop overlay.
//
// The name/OS/capability helpers are copied from Omarchy's first-party
// Tailscale widget (shell/plugins/panels/tailscale/Model.js, MIT, © Omarchy
// contributors) so this plugin renders devices the same way the bar does
// without depending on that widget being enabled. parseStatus is our own:
// unlike the bar's, it keeps offline peers so they can be shown dimmed.

// Tailscale grades every peer for Taildrop in `TaildropTarget`. Only two
// grades matter to a share sheet: 1 means "send now", 5 means the device
// exists but is offline. Everything else (other owner, no peer API, an OS
// without Taildrop, daemon too old to say) is hidden rather than explained.
var TARGET_OK = 1
var TARGET_OFFLINE = 5

function cleanDnsName(name) {
  var value = String(name || "")
  return value.charAt(value.length - 1) === "." ? value.slice(0, -1) : value
}

function shortDnsName(name) {
  var clean = cleanDnsName(name)
  if (clean === "") return ""
  return clean.split(".")[0] || clean
}

function displayHostName(hostName, dnsName) {
  var host = String(hostName || "")
  if (host !== "" && host.toLowerCase() !== "localhost") return host
  return shortDnsName(dnsName) || host || "Unknown"
}

function isMullvadHost(name) {
  var value = String(name || "").toLowerCase()
  var suffix = ".mullvad.ts.net"
  return value.length > suffix.length && value.indexOf(suffix) === value.length - suffix.length
}

function isMullvadPeer(peer) {
  var hostName = String((peer && peer.HostName) || "")
  var dnsName = cleanDnsName((peer && peer.DNSName) || "")
  return isMullvadHost(dnsName) || isMullvadHost(hostName)
}

function osIcon(os) {
  var value = String(os || "").toLowerCase()
  if (value === "linux") return "󰌽"
  if (value === "macos" || value === "ios") return "󰀵"
  if (value === "windows") return "󰍲"
  if (value === "android") return "󰀲"
  return "󰟀"
}

function osLabel(os) {
  var value = String(os || "").toLowerCase()
  if (value === "linux") return "Linux"
  if (value === "macos") return "macOS"
  if (value === "ios") return "iOS"
  if (value === "windows") return "Windows"
  if (value === "android") return "Android"
  return value === "" ? "" : String(os)
}

// Taildrop is a tailnet feature the admin can turn off, so the overlay only
// makes sense when this profile actually carries the capability.
function hasFileSharing(self) {
  var capability = "https://tailscale.com/cap/file-sharing"
  var capMap = (self && self.CapMap) || null
  if (capMap && capMap[capability] !== undefined) return true
  var capabilities = (self && self.Capabilities) || []
  for (var i = 0; i < capabilities.length; i++) {
    if (String(capabilities[i]) === capability) return true
  }
  return false
}

function peerFromStatus(id, peer) {
  var code = typeof peer.TaildropTarget === "number" ? peer.TaildropTarget : 0
  return {
    id: String(id),
    name: displayHostName(peer.HostName, peer.DNSName),
    dnsName: cleanDnsName(peer.DNSName),
    // `tailscale file cp` takes a host name or DNS name; the DNS name is the
    // unambiguous one when two devices share a host name.
    target: cleanDnsName(peer.DNSName) || displayHostName(peer.HostName, peer.DNSName),
    os: String(peer.OS || ""),
    icon: osIcon(peer.OS),
    online: code === TARGET_OK,
    code: code,
    mullvad: isMullvadPeer(peer)
  }
}

// Two devices can share a host name (a laptop re-enrolled under the same
// name). Give the duplicates their DNS short name so the tiles stay apart.
function disambiguate(peers) {
  var counts = {}
  for (var i = 0; i < peers.length; i++) counts[peers[i].name] = (counts[peers[i].name] || 0) + 1
  for (var j = 0; j < peers.length; j++) {
    if (counts[peers[j].name] > 1 && peers[j].dnsName !== "") peers[j].name = shortDnsName(peers[j].dnsName)
  }
  return peers
}

function sortForGrid(peers) {
  peers.sort(function(a, b) {
    if (a.online !== b.online) return a.online ? -1 : 1
    return String(a.name).localeCompare(String(b.name))
  })
  return peers
}

// Turns `tailscale status --json` into what the overlay renders. `state` is
// one of: running, stopped, needsLogin, noFileSharing, error.
function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return { state: "error", message: "Tailscale returned no status" }

  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return { state: "error", message: "Could not read Tailscale status" }
  }

  var backendState = String(data.BackendState || "Unknown")
  if (backendState === "NeedsLogin") return { state: "needsLogin", message: "Tailscale needs you to log in" }
  if (backendState !== "Running") return { state: "stopped", message: "Tailscale is not running" }

  var self = data.Self || {}
  if (!hasFileSharing(self)) return { state: "noFileSharing", message: "Taildrop is disabled on this tailnet" }

  var peers = []
  var rawPeers = data.Peer || {}
  for (var id in rawPeers) {
    var peer = peerFromStatus(id, rawPeers[id] || {})
    if (peer.mullvad) continue
    if (peer.code !== TARGET_OK && peer.code !== TARGET_OFFLINE) continue
    peers.push(peer)
  }

  var onlineCount = 0
  for (var i = 0; i < peers.length; i++) if (peers[i].online) onlineCount++

  return {
    state: "running",
    selfName: displayHostName(self.HostName, self.DNSName),
    peers: sortForGrid(disambiguate(peers)),
    onlineCount: onlineCount
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    cleanDnsName: cleanDnsName,
    shortDnsName: shortDnsName,
    displayHostName: displayHostName,
    isMullvadPeer: isMullvadPeer,
    osIcon: osIcon,
    osLabel: osLabel,
    hasFileSharing: hasFileSharing,
    peerFromStatus: peerFromStatus,
    disambiguate: disambiguate,
    sortForGrid: sortForGrid,
    parseStatus: parseStatus
  }
}
