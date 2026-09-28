// cordis entry point for the `media` plugin. The logic lives in MediaCore.swift.

nonisolated(unsafe) var mediaCore: MediaCore?

struct Plugin: CordisPlugin {
  // `tabs` is optional (jump to a tab; called, not injected).
  static let manifest = Manifest(name: "Media", version: "0.1.0", inject: ["webviews", "ui", "keys", "nowplaying"], provides: [])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = MediaCore(env: PluginEnv(ctx))
    mediaCore = core
    core.start()
  }

  static func dispose() {
    mediaCore?.stop()
    mediaCore = nil
  }
}
