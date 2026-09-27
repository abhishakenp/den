// cordis entry point for the `commandbar` plugin (the `commands` service). The logic lives in
// CommandBarCore.swift.

nonisolated(unsafe) var commandBarCore: CommandBarCore?

struct Plugin: CordisPlugin {
  static let manifest = Manifest(
    name: "Command Bar", version: "0.1.0", inject: ["tabs", "spaces", "ui", "keys", "content", "storage"], provides: ["commands"])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = CommandBarCore(env: PluginEnv(ctx))
    commandBarCore = core
    ctx.provide("commands") { m, a in core.handle(m, a) }
    core.start()
  }

  static func dispose() {
    commandBarCore?.stop()
    commandBarCore = nil
  }
}
