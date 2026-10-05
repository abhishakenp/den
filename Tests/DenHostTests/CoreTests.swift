import CordisValue
import Foundation
import DenTestSupport
import Testing

@testable import DenHost

@MainActor
@Suite(.watchdog)
struct CoreTests {
  final class Echo: HostService {
    let name = "echo"
    func handle(method: String, args: Value) -> Value { ["method": .string(method), "args": args] }
  }

  @Test func hostCallsAndEvents() {
    let host = ServiceHost()
    host.provide(Echo())
    #expect(host.call("echo", "ping", 3)["method"] == "ping")
    #expect(host.call("nope", "x").isError)
    var got: [Value] = []
    let h = host.on("a.b") { got.append($0) }
    host.emit("a.b", 1)
    host.off(h)
    host.emit("a.b", 2)
    #expect(got == [1])
  }

  @Test func storageRoundTripsAtomically() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("den-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dir) }
    let s = StorageService(root: dir)
    let value: Value = ["spaces": ["Work", "Home"], "n": 3]
    #expect(s.handle(method: "set", args: ["ns": "spaces", "key": "state", "value": value]) == .ok)
    #expect(s.handle(method: "set", args: ["ns": "spaces", "key": "n", "value": 7]) == .ok)
    // The cache keeps encoded values; the file is still the one Codec object.
    let file = try Data(contentsOf: dir.appendingPathComponent("spaces.cvalue"))
    #expect([UInt8](file) == Codec.encode(["state": value, "n": 7]))
    #expect(s.handle(method: "get", args: ["ns": "spaces", "key": "n"]) == 7)
    _ = s.handle(method: "delete", args: ["ns": "spaces", "key": "n"])
    // A fresh instance reads from disk.
    let s2 = StorageService(root: dir)
    #expect(s2.handle(method: "get", args: ["ns": "spaces", "key": "state"]) == value)
    #expect(s2.handle(method: "keys", args: ["ns": "spaces"]) == ["state"])
    _ = s2.handle(method: "delete", args: ["ns": "spaces", "key": "state"])
    #expect(StorageService(root: dir).handle(method: "get", args: ["ns": "spaces", "key": "state"]) == .null)
    #expect(s.handle(method: "get", args: ["ns": "../etc", "key": "x"]).isError)
  }
}
