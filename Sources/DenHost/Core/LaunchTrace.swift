import Foundation

/// `DEN_TRACE=1`: prints `trace <phase> <ms since process start>` at each launch phase, from the
/// app and from inside the host (runtime init, plugin loads). Off: one branch per mark.
@MainActor
public enum LaunchTrace {
  public nonisolated static let on = ProcessInfo.processInfo.environment["DEN_TRACE"] != nil
  /// Process start (kernel), so marks include dyld and runtime init.
  public nonisolated static let processStart: Date = {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
    let tv = info.kp_proc.p_starttime
    return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
  }()

  public static func mark(_ phase: @autoclosure () -> String) {
    guard on else { return }
    print(String(format: "trace %@ %.1f", phase(), Date().timeIntervalSince(processStart) * 1000))
  }
}
