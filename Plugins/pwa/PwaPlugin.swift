// cordis entry point for the `pwa` plugin. The logic lives in PwaCore.swift.

nonisolated(unsafe) var pwaCore: PwaCore?

struct Plugin: CordisPlugin {
  static let manifest = Manifest(
    name: "Web Apps", version: "0.1.0", inject: ["webviews", "window", "storage", "ui", "tabs", "spaces", "content", "app"], provides: ["pwa"])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = PwaCore(env: PluginEnv(ctx))
    pwaCore = core
    ctx.provide("pwa") { m, a in core.handle(m, a) }
    core.start()
  }

  static func dispose() {
    pwaCore?.stop()
    pwaCore = nil
  }
}
