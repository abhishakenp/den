// cordis entry point for the `updates` plugin. The logic lives in UpdatesCore.swift.

nonisolated(unsafe) var updatesCore: UpdatesCore?

struct Plugin: CordisPlugin {
  // `config`, `commands` and `webviews` are optional, so they are called but not injected.
  static let manifest = Manifest(name: "Updates", version: "0.1.1", inject: ["updates", "app", "ui", "storage"], provides: [])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = UpdatesCore(env: PluginEnv(ctx))
    updatesCore = core
    core.start()
  }

  static func dispose() {
    updatesCore?.stop()
    updatesCore = nil
  }
}
