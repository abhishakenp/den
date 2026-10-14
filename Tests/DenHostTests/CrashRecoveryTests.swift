import CordisValue
import DenTestSupport
import Foundation
import Testing

@testable import DenHost

/// CrashRecovery's rules, without a web view: when a crashed page may come back by itself, and
/// where its video resumes.
@Suite(.watchdog)
struct CrashRecoveryTests {
  @Test func aPageComesBackUntilItKeepsCrashing() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var times: [Date] = []
    for i in 0..<CrashRecovery.limit {
      let r = CrashRecovery.mayRestore(times, now: t0.addingTimeInterval(Double(i) * 10))
      #expect(r.restore)
      times = r.times
    }
    // One more inside the window: the crash page.
    let over = CrashRecovery.mayRestore(times, now: t0.addingTimeInterval(40))
    #expect(!over.restore)
    // Once the earlier crashes are older than the window, it comes back by itself again.
    let later = CrashRecovery.mayRestore(over.times, now: t0.addingTimeInterval(40 + CrashRecovery.window))
    #expect(later.restore)
    #expect(later.times.count == 1)
  }

  @Test func theVideoResumesWhereItWas() {
    let url = "https://www.youtube.com/watch?v=abc"
    let playing: Value = ["t": 754.2, "dur": 3600.0, "paused": false]
    #expect(CrashRecovery.resume(url: url, video: playing) == CrashRecovery.Resume(url: url, time: 754.2, play: true))
    let paused: Value = ["t": 30.0, "dur": 100.0, "paused": true]
    #expect(CrashRecovery.resume(url: url, video: paused)?.play == false)
    // Nothing worth keeping: no video, its first seconds, its end, a live stream (dur -1).
    #expect(CrashRecovery.resume(url: url, video: nil) == nil)
    #expect(CrashRecovery.resume(url: url, video: ["t": 1.0, "dur": 100.0, "paused": false]) == nil)
    #expect(CrashRecovery.resume(url: url, video: ["t": 99.0, "dur": 100.0, "paused": false]) == nil)
    #expect(CrashRecovery.resume(url: url, video: ["t": 50.0, "dur": -1.0, "paused": false]) == nil)
  }

  @Test func samePageIgnoresFragmentAndStartTime() {
    #expect(CrashRecovery.samePage("https://www.youtube.com/watch?v=abc", "https://www.youtube.com/watch?v=abc&t=754s"))
    #expect(CrashRecovery.samePage("https://x.test/a#top", "https://x.test/a"))
    #expect(!CrashRecovery.samePage("https://www.youtube.com/watch?v=abc", "https://www.youtube.com/watch?v=xyz"))
  }

  @Test func aTimeOnlyReportIsTheSameReport() {
    var a = PageMedia(), b = PageMedia()
    a.playing = true; b.playing = true
    a.video = ["t": 10.0, "dur": 30.0, "paused": false]
    b.video = ["t": 15.0, "dur": 30.0, "paused": false]
    #expect(a.sameIgnoringTime(b))
    b.video = ["t": 15.0, "dur": 30.0, "paused": true]
    #expect(!a.sameIgnoringTime(b))
  }
}
