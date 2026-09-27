import AppKit
import Foundation
import DenTestSupport
import Testing

@testable import DenHost

/// The menu bar is built on the launch path (applicationWillFinishLaunching): keep it cheap.
@MainActor
@Suite(.serialized, .watchdog)
struct MenuCostTests {
  @Test func installingTheMenuBarIsCheap() {
    _ = NSApplication.shared
    MainMenu.install()  // warm (first-use costs of AppKit, SF symbols not involved)
    // Best of 5 batches: the minimum is what the code costs; load only ever adds to it.
    let n = 20, clock = ContinuousClock()
    let ms = (0..<5).map { _ in
      let t = clock.measure { for _ in 0..<n { MainMenu.install() } }
      return Double(t.components.attoseconds) / 1e15 / Double(n) + Double(t.components.seconds) * 1000 / Double(n)
    }.min()!
    print("menu.install ms \(String(format: "%.2f", ms))")
    // 1.1 ms measured on an idle-ish machine, 9 ms at load average 600: a regression guard only.
    #expect(ms < 50)
  }
}
