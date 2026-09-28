import Foundation

/// Gives memory a one-off job freed back to the system now rather than under memory pressure
/// (`malloc_zone_pressure_relief`, off the main thread). It returns freed small blocks (the
/// snapshot encoder's buffers); it does not release malloc's cache of freed large blocks, which
/// den turns off instead (`MallocLargeCache=0` in Info.plist's LSEnvironment; perf lab,
/// docs/perf/baseline.md).
public enum MemoryRelief {
  /// Relieves after `delay` seconds (the job's buffers are released a moment after it reports).
  public static func soon(after delay: Double = 0.5) {
    DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + delay) { malloc_zone_pressure_relief(nil, 0) }
  }
}
