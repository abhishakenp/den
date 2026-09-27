// Generates Resources/den.icns: a soft three-color gradient squircle with a lowercase "d".
// Run: swift scripts/make-icon.swift  (den's own artwork; no third-party assets)
import AppKit

func render(_ px: Int) -> Data {
  let s = CGFloat(px)
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let inset = s * 0.1
  let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
  let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
  let g = NSGradient(colors: [NSColor(srgbRed: 0.62, green: 0.52, blue: 1, alpha: 1), NSColor(srgbRed: 1, green: 0.55, blue: 0.72, alpha: 1), NSColor(srgbRed: 1, green: 0.8, blue: 0.55, alpha: 1)])!
  g.draw(in: path, angle: -50)
  let font = NSFont.systemFont(ofSize: rect.height * 0.62, weight: .heavy)
  let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 1, alpha: 0.95)]
  let str = "d" as NSString
  let sz = str.size(withAttributes: attrs)
  str.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2 + rect.height * 0.03), withAttributes: attrs)
  NSGraphicsContext.restoreGraphicsState()
  return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("den.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
  try! render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
  try! render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Resources/den.icns"]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/den.icns" : "iconutil failed")
