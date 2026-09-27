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

  static func snapshot(_ web: WKWebView) async -> NSImage? {
    await withCheckedContinuation { cont in
      web.takeSnapshot(with: nil) { img, _ in cont.resume(returning: img) }
    }
  }

  static func allWebViews(in v: NSView) -> [WKWebView] {
    if let w = v as? WKWebView { return [w] }
    return v.subviews.flatMap(allWebViews)
  }
}
