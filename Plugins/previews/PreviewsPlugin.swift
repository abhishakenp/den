// cordis entry point for the `previews` plugin. The logic lives in PreviewsCore.swift,
// Cards.swift and Providers.swift.

nonisolated(unsafe) var previewsCore: PreviewsCore?

struct Plugin: CordisPlugin {
  // `net`, `session` and `tabs` are called when present, not injected: without them the generic
  // page preview still works.
  static let manifest = Manifest(name: "Previews", version: "0.1.0", inject: ["ui", "webviews", "storage"], provides: ["previews"])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = PreviewsCore(env: PluginEnv(ctx))
    previewsCore = core
    ctx.provide("previews") { m, a in core.handle(m, a) }
    core.start()
  }

  static func dispose() {
    previewsCore?.hide()
    previewsCore = nil
  }
}
