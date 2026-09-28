import AppKit
import CordisValue
import Foundation
import Testing

@testable import DenHost
@testable import PluginCores

/// ⌘W latency: the synchronous work from the key to the next tab being in the content area,
/// with a realistic sidebar (60 Today tabs) and archive (400 entries). Prints the median so a
/// change can be compared before and after (docs/perf/baseline.md).
@MainActor
@Suite(.serialized)
struct CloseLatencyTests {
  @Test func closeLatency() {
    let h = Harness()
    h.startTabs()
    for n in 0..<400 { h.tabs("addToArchive", ["url": .string("https://archive.example/\(n)"), "title": .string("Archived \(n)")]) }
    for n in 0..<60 { h.tabs("open", ["url": .string("https://example.com/page/\(n)"), "background": true]) }
    var samples: [Double] = []
    for _ in 0..<25 {
      let target = h.ids("today")[5]
      h.tabs("select", ["id": .string(target)])
      let t0 = ContinuousClock.now
      h.key("cmd+w")
      let d = ContinuousClock.now - t0
      samples.append(Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000)
      #expect(h.selected != target)
      #expect(h.rt.call("content", "get")["panes"] == [.string(h.selected!)])
    }
    samples.sort()
    print(String(format: "closeLatency median %.2f ms p90 %.2f ms (n=%d)", samples[samples.count / 2], samples[samples.count * 9 / 10], samples.count))
  }
}
