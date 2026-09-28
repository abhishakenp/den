// cordis entry point for the `calendar` plugin. The logic lives in CalendarCore.swift and ICS.swift.

nonisolated(unsafe) var calendarCore: CalendarCore?

struct Plugin: CordisPlugin {
  // `connections`, `tabs` and `webviews` are optional: called, not injected.
  static let manifest = Manifest(name: "Google Calendar", version: "0.1.0", inject: ["session", "net", "storage", "ui", "schedule"], provides: [])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = CalendarCore(env: PluginEnv(ctx))
    calendarCore = core
    core.start()
  }

  static func dispose() { calendarCore = nil }
}
