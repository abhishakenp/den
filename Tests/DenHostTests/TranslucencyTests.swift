import AppKit
import CordisValue
import DenTestSupport
import Testing

@testable import DenHost

/// Settings ▸ General ▸ Translucent window: off by default (nothing created), on puts macOS's
/// behind-window material under a see-through theme in every window, now and later; off removes it.
@MainActor
@Suite(.serialized, .watchdog)
struct TranslucencyTests {
  static func footprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
  }

  @Test func offByDefaultOnEverywhereThenOff() async throws {
    defer { ThemeBackgroundView.translucency = false }
    let rt = ServiceTests.runtime()
    let views = { rt.windows.all.flatMap { [$0.background, $0.sidebar.backdrop] } }
    #expect(!ThemeBackgroundView.translucency)
    #expect(views().allSatisfy { $0.material == nil && !$0.translucent })
    rt.window.window.displayIfNeeded()
    let before = Self.footprint()
    rt.call("settings", "set", ["id": "general", "key": "translucent", "value": true])
    #expect(views().allSatisfy { $0.translucent && $0.material?.blendingMode == .behindWindow })
    // The material sits under the theme's gradient, which lets it show through.
    let bg = rt.window.background
    #expect(bg.layer?.sublayers?.first === bg.material?.layer)
    #expect(bg.layer?.sublayers?.contains { ($0 as? CAGradientLayer)?.opacity == ThemeBackgroundView.translucentOpacity } == true)
    rt.window.window.displayIfNeeded()
    print("translucency footprint delta (2 views, one window): \(Int64(Self.footprint()) - Int64(before)) bytes")
    // A window opened afterwards is translucent too.
    rt.call("window", "new")
    #expect(rt.windows.all.count == 2)
    #expect(views().allSatisfy { $0.translucent && $0.material != nil })
    // Off: the material is gone and the theme is opaque again.
    rt.call("settings", "set", ["id": "general", "key": "translucent", "value": false])
    #expect(views().allSatisfy { !$0.translucent && $0.material == nil })
    #expect(bg.layer?.sublayers?.contains { ($0 as? CAGradientLayer)?.opacity == 1 } == true)
    rt.tearDown()
  }
}
