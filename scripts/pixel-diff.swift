// Pixel diff for den's UI goldens (docs/architecture/thin-host.md §6, step 0).
//   swift scripts/pixel-diff.swift <a.png|dirA> <b.png|dirB> [--tolerance N] [--out <dir>] [--noise <file>]
// Compares two PNGs, or every same-named PNG in two folders (a CI `snapshots` artifact against the
// goldens). A pixel differs when any RGBA channel differs by more than --tolerance (0-255, default 0).
// Prints one line per image: `same`, `DIFF <n> px (<pct>%) bbox x,y,w,h`, `SIZE`, `only-a`, `only-b`.
// --out writes <name>.diff.png for every differing image: the b image dimmed to grey with the
// differing pixels in red. --noise names images (one per line, `#` comments) that are known to vary
// between two renders of the same commit (network pages, clocks); they are reported as `noise` and
// never fail the run. Exit 0 when nothing outside the noise list differs, 1 otherwise, 2 on bad input.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Bitmap {
  let width: Int, height: Int
  var bytes: [UInt8]  // RGBA, premultiplied, sRGB
}

func load(_ url: URL) -> Bitmap? {
  guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
  let w = img.width, h = img.height
  var bytes = [UInt8](repeating: 0, count: w * h * 4)
  let ok = bytes.withUnsafeMutableBytes { p -> Bool in
    guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return true
  }
  return ok ? Bitmap(width: w, height: h, bytes: bytes) : nil
}

func write(_ b: Bitmap, to url: URL) {
  var bytes = b.bytes
  bytes.withUnsafeMutableBytes { p in
    guard let ctx = CGContext(data: p.baseAddress, width: b.width, height: b.height, bitsPerComponent: 8, bytesPerRow: b.width * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
      let img = ctx.makeImage(), let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dst, img, nil)
    CGImageDestinationFinalize(dst)
  }
}

struct Result {
  var differing = 0
  var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
}

func compare(_ a: Bitmap, _ b: Bitmap, tolerance: Int, diff: inout Bitmap?) -> Result {
  var r = Result()
  var out = diff
  for y in 0..<a.height {
    for x in 0..<a.width {
      let i = (y * a.width + x) * 4
      var d = 0
      for c in 0..<4 { d = max(d, abs(Int(a.bytes[i + c]) - Int(b.bytes[i + c]))) }
      if d > tolerance {
        r.differing += 1
        r.minX = min(r.minX, x); r.maxX = max(r.maxX, x)
        r.minY = min(r.minY, y); r.maxY = max(r.maxY, y)
        if out != nil { out!.bytes[i] = 255; out!.bytes[i + 1] = 0; out!.bytes[i + 2] = 0; out!.bytes[i + 3] = 255 }
      } else if out != nil {
        let g = UInt8((Int(b.bytes[i]) + Int(b.bytes[i + 1]) + Int(b.bytes[i + 2])) / 3 / 3 + 170)
        out!.bytes[i] = g; out!.bytes[i + 1] = g; out!.bytes[i + 2] = g; out!.bytes[i + 3] = 255
      }
    }
  }
  diff = out
  return r
}

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
  guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
  let v = args[i + 1]
  args.removeSubrange(i...(i + 1))
  return v
}
let tolerance = Int(option("--tolerance") ?? "0") ?? 0
let outDir = option("--out").map { URL(fileURLWithPath: $0, isDirectory: true) }
let noise: Set<String> = Set((option("--noise").flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "")
  .split(separator: "\n").map { $0.split(separator: "#").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" }.filter { !$0.isEmpty })
guard args.count == 2 else {
  FileHandle.standardError.write(Data("usage: swift scripts/pixel-diff.swift <a.png|dirA> <b.png|dirB> [--tolerance N] [--out dir] [--noise file]\n".utf8))
  exit(2)
}
let a = URL(fileURLWithPath: args[0]), b = URL(fileURLWithPath: args[1])
var isDir: ObjCBool = false
FileManager.default.fileExists(atPath: a.path, isDirectory: &isDir)
var pairs: [(String, URL?, URL?)] = []
if isDir.boolValue {
  func pngs(_ d: URL) -> [String: URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
    return Dictionary(uniqueKeysWithValues: names.filter { $0.hasSuffix(".png") && !$0.hasSuffix(".diff.png") }.map { ($0, d.appendingPathComponent($0)) })
  }
  let la = pngs(a), lb = pngs(b)
  for n in Set(la.keys).union(lb.keys).sorted() { pairs.append((n, la[n], lb[n])) }
} else {
  pairs.append((b.lastPathComponent, a, b))
}
if let outDir { try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true) }
var failed = 0, same = 0, noisy = 0
for (name, ua, ub) in pairs {
  let stem = String(name.dropLast(4))
  let isNoise = noise.contains(stem) || noise.contains(name)
  guard let ua, let ub else {
    print("\(ua == nil ? "only-b" : "only-a") \(name)")
    continue
  }
  guard let ia = load(ua), let ib = load(ub) else { print("UNREADABLE \(name)"); failed += 1; continue }
  guard ia.width == ib.width, ia.height == ib.height else {
    print("\(isNoise ? "noise" : "SIZE") \(name) \(ia.width)x\(ia.height) vs \(ib.width)x\(ib.height)")
    if isNoise { noisy += 1 } else { failed += 1 }
    continue
  }
  var diff: Bitmap? = outDir == nil ? nil : ib
  let r = compare(ia, ib, tolerance: tolerance, diff: &diff)
  if r.differing == 0 { same += 1; print("same \(name)"); continue }
  let pct = Double(r.differing) * 100 / Double(ia.width * ia.height)
  print(String(format: "%@ %@ %d px (%.3f%%) bbox %d,%d,%d,%d", isNoise ? "noise" : "DIFF", name, r.differing, pct,
               r.minX, r.minY, r.maxX - r.minX + 1, r.maxY - r.minY + 1))
  if isNoise { noisy += 1 } else { failed += 1 }
  if let outDir, let diff { write(diff, to: outDir.appendingPathComponent(stem + ".diff.png")) }
}
print("pixel-diff: \(same) same, \(failed) differ, \(noisy) noise (tolerance \(tolerance))")
exit(failed == 0 ? 0 : 1)
