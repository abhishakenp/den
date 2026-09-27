// cordis entry point for the `pagetools` plugin. The logic lives in PageToolsCore.swift, the
// in-page scripts in resources/.

nonisolated(unsafe) var pageToolsCore: PageToolsCore?

struct Plugin: CordisPlugin {
  static let manifest = Manifest(
    name: "Page Tools", version: "0.1.0", inject: ["webviews", "content", "ui", "keys", "storage", "app", "speech", "translate", "schedule", "settings"], provides: [])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = PageToolsCore(env: PluginEnv(ctx))
    pageToolsCore = core
    core.start()
  }

  static func dispose() {
    pageToolsCore?.stop()
    pageToolsCore = nil
  }
}
