import AppKit
import DenTestSupport
import Testing

@testable import DenHost

/// Dark-mode favicons: dark monochrome icons on transparency (GitHub) are drawn inverted.
@MainActor
@Suite(.watchdog) struct IconTests {
  static func image(_ draw: @escaping (NSRect) -> Void) -> NSImage {
    NSImage(size: NSSize(width: 32, height: 32), flipped: false) { r in draw(r); return true }
  }

  /// GitHub's favicon shape: a black disc with a white shape knocked out, clear corners.
  static let githubLike = image { r in
    NSColor.black.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
    NSColor.white.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 11, dy: 11)).fill()
  }

  @Test func classifiesDarkMonochromeIconsOnTransparency() {
    #expect(ImageCache.isDarkGlyph(Self.githubLike))
    // A plain black glyph, and a near-black one (#24292f).
    #expect(ImageCache.isDarkGlyph(Self.image { r in NSColor.black.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 5, dy: 5)).fill() }))
    #expect(ImageCache.isDarkGlyph(Self.image { r in
      NSColor(srgbRed: 0x24 / 255, green: 0x29 / 255, blue: 0x2F / 255, alpha: 1).setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 4, dy: 4)).fill()
    }))
    // Colorful icons keep their colors.
    #expect(!ImageCache.isDarkGlyph(Self.image { r in NSColor.systemRed.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 4, dy: 4)).fill() }))
    #expect(!ImageCache.isDarkGlyph(Self.image { r in
      NSColor(srgbRed: 0.05, green: 0.1, blue: 0.45, alpha: 1).setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 4, dy: 4)).fill()
    }))
    // A dark glyph on an opaque white square is already visible on a dark sidebar.
    #expect(!ImageCache.isDarkGlyph(Self.image { r in
      NSColor.white.setFill(); r.fill()
      NSColor.black.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 6, dy: 6)).fill()
    }))
    // A light glyph (already a dark-mode icon) stays as it is.
    #expect(!ImageCache.isDarkGlyph(Self.image { r in NSColor.white.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 5, dy: 5)).fill() }))
  }

  /// Through IconView: in a dark window the disc comes out light and the knockout dark; in a
  /// light window the icon is untouched.
  @Test func iconViewInvertsDarkIconsOnlyInDarkMode() throws {
    let url = "https://example.test/github-like.png"
    ImageCache.shared.store(url, Self.githubLike)
    func brightness(dark: Bool, at p: (Int, Int)) throws -> CGFloat {
      let v = IconView(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
      v.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      v.spec = url
      let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
      v.cacheDisplay(in: v.bounds, to: rep)
      let s = CGFloat(rep.pixelsWide) / 32
      let c = try #require(rep.colorAt(x: Int(CGFloat(p.0) * s), y: Int(CGFloat(p.1) * s))?.usingColorSpace(.sRGB))
      return c.brightnessComponent
    }
    // (4, 16): on the disc; (16, 16): the knockout.
    #expect(try brightness(dark: true, at: (4, 16)) > 0.9)
    #expect(try brightness(dark: true, at: (16, 16)) < 0.1)
    #expect(try brightness(dark: false, at: (4, 16)) < 0.1)
    #expect(try brightness(dark: false, at: (16, 16)) > 0.9)
  }
}
