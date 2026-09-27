import AppKit
import Foundation
import Testing

@testable import DenHost

/// Favicons that would render blurry fall back to a sharp vector icon.
@MainActor
@Suite(.serialized)
struct FaviconFallbackTests {
  static func bitmap(_ px: Int) -> NSImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let img = NSImage(size: NSSize(width: px, height: px))
    img.addRepresentation(rep)
    return img
  }

  @Test func googlesSixteenPixelGlobeIsNoFavicon() {
    let s2 = "https://www.google.com/s2/favicons?domain=nosuchsite.test&sz=64"
    #expect(ImageCache.isServiceFallback(s2, Self.bitmap(16)))
    #expect(!ImageCache.isServiceFallback(s2, Self.bitmap(64)))  // a real icon at the size asked
    #expect(!ImageCache.isServiceFallback("https://example.com/favicon.ico", Self.bitmap(16)))  // a site's own small icon stays
  }

  /// A favicon that doesn't load draws a vector fallback (the site's letter tile, or the globe
  /// symbol without a domain): at 2x its edges are anti-aliased at device pixels (sharp), not a
  /// 16 px bitmap scaled up.
  @Test func missingFaviconDrawsAVectorGlobeAtBackingScale() throws {
    let v = IconView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
    v.spec = "https://nothing.invalid/favicon.ico"  // never loads in a test
    v.tint = .black
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = NSSize(width: 16, height: 16)  // 2x
    v.cacheDisplay(in: v.bounds, to: rep)
    var inked = 0
    for x in 0..<32 { for y in 0..<32 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { inked += 1 } }
    #expect(inked > 40)  // the globe was drawn
  }
}
