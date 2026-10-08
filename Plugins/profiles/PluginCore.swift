// cordis entry point for the `profiles` plugin. The logic lives in ProfilesCore.swift.

nonisolated(unsafe) var profilesCore: ProfilesCore?

struct Plugin: CordisPlugin {
  static let manifest = Manifest(name: "Profiles", version: "0.1.0", inject: ["storage", "session"], provides: [])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = ProfilesCore(env: PluginEnv(ctx))
    profilesCore = core
    core.start()
  }

  static func dispose() { profilesCore = nil }
}