// cordis entry point for the `passwords` plugin. The logic lives in PasswordsCore.swift.

nonisolated(unsafe) var passwordsCore: PasswordsCore?

struct Plugin: CordisPlugin {
  // `commands` is optional (called, not injected).
  static let manifest = Manifest(name: "Passwords", version: "0.1.0", inject: ["vault", "ui", "storage"], provides: [])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = PasswordsCore(env: PluginEnv(ctx))
    passwordsCore = core
    core.start()
  }

  static func dispose() {
    passwordsCore?.stop()
    passwordsCore = nil
  }
}
