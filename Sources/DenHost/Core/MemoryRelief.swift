import Foundation

/// Gives memory that big one-off jobs freed back to the system now, instead of under memory
/// pressure. malloc keeps freed large and small blocks dirty in the process (they count in its
/// footprint, `MALLOC_LARGE (empty)` in vmmap): a content rule list compile in den's process
/// peaked at 282 MB and left 27 MB of it dirty for the rest of the session (perf lab, 2026-09-28).
/// `malloc_zone_pressure_relief` returns them; it takes about a millisecond, off the main thread.
public enum MemoryRelief {
  /// Relieves after `delay` seconds (the job's buffers are released a moment after it reports).
  public static func soon(after delay: Double = 0.5) {
    DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + delay) { malloc_zone_pressure_relief(nil, 0) }
  }
}
