// Test fixture for lazy plugins (LazyPluginsTests): a plugin that registers one of each entry point
// a sidecar can declare (service, command, key event, settings section) and reports every use.
// Built with cordis-build by the test; not part of any SwiftPM target.
nonisolated(unsafe) var runs: Int64 = 0

struct Plugin: CordisPlugin {
  static let manifest = Manifest(name: "Probe", version: "1.0.0", provides: ["probe"])

  static func apply(_ ctx: Context) throws(PluginError) {
    runs = 0
    _ = ctx.call("commands", "register", ["id": "probe.hello", "title": "Hello Probe", "owner": "probe"])
    _ = ctx.call("keys", "bind", ["chord": "cmd+shift+9", "event": "probe.key.go", "title": "Probe"])
    _ = ctx.call("settings", "register", ["id": "probe", "title": "Probe", "controls": []])
    ctx.on("commands.run") { v in
      if v["id"].string == "probe.hello" {
        runs += 1
        ctx.emit("probe.ran", .int(runs))
      }
    }
    ctx.on("probe.key.go") { _ in ctx.emit("probe.went", true) }
    ctx.on("settings.changed") { v in if v["id"].string == "probe" { ctx.emit("probe.setting", v["value"]) } }
    ctx.provide("probe") { method, args in method == "echo" ? args : .string("probe:" + method) }
    ctx.emit("probe.applied", true)
  }
}
