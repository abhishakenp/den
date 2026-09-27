// Composes a labelled grid of snapshot crops (scripts/snapshots.sh → docs/screenshots/theming-grid.png).
// usage: swift scripts/lib/grid.swift <out.png> <cols> <cellW> <cellH> <label|path|x0,y0,x1,y1>...
// Each cell: a crop (fractions of the image) scaled to fit; a row label starts a new row.
import AppKit

let a = CommandLine.arguments
let out = a[1], cols = Int(a[2])!, cw = CGFloat(Double(a[3])!), ch = CGFloat(Double(a[4])!)
var rows: [(String, [(String, CGRect)])] = []
var i = 5
while i < a.count {
  if a[i].hasPrefix("label:") { rows.append((String(a[i].dropFirst(6)), [])); i += 1; continue }
  let f = a[i + 1].split(separator: ",").map { CGFloat(Double($0)!) }
  rows[rows.count - 1].1.append((a[i], CGRect(x: f[0], y: f[1], width: f[2] - f[0], height: f[3] - f[1])))
  i += 2
}
let labelW: CGFloat = 150, pad: CGFloat = 8
let W = labelW + CGFloat(cols) * (cw + pad) + pad, H = CGFloat(rows.count) * (ch + pad) + pad
let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()
NSColor(white: 0.5, alpha: 1).setFill()
NSRect(x: 0, y: 0, width: W, height: H).fill()
for (r, row) in rows.enumerated() {
  let y = H - pad - CGFloat(r + 1) * (ch + pad) + pad
  (row.0 as NSString).draw(at: NSPoint(x: 10, y: y + ch / 2 - 8), withAttributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.white])
  for (c, cell) in row.1.enumerated() {
    guard let src = NSImage(contentsOfFile: cell.0), let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
    let iw = CGFloat(cg.width), ih = CGFloat(cg.height)
    let crop = CGRect(x: cell.1.minX * iw, y: cell.1.minY * ih, width: cell.1.width * iw, height: cell.1.height * ih)
    guard let part = cg.cropping(to: crop) else { continue }
    let s = min(cw / crop.width, ch / crop.height)
    let dw = crop.width * s, dh = crop.height * s
    let x = labelW + pad + CGFloat(c) * (cw + pad) + (cw - dw) / 2
    NSGraphicsContext.current?.imageInterpolation = .high
    NSImage(cgImage: part, size: NSSize(width: dw, height: dh)).draw(in: NSRect(x: x, y: y + (ch - dh) / 2, width: dw, height: dh))
  }
}
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("grid: \(out) \(Int(W))x\(Int(H))")
