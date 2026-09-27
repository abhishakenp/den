import AppKit
import Foundation
import Testing

@testable import DenHost

/// The menu bar is built on the launch path (applicationWillFinishLaunching): keep it cheap.
@MainActor
@Suite(.serialized)
struct MenuCostTests {
  @Test func installingTheMenuBarIsCheap() {
    _ = NSApplication.shared
    MainMenu.install()  // warm (first-use costs of AppKit, SF symbols not involved)
    let n = 20
    let t0 = Date()
    for _ in 0..<n { MainMenu.install() }
    let ms = Date().timeIntervalSince(t0) * 1000 / Double(n)
    print("menu.install ms \(String(format: "%.2f", ms))")
    // 1.1 ms measured on an idle-ish machine, 9 ms at load average 600: a regression guard only.
    #expect(ms < 50)
  }
}
