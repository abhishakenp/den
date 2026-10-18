import WebKit

/// What den gives back when macOS says memory is short. Every live page is a WebContent process
/// (150-600 MB measured), so the big win is unloading pages nobody is looking at.
extension WebViewsService {
  /// Warning: every profile's in-memory resource cache is dropped (the disk cache stays, so
  /// reloads stay fast). Critical: also every live page that is not on screen is discarded, as
  /// the idle discard does (`keepReason` spares media, PiP, calls, unsaved input, visible
  /// pages). Returns how many pages were discarded.
  @discardableResult
  func purgeMemory(critical: Bool) -> Int {
    for s in liveStores { s.removeData(ofTypes: [WKWebsiteDataTypeMemoryCache], modifiedSince: .distantPast) {} }
    guard critical else { return 0 }
    var n = 0
    for r in records.values.sorted(by: { $0.id < $1.id }) where r.webView != nil && !r.id.hasPrefix("popup") {
      if suspend(r, force: false)["suspended"] == true { n += 1 }
    }
    host.emit("webviews.memoryPressure", ["critical": .bool(critical), "discarded": .int(Int64(n))])
    return n
  }
}
