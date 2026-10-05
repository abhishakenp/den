// cordis entry point for the `continuity` plugin. The logic lives in ContinuityCore.swift.

nonisolated(unsafe) var continuityCore: ContinuityCore?

struct Plugin: CordisPlugin {
  // `tabs`, `spaces` and `webviews` are called, not injected: without tabs there is nothing to show.
  static let manifest = Manifest(name: "Continuity", version: "0.1.0", inject: ["spotlight", "handoff", "settings"], provides: [])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = ContinuityCore(env: PluginEnv(ctx))
    continuityCore = core
    core.start()
  }

  static func dispose() {
    continuityCore?.stop()
    continuityCore = nil
  }
}
