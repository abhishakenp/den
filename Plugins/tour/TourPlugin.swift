// cordis entry point for the `tour` plugin. The logic lives in TourCore.swift.
//
// Tour Callouts: visual callout panels with arrow pointers that highlight real UI elements.
// First-run tour, discovery tips for lesser-known features, contextual help for settings pages.
// Uses SwiftUI overlay with arrow pointers and animated transitions.

nonisolated(unsafe) var tourCore: TourCore?

struct Plugin: CordisPlugin {
  static let manifest = Manifest(name: "Tour", version: "0.1.0", inject: ["ui", "storage", "settings", "commands"], provides: [])

  static func apply(_ ctx: Context) throws(PluginError) {
    let core = TourCore(env: PluginEnv(ctx))
    tourCore = core
    core.start()
  }

  static func dispose() {
    tourCore?.stop()
    tourCore = nil
  }
}