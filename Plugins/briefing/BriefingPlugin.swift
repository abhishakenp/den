// cordis entry point for the `briefing` plugin. The logic lives in BriefingCore.swift.

nonisolated(unsafe) var briefingCore: BriefingCore?

struct Plugin: CordisPlugin {
  // `connections`, `commands` and `tabs` are optional: called, not injected.
  static let manifest = Manifest(name: "Briefing", version: "0.1.0", inject: ["ui", "storage", "keys", "schedule", "ai"], provides: ["briefing"])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = BriefingCore(env: PluginEnv(ctx))
    briefingCore = core
    ctx.provide("briefing") { m, a in core.handle(m, a) }
    core.start()
  }

  static func dispose() { briefingCore = nil }
}
