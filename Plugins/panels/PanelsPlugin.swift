// cordis entry point for the `panels` plugin. The logic lives in PanelsCore.swift.

nonisolated(unsafe) var panelsCore: PanelsCore?

struct Plugin: CordisPlugin {
  // `tabs`, `commands` and `settings` are optional (called, not injected).
  static let manifest = Manifest(name: "Web Panels", version: "0.1.0", inject: ["webviews", "content", "ui", "keys", "storage"], provides: [])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = PanelsCore(env: PluginEnv(ctx))
    panelsCore = core
    core.start()
  }

  static func dispose() {
    panelsCore?.stop()
    panelsCore = nil
  }
}
