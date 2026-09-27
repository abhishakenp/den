// cordis entry point for the `shields` plugin. The logic lives in ShieldsCore.swift.

nonisolated(unsafe) var shieldsCore: ShieldsCore?

struct Plugin: CordisPlugin {
  // `commands`, `tabs`, `settings` and `webext` are called when present, not injected.
  static let manifest = Manifest(name: "Shields", version: "0.1.0", inject: ["sitepolicy", "webviews", "ui", "storage"], provides: ["shields"])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = ShieldsCore(env: PluginEnv(ctx))
    shieldsCore = core
    ctx.provide("shields") { m, a in core.handle(m, a) }
    core.start()
  }

  static func dispose() {
    shieldsCore?.stop()
    shieldsCore = nil
  }
}
