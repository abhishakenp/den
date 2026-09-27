import AppKit
import DenTestSupport
import Foundation
import Testing

/// Swift Testing has no global traits, so the per-test watchdog rides on every suite. This keeps
/// it that way: a new suite without `.watchdog` fails here instead of being able to hang a run.
@Suite(.watchdog)
struct WatchdogCoverageTests {
  @Test func everySuiteHasTheWatchdog() throws {
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    var missing: [String] = []
    for target in ["DenHostTests", "PluginTests"] {
      let dir = tests.appendingPathComponent(target)
      for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".swift") {
        let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
        guard text.contains("@Test") else { continue }
        // Each suite type is declared at top level as `struct …` / `final class …` after its attributes.
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() where line.hasPrefix("struct ") || line.hasPrefix("@Suite") && line.contains("struct ") {
          let attrs = lines[max(0, i - 3)...i].joined(separator: " ")
          if !attrs.contains(".watchdog") { missing.append("\(target)/\(name):\(i + 1) \(line)") }
        }
      }
    }
    #expect(missing.isEmpty, "suites without .watchdog: \(missing)")
  }

  /// The watchdog itself: a test that overruns its limit is reported (not hung) and cancelled.
  @Test func boundedWaitsGiveUp() async {
    let start = ContinuousClock.now
    let never = await Wait.until("something that never happens", seconds: 0.2) { false }
    #expect(!never)
    let late: Int? = await Wait.callback("a callback that never comes", seconds: 0.2) { (_: @escaping @Sendable (Int) -> Void) in }
    #expect(late == nil)
    #expect(ContinuousClock.now - start < .seconds(5))
  }

  /// Test windows never show on the user's screen: every way of ordering one in leaves it at
  /// alpha 0 in the window server, while AppKit code still reads the alpha it set.
  @Test @MainActor func testWindowsAreInvisible() async throws {
    try #require(Invisible.enabled, "DEN_TEST_SHOW_WINDOWS=1 is set")
    #expect(NSApplication.shared.activationPolicy() == .prohibited)
    func serverAlpha(_ w: NSWindow) -> Double? {
      let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(w.windowNumber)) as? [[String: Any]]
      return list?.first?[kCGWindowAlpha as String] as? Double
    }
    let orderers: [(String, (NSWindow) -> Void)] = [
      ("orderFront", { $0.orderFront(nil) }), ("orderFrontRegardless", { $0.orderFrontRegardless() }),
      ("makeKeyAndOrderFront", { $0.makeKeyAndOrderFront(nil) }), ("orderBack", { $0.orderBack(nil) }),
      ("fade in", { $0.alphaValue = 0.5; $0.orderFront(nil); $0.animator().alphaValue = 1 }),
    ]
    for (name, show) in orderers {
      let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 200, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
      w.isReleasedWhenClosed = false
      show(w)
      #expect(w.isVisible, "\(name)")
      // The window server learns about the window when the run loop turns.
      #expect(await Wait.until("\(name): window server lists the window", seconds: 10) { serverAlpha(w) != nil })
      #expect(serverAlpha(w) == 0, "\(name): window server alpha \(String(describing: serverAlpha(w)))")
      w.alphaValue = 0.7
      try await Task.sleep(for: .milliseconds(50))
      #expect(abs(w.alphaValue - 0.7) < 0.001 && serverAlpha(w) == 0, "\(name): alpha after set")
      w.orderOut(nil)
    }
  }

  // Self-tests of the watchdog, off by default (they fail on purpose):
  //   DEN_WATCHDOG_SELFTEST=1 DEN_TEST_LIMIT=3 DEN_TEST_GRACE=3 scripts/test.sh --filter WatchdogSelfTest
  // `cooperative` must fail with a WATCHDOG report after 3 s and let the run continue;
  // `blockedMainThread` must end the process (exit 1) with the report ~6 s in.
  static let selfTest = ProcessInfo.processInfo.environment["DEN_WATCHDOG_SELFTEST"] == "1"
}

@Suite(.serialized, .watchdog, .enabled(if: WatchdogCoverageTests.selfTest))
struct WatchdogSelfTest {
  @Test func cooperative() async {
    _ = await Wait.until("a flag nobody sets", seconds: 3600) { false }
  }

  @Test @MainActor func blockedMainThread() {
    Wait.note("a semaphore nobody signals, on the main thread")
    DispatchSemaphore(value: 0).wait()
  }
}
