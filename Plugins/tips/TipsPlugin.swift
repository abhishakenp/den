// cordis entry point for the `tips` plugin. The logic lives in TipsCore.swift.

nonisolated(unsafe) var tipsCore: TipsCore?

struct Plugin: CordisPlugin {
  // `commands`, `spaces`, `content` and `importer` are optional, so they are called but not injected.
  static let manifest = Manifest(name: "Tips", version: "0.1.0", inject: ["ui", "storage", "settings"], provides: [])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = TipsCore(env: PluginEnv(ctx))
    tipsCore = core
    core.start()
  }

  static func dispose() {
    tipsCore?.stop()
    tipsCore = nil
  }
}
