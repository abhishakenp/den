// cordis entry point for the `peek` plugin. The logic lives in PeekCore.swift.

nonisolated(unsafe) var peekCore: PeekCore?

struct Plugin: CordisPlugin {
  static let manifest = Manifest(
    name: "Peek", version: "0.1.0", inject: ["tabs", "spaces", "webviews", "content", "ui", "keys", "window", "storage", "app"], provides: ["peek"])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = PeekCore(env: PluginEnv(ctx))
    peekCore = core
    ctx.provide("peek") { m, a in core.handle(m, a) }
    core.start()
  }

  static func dispose() {
    peekCore?.stop()
    peekCore = nil
  }
}
