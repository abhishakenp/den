import AppKit
import WebKit

/// Renders a window (including its titlebar buttons) to PNG without Screen Recording permission.
/// AppKit content comes from `cacheDisplay`; WKWebView content (which renders out of process
/// and is blank in `cacheDisplay`) is composited from `takeSnapshot` via temporary image views.
@MainActor
public enum Snapshotter {
  public static func capture(_ window: NSWindow) async -> NSBitmapImageRep? {
    guard let frameView = window.contentView?.superview else { return nil }
    var temps: [NSView] = []
    for web in allWebViews(in: frameView) where !web.isHiddenOrHasHiddenAncestor && web.bounds.width > 1 {
      guard let img = await snapshot(web), let parent = web.superview else { continue }
      let iv = NSImageView(frame: web.frame)
      iv.image = img
      iv.imageScaling = .scaleAxesIndependently
      iv.autoresizingMask = web.autoresizingMask
      parent.addSubview(iv, positioned: .above, relativeTo: web)
      temps.append(iv)
    }
    frameView.layoutSubtreeIfNeeded()
    frameView.display()
    let rect = frameView.bounds
    guard let rep = frameView.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
    frameView.cacheDisplay(in: rect, to: rep)
    temps.forEach { $0.removeFromSuperview() }
    return rep
  }

  public static func write(_ window: NSWindow, to path: String) async -> Bool {
    guard let rep = await capture(window), let data = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? data.write(to: URL(fileURLWithPath: path))) != nil
  }

  /// Longest wait for one web view's `takeSnapshot`. WebKit never calls back for a page it
  /// doesn't paint (a suspended or occluded one), so this is bounded rather than a hang.
  public static var webTimeout: TimeInterval = 10

  static func snapshot(_ web: WKWebView) async -> NSImage? {
    let timeout = webTimeout
    return await withCheckedContinuation { cont in
      let once = Once(cont)
      web.takeSnapshot(with: nil) { img, _ in MainActor.assumeIsolated { once.resume(img) } }
      DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
        MainActor.assumeIsolated {
          guard !once.done else { return }
          print("snapshot: web view \(web.url?.absoluteString ?? "(no url)") gave no image within \(Int(timeout)) s; its area is left as drawn")
          once.resume(nil)
        }
      }
    }
  }

  /// Resumes a continuation at most once (the snapshot or the timeout, whichever comes first).
  @MainActor final class Once {
    let cont: CheckedContinuation<NSImage?, Never>
    var done = false
    init(_ cont: CheckedContinuation<NSImage?, Never>) { self.cont = cont }
    func resume(_ img: NSImage?) {
      guard !done else { return }
      done = true
      cont.resume(returning: img)
    }
  }

  static func allWebViews(in v: NSView) -> [WKWebView] {
    if let w = v as? WKWebView { return [w] }
    return v.subviews.flatMap(allWebViews)
  }
}
