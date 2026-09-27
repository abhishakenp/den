// cordis entry point for the `connections` plugin. The logic lives in ConnectionsCore.swift.

nonisolated(unsafe) var connectionsCore: ConnectionsCore?

struct Plugin: CordisPlugin {
  // `commands` is optional (commandbar plugin), so it is called but not injected.
  static let manifest = Manifest(name: "Connections", version: "0.1.0", inject: ["ui", "storage", "tabs", "spaces"], provides: ["connections"])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = ConnectionsCore(env: PluginEnv(ctx))
    connectionsCore = core
    ctx.provide("connections") { m, a in core.handle(m, a) }
    core.start()
  }

  static func dispose() { connectionsCore = nil }
}
