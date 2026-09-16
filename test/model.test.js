// Run with: node --test test/
const test = require("node:test")
const assert = require("node:assert/strict")
const Model = require("../Model.js")

const CAP = "https://tailscale.com/cap/file-sharing"

function peer(overrides) {
  return Object.assign({
    HostName: "device",
    DNSName: "device.tailnet.ts.net.",
    OS: "linux",
    Online: true,
    TaildropTarget: 1,
    UserID: 1
  }, overrides)
}

function status(peers, overrides) {
  return JSON.stringify(Object.assign({
    BackendState: "Running",
    Self: { HostName: "me", DNSName: "me.tailnet.ts.net.", CapMap: { [CAP]: null } },
    Peer: peers
  }, overrides))
}

test("parseStatus: online devices become tiles, offline are kept for counting", () => {
  const r = Model.parseStatus(status({
    a: peer({ HostName: "phone", OS: "iOS" }),
    b: peer({ HostName: "laptop", OS: "macOS", Online: false, TaildropTarget: 5 })
  }))
  assert.equal(r.state, "running")
  assert.equal(r.selfName, "me")
  assert.equal(r.onlineCount, 1)
  assert.deepEqual(r.peers.map(p => [p.name, p.online]), [["phone", true], ["laptop", false]])
})

test("parseStatus: peers Tailscale grades as unsendable are dropped", () => {
  const r = Model.parseStatus(status({
    ok: peer({ HostName: "ok" }),
    otherOwner: peer({ HostName: "theirs", TaildropTarget: 9 }),
    noPeerApi: peer({ HostName: "server", TaildropTarget: 8 }),
    ungraded: peer({ HostName: "old", TaildropTarget: 0 }),
    mullvad: peer({ HostName: "exit", DNSName: "de-ber.mullvad.ts.net." })
  }))
  assert.deepEqual(r.peers.map(p => p.name), ["ok"])
})

test("parseStatus: online first, then alphabetical, case-insensitively", () => {
  const r = Model.parseStatus(status({
    a: peer({ HostName: "zeta" }),
    b: peer({ HostName: "Alpha" }),
    c: peer({ HostName: "beta", Online: false, TaildropTarget: 5 }),
    d: peer({ HostName: "alpha2", Online: false, TaildropTarget: 5 })
  }))
  assert.deepEqual(r.peers.map(p => p.name), ["Alpha", "zeta", "alpha2", "beta"])
})

test("parseStatus: duplicate host names fall back to the DNS short name", () => {
  const r = Model.parseStatus(status({
    a: peer({ HostName: "Ryan's MacBook Air", DNSName: "ryans-macbook-air.tailnet.ts.net." }),
    b: peer({ HostName: "Ryan's MacBook Air", DNSName: "ryans-macbook-air-1.tailnet.ts.net." }),
    c: peer({ HostName: "unique", DNSName: "unique.tailnet.ts.net." })
  }))
  assert.deepEqual(r.peers.map(p => p.name).sort(), ["ryans-macbook-air", "ryans-macbook-air-1", "unique"])
})

test("parseStatus: the send target is the DNS name, so duplicates stay distinct", () => {
  const r = Model.parseStatus(status({ a: peer({ HostName: "phone", DNSName: "phone.tailnet.ts.net." }) }))
  assert.equal(r.peers[0].target, "phone.tailnet.ts.net")
})

test("parseStatus: a 'localhost' host name is replaced by the DNS short name", () => {
  const r = Model.parseStatus(status({ a: peer({ HostName: "localhost", DNSName: "ipad-pro.tailnet.ts.net." }) }))
  assert.equal(r.peers[0].name, "ipad-pro")
})

test("parseStatus: backend states map to sheet states", () => {
  assert.equal(Model.parseStatus(status({}, { BackendState: "Stopped" })).state, "stopped")
  assert.equal(Model.parseStatus(status({}, { BackendState: "NeedsLogin" })).state, "needsLogin")
  assert.equal(Model.parseStatus(status({}, { BackendState: "NoState" })).state, "stopped")
})

test("parseStatus: a tailnet without the file-sharing capability is reported", () => {
  const r = Model.parseStatus(status({}, { Self: { HostName: "me" } }))
  assert.equal(r.state, "noFileSharing")
  const legacy = Model.parseStatus(status({}, { Self: { HostName: "me", Capabilities: [CAP] } }))
  assert.equal(legacy.state, "running")
})

test("parseStatus: empty or malformed input is an error, not a crash", () => {
  assert.equal(Model.parseStatus("").state, "error")
  assert.equal(Model.parseStatus("   ").state, "error")
  assert.equal(Model.parseStatus("{not json").state, "error")
  assert.equal(Model.parseStatus(null).state, "error")
})

test("parseStatus: no peers at all is still a running tailnet", () => {
  const r = Model.parseStatus(status({}))
  assert.equal(r.state, "running")
  assert.deepEqual(r.peers, [])
  assert.equal(r.onlineCount, 0)
})

test("osIcon and osLabel cover the platforms Tailscale reports", () => {
  assert.equal(Model.osLabel("iOS"), "iOS")
  assert.equal(Model.osLabel("macOS"), "macOS")
  assert.equal(Model.osLabel("android"), "Android")
  assert.equal(Model.osLabel(""), "")
  assert.equal(Model.osLabel("freebsd"), "freebsd")
  assert.equal(Model.osIcon("iOS"), Model.osIcon("macOS"))
  assert.notEqual(Model.osIcon("linux"), Model.osIcon("windows"))
  assert.equal(Model.osIcon("plan9"), Model.osIcon(undefined))
})

test("name helpers", () => {
  assert.equal(Model.cleanDnsName("a.b.ts.net."), "a.b.ts.net")
  assert.equal(Model.cleanDnsName("a.b.ts.net"), "a.b.ts.net")
  assert.equal(Model.shortDnsName("a.b.ts.net."), "a")
  assert.equal(Model.shortDnsName(""), "")
  assert.equal(Model.displayHostName("", ""), "Unknown")
  assert.equal(Model.displayHostName("", "x.y."), "x")
})
