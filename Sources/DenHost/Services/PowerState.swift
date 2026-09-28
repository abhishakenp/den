import Foundation
import IOKit.ps

/// The Mac's power situation, for `app.state` / `app.power`: running on battery, and Low Power
/// Mode.
public struct PowerState: Equatable, Sendable {
  public var battery: Bool
  public var lowPower: Bool
  public init(battery: Bool, lowPower: Bool) { (self.battery, self.lowPower) = (battery, lowPower) }
  /// Plugged in, Low Power Mode off.
  public static let ac = PowerState(battery: false, lowPower: false)
}

/// Where `AppService` gets the power state from. The app reads the Mac (`SystemPower`); tests get
/// `FixedPower` (plugged in, no Low Power Mode) unless they set otherwise, so no test depends on
/// the machine it runs on.
@MainActor
public protocol PowerSource: AnyObject {
  func read() -> PowerState
  /// Calls `changed` on the main thread whenever the state may have changed.
  func watch(_ changed: @escaping @MainActor () -> Void)
}

/// The Mac: IOKit's providing power source and `ProcessInfo.isLowPowerModeEnabled`. Changes come
/// from IOKit's power-source notification (a notify port on the main run loop) and
/// `NSProcessInfoPowerStateDidChange`, so watching costs no wakeups.
@MainActor
public final class SystemPower: PowerSource {
  public init() {}

  public func read() -> PowerState {
    var battery = false
    if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(), let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
      battery = (type as String) == kIOPSBatteryPowerValue
    }
    return PowerState(battery: battery, lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
  }

  private static var watchers: [@MainActor () -> Void] = []
  private static var source: CFRunLoopSource?

  public func watch(_ changed: @escaping @MainActor () -> Void) {
    Self.watchers.append(changed)
    NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { changed() }
    }
    guard Self.source == nil else { return }
    guard let src = IOPSNotificationCreateRunLoopSource({ _ in MainActor.assumeIsolated { SystemPower.fire() } }, nil)?.takeRetainedValue() else { return }
    Self.source = src
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
  }

  private static func fire() { for w in watchers { w() } }
}

/// A power state that only changes when told to (tests).
@MainActor
public final class FixedPower: PowerSource {
  public var state: PowerState { didSet { if state != oldValue { watchers.forEach { $0() } } } }
  private var watchers: [@MainActor () -> Void] = []
  public init(_ state: PowerState = .ac) { self.state = state }
  public func read() -> PowerState { state }
  public func watch(_ changed: @escaping @MainActor () -> Void) { watchers.append(changed) }
}
