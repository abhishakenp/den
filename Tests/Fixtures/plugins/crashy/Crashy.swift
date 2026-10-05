// Test fixture (PluginPlatformTests): a plugin that crashes on demand, built with cordis-build by
// the test; not part of any SwiftPM target.
struct Plugin: CordisPlugin {
  static let manifest = Manifest(name: "Crashy", version: "1.0.0", provides: ["crashy"])

  static func apply(_ ctx: Context) throws(PluginError) {
    ctx.on("crashy.boom") { _ in
      let none: [Int64] = []
      _ = none[3]
    }
    ctx.provide("crashy") { method, args in
      switch method {
      case "trap":
        let items: [Int64] = []
        return .int(items[Int(args.int ?? 3)])
      case "segv":
        let p = UnsafeMutablePointer<Int64>(bitPattern: 8)!
        p.pointee = 1
        return .int(p.pointee)
      default:
        return .string("fine")
      }
    }
  }
}
