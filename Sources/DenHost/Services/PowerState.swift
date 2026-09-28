import Foundation
import IOKit.ps

/// The Mac's power situation, for `app.state` / `app.power`: running on battery, and Low Power
/// Mode. Read on demand; changes arrive from IOKit's power-source notification (a notify port on
/// the main run loop) and `NSProcessInfoPowerStateDidChange`, so watching costs no wakeups.
public struct PowerState: Equatable, Sendable {
  public var battery: Bool
  public var lowPower: Bool
  public init(battery: Bool, lowPower: Bool) { (self.battery, self.lowPower) = (battery, lowPower) }

  public static func read() -> PowerState {
    var battery = false
    if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
      battery = (type as String) == kIOPSBatteryPowerValue
    }
    return PowerState(battery: battery, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
  }

  @MainActor private static var watchers: [@MainActor () -> Void] = []
  @MainActor private static var source: CFRunLoopSource?

  /// Calls `f` on the main thread whenever the power source changes (one run-loop source for all).
  @MainActor static func watch(_ f: @escaping @MainActor () -> Void) {
    watchers.append(f)
    guard source == nil else { return }
    guard let src = IOPSNotificationCreateRunLoopSource({ _ in MainActor.assumeIsolated { PowerState.fire() } }, nil)?.takeRetainedValue() else { return }
    source = src
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
  }

  @MainActor private static func fire() { for w in watchers { w() } }
}
