// cordis entry point for the `spaces` plugin. The logic lives in SpacesCore.swift.

nonisolated(unsafe) var spacesCore: SpacesCore?

struct Plugin: CordisPlugin {
  static let manifest = Manifest(name: "Spaces", version: "0.1.0", inject: ["window", "ui", "storage", "keys"], provides: ["spaces"])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = SpacesCore(env: PluginEnv(ctx))
    spacesCore = core
    ctx.provide("spaces") { m, a in core.handle(m, a) }
    core.start()
  }

  static func dispose() { spacesCore = nil }
}
