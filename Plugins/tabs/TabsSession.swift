// The restorable session in ~/.den/logs/den.log (it was the host's `sessionSummary`;
// docs/architecture/thin-host.md §6 step 2). After den logs a launch (first window) or a quit, the
// host emits `app.session {phase}`; this logs `session <phase> spaces=… current=… tabs=…
// selected=… sig=…` with `app.log`. `sig` is an FNV-1a hash of every tab's id and URL, equal
// before a quit and after the relaunch when the session survived (scripts/lib/app.zsh compares).

#if !hasFeature(Embedded)
  import CordisValue
#endif

extension TabsCore {
  func startSessionLog() {
    env.on("app.session") { [self] v in
      let phase = v.s("phase")
      guard phase == "launch" || phase == "quit" else { return }
      env.call("app", "log", ["line": .string("session " + phase + " " + sessionSummary())])
    }
  }

  /// `spaces=<n> current=<space> tabs=<n> selected=<tab> sig=<hex>`.
  func sessionSummary() -> String {
    var ids: [String] = []
    var sig = ""
    let spaces = env.call("spaces", "list").array ?? []
    for (j, sp) in spaces.enumerated() {
      let l = list(sp.s("id"))
      var stack: [Value] = (j == 0 ? l.a("favorites") : []) + l.a("pinned") + l.a("today")
      stack.reverse()
      while let i = stack.popLast() {
        if i.b("folder") || i.b("split") {
          stack += i.a("children").reversed()
        } else {
          ids.append(i.s("id"))
          sig += i.s("id") + " " + i.s("url") + "\n"
        }
      }
    }
    var h: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV-1a
    for b in sig.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
    let selected = handle("selected", .null)["id"].string ?? "-"
    let current = env.call("spaces", "current")["id"].string ?? "-"
    return "spaces=" + String(spaces.count) + " current=" + current + " tabs=" + String(ids.count) + " selected=" + selected + " sig=" + Self.hex(h)
  }

  /// Lowercase hex, no leading zeros (as `String(h, radix: 16)`).
  static func hex(_ v: UInt64) -> String {
    let digits: [UInt8] = Array("0123456789abcdef".utf8)
    var out: [UInt8] = []
    var x = v
    repeat {
      out.append(digits[Int(x & 15)])
      x >>= 4
    } while x > 0
    return String(decoding: out.reversed(), as: UTF8.self)
  }
}
