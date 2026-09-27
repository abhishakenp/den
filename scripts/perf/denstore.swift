// denstore: rewrites a den storage root so the tabs plugin restores ZERO tabs (no favorites, pinned,
// folders, splits, today tabs, archive). Spaces are kept. Used by scripts/perf.sh to measure den's
// minimum footprint: the host with no web content at all.
//   denstore empty-tabs <storage dir>
//   denstore tabs <N> <storage dir>   same, then N never-loaded tabs in the first space's Today list with
//                                     nothing selected: the per-tab cost of a discarded tab (metadata only)
// The file format is Cordis' Value codec (see cordis-swift Sources/CordisValue/Codec.swift):
//   tag 0 null | 1 false | 2 true | 3 i64 | 4 f64 | 5 string u32+utf8 | 6 bytes u32+raw
//   7 array u32 count + values | 8 object u32 count + (u32 key len + key, value)*   (little-endian)
import Foundation

indirect enum V { case null, bool(Bool), int(Int64), double(Double), string(String), bytes([UInt8]), array([V]), object([(String, V)]) }

struct Reader {
  let b: [UInt8]; var i = 0
  mutating func u32() -> Int { defer { i += 4 }; return Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
  mutating func u64() -> UInt64 { var v: UInt64 = 0; for k in 0..<8 { v |= UInt64(b[i + k]) << (8 * k) }; i += 8; return v }
  mutating func raw(_ n: Int) -> [UInt8] { defer { i += n }; return Array(b[i..<(i + n)]) }
  mutating func read() -> V {
    let t = b[i]; i += 1
    switch t {
    case 0: return .null
    case 1: return .bool(false)
    case 2: return .bool(true)
    case 3: return .int(Int64(bitPattern: u64()))
    case 4: return .double(Double(bitPattern: u64()))
    case 5: let n = u32(); return .string(String(decoding: raw(n), as: UTF8.self))
    case 6: let n = u32(); return .bytes(raw(n))
    case 7: let n = u32(); return .array((0..<n).map { _ in read() })
    case 8:
      let n = u32()
      return .object((0..<n).map { _ in let k = u32(); let key = String(decoding: raw(k), as: UTF8.self); return (key, read()) })
    default: fatalError("unknown tag \(t) at \(i - 1)")
    }
  }
}
func encode(_ v: V, _ o: inout [UInt8]) {
  func u32(_ n: Int) { for k in 0..<4 { o.append(UInt8(truncatingIfNeeded: n >> (8 * k))) } }
  func u64(_ n: UInt64) { for k in 0..<8 { o.append(UInt8(truncatingIfNeeded: n >> (8 * UInt64(k)))) } }
  switch v {
  case .null: o.append(0)
  case let .bool(x): o.append(x ? 2 : 1)
  case let .int(x): o.append(3); u64(UInt64(bitPattern: x))
  case let .double(x): o.append(4); u64(x.bitPattern)
  case let .string(s): o.append(5); u32(s.utf8.count); o += Array(s.utf8)
  case let .bytes(b): o.append(6); u32(b.count); o += b
  case let .array(a): o.append(7); u32(a.count); for x in a { encode(x, &o) }
  case let .object(p): o.append(8); u32(p.count); for (k, x) in p { u32(k.utf8.count); o += Array(k.utf8); encode(x, &o) }
  }
}
func set(_ v: V, _ f: (String, V) -> V) -> V { if case let .object(p) = v { return .object(p.map { ($0.0, f($0.0, $0.1)) }) }; return v }

let args = CommandLine.arguments
guard (args.count == 3 && args[1] == "empty-tabs") || (args.count == 4 && args[1] == "tabs" && Int(args[2]) != nil) else {
  print("usage: denstore empty-tabs <storage dir> | denstore tabs <N> <storage dir>"); exit(2)
}
let count = args[1] == "tabs" ? Int(args[2])! : 0
let url = URL(fileURLWithPath: args.last!).appendingPathComponent("tabs.cvalue")
let ids = (0..<count).map { "perf-tab-\($0 + 1)" }
let now = Int64(Date().timeIntervalSince1970 * 1000)
let tabValues: [V] = ids.enumerated().map { i, id in
  .object([("id", .string(id)), ("title", .string("Perf tab \(i + 1)")), ("customTitle", .null),
           ("url", .string("https://example.com/?perf=\(i + 1)")), ("pinnedUrl", .null), ("favicon", .null), ("lastActive", .int(now))])
}
guard let data = try? Data(contentsOf: url) else { print("no \(url.path) (launch den once on this store first)"); exit(2) }
var r = Reader(b: [UInt8](data))
let root = r.read()
precondition(r.i == r.b.count, "trailing bytes: not a Cordis value")
let emptied = set(root) { k, state in
  guard k == "state" else { return state }
  return set(state) { key, v in
    switch key {
    case "tabs": return .array(tabValues)
    case "folders", "splits", "favorites", "archive", "mru": return .array([])
    case "spaces":
      guard case let .array(spaces) = v else { return v }
      return .array(spaces.enumerated().map { j, sp in
        set(sp) { sk, sv in sk == "pinned" ? .array([]) : sk == "today" ? .array(j == 0 ? ids.map { .string($0) } : []) : sk == "selected" ? .null : sv }
      })
    default: return v
    }
  }
}
var out: [UInt8] = []
encode(emptied, &out)
try! Data(out).write(to: url, options: .atomic)
print("\(count) tabs, nothing selected, in \(url.path) (\(data.count) -> \(out.count) bytes)")
