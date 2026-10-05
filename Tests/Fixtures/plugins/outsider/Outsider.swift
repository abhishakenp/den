// Test fixture (PluginPlatformTests): a third-party plugin that tries things on the test's behalf,
// so the test can check what den lets a sandboxed plugin do. Built with cordis-build by the test.
import CCordis  // stdlib.h: mkstemp

nonisolated(unsafe) var heard: [Value] = []

struct Plugin: CordisPlugin {
  static let manifest = Manifest(name: "Outsider", version: "1.0.0", provides: ["outsider"])

  static func apply(_ ctx: Context) throws(PluginError) {
    heard = []
    for e in ["ai.result", "net.result", "webviews.injectResult", "outsider.ping", "ui.action"] {
      ctx.on(e) { v in heard.append(["event": .string(e), "payload": v]) }
    }
    ctx.provide("outsider") { method, args in
      switch method {
      case "try":
        return ctx.call(args["service"].string ?? "", args["method"].string ?? "", args["args"])
      case "emit":
        ctx.emit(args["event"].string ?? "", args["payload"])
        return true
      case "listen":
        let event = args["event"].string ?? ""
        return .int(Int64(ctx.on(event) { v in heard.append(["event": .string(event), "payload": v]) }))
      case "heard":
        return .array(heard)
      case "touch":
        var path: [CChar] = []
        for b in "/tmp/den-outsider-XXXXXX".utf8 { path.append(CChar(bitPattern: b)) }
        path.append(0)
        return .int(Int64(path.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }))
      default:
        return .string("outsider:" + method)
      }
    }
  }
}
