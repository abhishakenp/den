import CordisValue
import Foundation

/// What den does when a page's web process dies (`webViewWebContentProcessDidTerminate`: a
/// WebKit crash, or macOS ending it for memory). The page comes back by itself at the same URL,
/// and a video picks up where it was (playing again if it was playing), so a long YouTube video
/// never needs a manual reload. A page that keeps crashing stops coming back by itself: after
/// `limit` restores within `window` seconds it shows den's "This page crashed · Reload" page.
public enum CrashRecovery {
  /// Restores allowed within `window` seconds before the crash page shows instead.
  public static let limit = 3
  public static let window: TimeInterval = 300

  /// Whether a page that crashed at `now` may come back by itself, given its earlier crashes
  /// (`times`). Returns the crash times to keep (the ones still inside the window, plus `now`).
  public static func mayRestore(_ times: [Date], now: Date) -> (restore: Bool, times: [Date]) {
    let recent = times.filter { now.timeIntervalSince($0) < window && now >= $0 }
    return (recent.count < limit, recent + [now])
  }

  /// Where a video resumes after the restore.
  public struct Resume: Equatable {
    /// The page's URL when it crashed (the resume applies only to that page).
    public let url: String
    /// Seconds into the video.
    public let time: Double
    /// It was playing (it plays again; a paused video stays paused).
    public let play: Bool
  }

  /// The resume point for the page's main video report (`PageMedia.video`: `t`, `dur`, `paused`):
  /// nil without a finite video, or near its very start or end (nothing worth keeping).
  public static func resume(url: String, video: Value?) -> Resume? {
    guard let v = video, let t = v["t"].double, let dur = v["dur"].double, dur > 0, t.isFinite else { return nil }
    guard t >= 3, t < dur - 3 else { return nil }
    return Resume(url: url, time: t, play: v["paused"].bool != true)
  }

  /// Two URLs are the same page for a resume when they match without their fragment and without
  /// a `t` (start time) query item (YouTube's own).
  public static func samePage(_ a: String, _ b: String) -> Bool {
    func key(_ s: String) -> String {
      guard var c = URLComponents(string: s) else { return s }
      c.fragment = nil
      c.queryItems = c.queryItems?.filter { $0.name != "t" }
      if c.queryItems?.isEmpty == true { c.queryItems = nil }
      return c.string ?? s
    }
    return key(a) == key(b)
  }
}
