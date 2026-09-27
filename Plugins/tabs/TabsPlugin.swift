// cordis entry point for the `tabs` plugin. The logic lives in TabsCore.swift.

nonisolated(unsafe) var tabsCore: TabsCore?

struct Plugin: CordisPlugin {
  static let manifest = Manifest(
    name: "Tabs", version: "0.1.0", inject: ["spaces", "webviews", "content", "ui", "storage", "keys", "window", "app"], provides: ["tabs"])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = TabsCore(env: PluginEnv(ctx))
    tabsCore = core
    ctx.provide("tabs") { m, a in core.handle(m, a) }
    core.start()
  }

  static func dispose() {
    tabsCore?.stop()
    tabsCore = nil
  }
}
