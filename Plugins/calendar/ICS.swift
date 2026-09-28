#if !hasFeature(Embedded)
  import CordisValue
#endif

/// A small iCalendar (RFC 5545) reader for one question: which events happen on a given day.
///
/// Handles what calendar exports carry in practice: folded lines, `VEVENT` blocks, UTC (`…Z`),
/// floating and `TZID=` times, all-day dates, `RRULE` (DAILY, WEEKLY with BYDAY, MONTHLY with
/// BYMONTHDAY or BYDAY like `2TU` / `-1FR`, YEARLY; INTERVAL, UNTIL, COUNT), `EXDATE`, moved or
/// cancelled instances (`RECURRENCE-ID`) and `STATUS:CANCELLED`.
///
/// Limitation: plugins have no time zone database, so a `TZID=` time is read as the Mac's own
/// zone (`offsetMinutes`). Events created in another zone than the Mac's would shift by the difference.
enum ICS {
  struct Stamp {
    var wall: Int64  // local wall-clock ms since 1970 (as if UTC)
    var utc: Bool  // written with `Z`: `wall` is UTC
    var date: Bool  // a DATE (all-day), no time
  }

  struct Event {
    var uid = ""
    var summary = ""
    var start: Stamp?
    var end: Stamp?
    var rrule = ""
    var exdates: [Stamp] = []
    var recurrenceId: Stamp?
    var cancelled = false
    var location = ""
    var description = ""
    var url = ""
    var conference = ""
  }

  /// Unfolds continuation lines (a leading space or tab continues the previous line).
  static func lines(_ text: String) -> [[UInt8]] {
    var out: [[UInt8]] = []
    var cur: [UInt8] = []
    var i = 0
    let b = Array(text.utf8)
    while i < b.count {
      let c = b[i]
      if c == 13 || c == 10 {
        // End of a physical line: a following space/tab continues it.
        var j = i + 1
        if c == 13, j < b.count, b[j] == 10 { j += 1 }
        if j < b.count, b[j] == 32 || b[j] == 9 {
          i = j + 1
          continue
        }
        out.append(cur)
        cur = []
        i = j
        continue
      }
      cur.append(c)
      i += 1
    }
    if !cur.isEmpty { out.append(cur) }
    return out
  }

  /// `DTSTART;TZID=Europe/Paris:20260928T140000` -> ("DTSTART", ["TZID": "Europe/Paris"], "20260928T140000").
  static func split(_ line: [UInt8]) -> (String, [String: String], String)? {
    // The value starts after the first ':' that isn't inside a quoted parameter value.
    var quoted = false
    var colon = -1
    for (k, c) in line.enumerated() {
      if c == 34 { quoted.toggle() }
      if c == 58 && !quoted { colon = k; break }
    }
    guard colon > 0 else { return nil }
    let head = Array(line[..<colon])
    let value = String(decoding: line[(colon + 1)...], as: UTF8.self)
    var parts: [String] = []
    var cur: [UInt8] = []
    for c in head {
      if c == 59 {
        parts.append(String(decoding: cur, as: UTF8.self))
        cur = []
      } else {
        cur.append(c)
      }
    }
    parts.append(String(decoding: cur, as: UTF8.self))
    var params: [String: String] = [:]
    for p in parts.dropFirst() {
      let pb = Array(p.utf8)
      if let eq = pb.firstIndex(of: 61) {
        params[upper(String(decoding: pb[..<eq], as: UTF8.self))] = String(decoding: pb[(eq + 1)...], as: UTF8.self)
      }
    }
    return (upper(parts[0]), params, value)
  }

  static func upper(_ s: String) -> String {
    var out: [UInt8] = []
    for c in s.utf8 { out.append(c >= 97 && c <= 122 ? c - 32 : c) }
    return String(decoding: out, as: UTF8.self)
  }

  /// TEXT values: `\n`, `\,`, `\;`, `\\`.
  static func text(_ s: String) -> String {
    var out: [UInt8] = []
    var esc = false
    for c in s.utf8 {
      if esc {
        out.append(c == 110 || c == 78 ? 10 : c)
        esc = false
      } else if c == 92 {
        esc = true
      } else {
        out.append(c)
      }
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// "20260928", "20260928T140000", "20260928T140000Z".
  static func stamp(_ v: String, _ params: [String: String]) -> Stamp? {
    let b = Array(v.utf8)
    func num(_ from: Int, _ len: Int) -> Int64? {
      guard from + len <= b.count else { return nil }
      var n: Int64 = 0
      for k in from..<(from + len) {
        guard b[k] >= 48 && b[k] <= 57 else { return nil }
        n = n * 10 + Int64(b[k] - 48)
      }
      return n
    }
    guard let y = num(0, 4), let mo = num(4, 2), let d = num(6, 2) else { return nil }
    let day = Web.days(y, mo, d)
    if b.count < 15 || b[8] != 84 || params["VALUE"] == "DATE" {  // T
      return Stamp(wall: day * 86_400_000, utc: false, date: true)
    }
    guard let h = num(9, 2), let mi = num(11, 2) else { return nil }
    let s = num(13, 2) ?? 0
    return Stamp(wall: (day * 86_400 + h * 3600 + mi * 60 + s) * 1000, utc: b.last == 90, date: false)  // Z
  }

  static func parse(_ source: String) -> [Event] {
    var out: [Event] = []
    var cur: Event?
    var depth = 0  // nested components inside VEVENT (VALARM)
    for line in lines(source) {
      guard let (name, params, value) = split(line) else { continue }
      if name == "BEGIN" {
        if upper(value) == "VEVENT" { cur = Event(); depth = 0 } else if cur != nil { depth += 1 }
        continue
      }
      if name == "END" {
        if upper(value) == "VEVENT", let e = cur { out.append(e); cur = nil } else if cur != nil { depth -= 1 }
        continue
      }
      guard cur != nil, depth == 0 else { continue }
      switch name {
      case "UID": cur!.uid = value
      case "SUMMARY": cur!.summary = Web.oneLine(text(value), max: 200)
      case "DTSTART": cur!.start = stamp(value, params)
      case "DTEND": cur!.end = stamp(value, params)
      case "RRULE": cur!.rrule = upper(value)
      case "EXDATE":
        for part in commaList(value) { if let s = stamp(part, params) { cur!.exdates.append(s) } }
      case "RECURRENCE-ID": cur!.recurrenceId = stamp(value, params)
      case "STATUS": cur!.cancelled = upper(value) == "CANCELLED"
      case "LOCATION": cur!.location = text(value)
      case "DESCRIPTION": cur!.description = text(value)
      case "URL": cur!.url = value
      case "X-GOOGLE-CONFERENCE": cur!.conference = value
      default: break
      }
    }
    return out
  }

  static func commaList(_ s: String) -> [String] {
    var out: [String] = []
    var cur: [UInt8] = []
    for c in s.utf8 {
      if c == 44 {
        if !cur.isEmpty { out.append(String(decoding: cur, as: UTF8.self)) }
        cur = []
      } else {
        cur.append(c)
      }
    }
    if !cur.isEmpty { out.append(String(decoding: cur, as: UTF8.self)) }
    return out
  }

  // MARK: Occurrences

  /// A stamp as UTC ms, reading floating and `TZID=` times in the Mac's zone.
  static func utc(_ s: Stamp, offsetMinutes: Int64) -> Int64 { s.utc ? s.wall : s.wall - offsetMinutes * 60_000 }
  /// A stamp as local wall-clock ms.
  static func local(_ s: Stamp, offsetMinutes: Int64) -> Int64 { s.utc ? s.wall + offsetMinutes * 60_000 : s.wall }

  static func floorDay(_ ms: Int64) -> Int64 { ms >= 0 ? ms / 86_400_000 : (ms - 86_399_999) / 86_400_000 }
  /// 0 = Sunday … 6 = Saturday (1970-01-01 was a Thursday).
  static func weekday(_ day: Int64) -> Int64 { ((day % 7) + 7 + 4) % 7 }

  /// (year, month, day of month) of a day number.
  static func ymd(_ day: Int64) -> (Int64, Int64, Int64) {
    let s = Web.date(day * 86_400_000)
    let b = Array(s.utf8)
    func n(_ a: Int, _ l: Int) -> Int64 {
      var v: Int64 = 0
      for k in a..<(a + l) { v = v * 10 + Int64(b[k] - 48) }
      return v
    }
    let dash = b.firstIndex(of: 45) ?? 4
    return (n(0, dash), n(dash + 1, 2), n(dash + 4, 2))
  }

  static func daysInMonth(_ y: Int64, _ m: Int64) -> Int64 {
    Web.days(m == 12 ? y + 1 : y, m == 12 ? 1 : m + 1, 1) - Web.days(y, m, 1)
  }

  static let dayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

  struct Rule {
    var freq = ""
    var interval: Int64 = 1
    var until: Stamp?
    var count: Int64 = 0
    var byDay: [(Int64, Int64)] = []  // (ordinal or 0, weekday)
    var byMonthDay: [Int64] = []
    var byMonth: [Int64] = []
  }

  static func rule(_ s: String) -> Rule {
    var r = Rule()
    for part in Array(s.utf8).split(separator: 59) {
      let p = Array(part)
      guard let eq = p.firstIndex(of: 61) else { continue }
      let k = String(decoding: p[..<eq], as: UTF8.self), v = String(decoding: p[(eq + 1)...], as: UTF8.self)
      switch k {
      case "FREQ": r.freq = v
      case "INTERVAL": r.interval = max(1, Int64(Text.int(v) ?? 1))
      case "UNTIL": r.until = stamp(v, [:])
      case "COUNT": r.count = Int64(Text.int(v) ?? 0)
      case "BYDAY":
        for d in commaList(v) {
          let db = Array(d.utf8)
          guard db.count >= 2 else { continue }
          let code = String(decoding: db[(db.count - 2)...], as: UTF8.self)
          guard let wd = dayCodes.firstIndex(of: code) else { continue }
          var ord: Int64 = 0
          let num = Array(db[..<(db.count - 2)])
          if !num.isEmpty {
            let neg = num.first == 45
            let digits = String(decoding: num.drop(while: { $0 == 43 || $0 == 45 }), as: UTF8.self)
            ord = Int64(Text.int(digits) ?? 0) * (neg ? -1 : 1)
          }
          r.byDay.append((ord, Int64(wd)))
        }
      case "BYMONTHDAY":
        for d in commaList(v) {
          let neg = Text.hasPrefix(d, "-")
          if let n = Text.int(neg ? Text.dropPrefix(d, "-") : d) { r.byMonthDay.append(Int64(n) * (neg ? -1 : 1)) }
        }
      case "BYMONTH":
        for d in commaList(v) { if let n = Text.int(d) { r.byMonth.append(Int64(n)) } }
      default: break
      }
    }
    return r
  }

  /// Does the rule produce an occurrence on local day `day` (the series starting on `first`)?
  /// COUNT and UNTIL are checked by the caller.
  static func matches(_ r: Rule, first: Int64, day: Int64) -> Bool {
    guard day >= first else { return false }
    let (fy, fm, fd) = ymd(first)
    let (y, m, d) = ymd(day)
    if !r.byMonth.isEmpty && !r.byMonth.contains(m) { return false }
    switch r.freq {
    case "DAILY":
      if !r.byDay.isEmpty && !r.byDay.contains(where: { $0.1 == weekday(day) }) { return false }
      return (day - first) % r.interval == 0
    case "WEEKLY":
      let days = r.byDay.isEmpty ? [weekday(first)] : r.byDay.map { $0.1 }
      guard days.contains(weekday(day)) else { return false }
      // Weeks start on Monday (WKST default).
      func weekStart(_ x: Int64) -> Int64 { x - (weekday(x) + 6) % 7 }
      return ((weekStart(day) - weekStart(first)) / 7) % r.interval == 0
    case "MONTHLY":
      let months = (y - fy) * 12 + (m - fm)
      guard months % r.interval == 0 else { return false }
      return monthDayMatches(r, y: y, m: m, d: d, day: day, defaultDay: fd)
    case "YEARLY":
      guard (y - fy) % r.interval == 0 else { return false }
      if r.byMonth.isEmpty && m != fm { return false }
      return monthDayMatches(r, y: y, m: m, d: d, day: day, defaultDay: fd)
    default:
      return false
    }
  }

  static func monthDayMatches(_ r: Rule, y: Int64, m: Int64, d: Int64, day: Int64, defaultDay: Int64) -> Bool {
    let dim = daysInMonth(y, m)
    if !r.byMonthDay.isEmpty { return r.byMonthDay.contains { ($0 > 0 ? $0 : dim + 1 + $0) == d } }
    if !r.byDay.isEmpty {
      let wd = weekday(day)
      let nth = (d - 1) / 7 + 1, fromEnd = -((dim - d) / 7 + 1)
      return r.byDay.contains { $0.1 == wd && ($0.0 == 0 || $0.0 == nth || $0.0 == fromEnd) }
    }
    return d == defaultDay
  }

  /// The occurrences of every event that overlap local day `day`, as
  /// `{id, title, start, end, allDay, link, location}` (ms UTC), sorted by start.
  static func eventsOn(_ events: [Event], day: Int64, offsetMinutes: Int64) -> [Value] {
    let off = offsetMinutes
    let dayStart = day * 86_400_000 - off * 60_000, dayEnd = dayStart + 86_400_000
    // Instances moved or cancelled by an override: uid -> their original local starts.
    var overridden: [String: [Int64]] = [:]
    for e in events { if let rid = e.recurrenceId { overridden[e.uid, default: []].append(local(rid, offsetMinutes: off)) } }
    var out: [Value] = []
    for e in events where !e.cancelled {
      guard let s = e.start else { continue }
      let duration: Int64 = e.end.map { utc($0, offsetMinutes: off) - utc(s, offsetMinutes: off) } ?? (s.date ? 86_400_000 : 0)
      var starts: [Int64] = []  // UTC ms of candidate occurrences
      if e.rrule.isEmpty || e.recurrenceId != nil {
        starts = [utc(s, offsetMinutes: off)]
      } else {
        let r = rule(e.rrule)
        let first = floorDay(local(s, offsetMinutes: off))
        let timeOfDay = local(s, offsetMinutes: off) - first * 86_400_000
        // An occurrence that started yesterday can still run into today.
        for cand in [day - 1, day] where matches(r, first: first, day: cand) {
          let startLocal = cand * 86_400_000 + timeOfDay
          if let u = r.until {
            let untilLocal = u.date ? u.wall + 86_400_000 - 1 : local(u, offsetMinutes: off)
            if startLocal > untilLocal { continue }
          }
          if r.count > 0 {
            var n: Int64 = 0
            var k = first
            while k <= cand && n <= r.count && k - first < 20_000 {
              if matches(r, first: first, day: k) { n += 1 }
              k += 1
            }
            if n > r.count { continue }
          }
          if e.exdates.contains(where: { x in x.date ? floorDay(x.wall) == cand : local(x, offsetMinutes: off) == startLocal }) { continue }
          if (overridden[e.uid] ?? []).contains(startLocal) { continue }
          starts.append(startLocal - off * 60_000)
        }
      }
      for st in starts {
        let en = st + max(duration, 0)
        let overlaps = s.date ? (st < dayEnd && max(en, st + 1) > dayStart) : (st < dayEnd && (en > dayStart || (duration == 0 && st >= dayStart)))
        guard overlaps else { continue }
        out.append(["id": .string(e.uid + "@" + String(st)), "title": .string(e.summary.isEmpty ? "(No title)" : e.summary),
                    "start": .int(s.date ? dayStart : st), "end": .int(s.date ? dayEnd : en), "allDay": .bool(s.date),
                    "link": .string(meetingLink(e)), "location": .string(Web.oneLine(e.location, max: 80))])
      }
    }
    return out.sorted { $0.i("start") != $1.i("start") ? $0.i("start") < $1.i("start") : $0.s("title") < $1.s("title") }
  }

  static let meetingHosts = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "whereby.com", "webex.com"]

  /// The first video-call link in the conference field, URL, location or description.
  static func meetingLink(_ e: Event) -> String {
    for field in [e.conference, e.url, e.location, e.description] {
      if let l = firstMeetingURL(field) { return l }
    }
    return ""
  }

  static func firstMeetingURL(_ s: String) -> String? {
    let b = Array(s.utf8)
    var from = 0
    while let at = Web.find(b, Array("https://".utf8), from: from) {
      var end = at
      while end < b.count, b[end] > 32, b[end] != 34, b[end] != 60, b[end] != 62, b[end] != 41, b[end] != 44 { end += 1 }
      let url = String(decoding: b[at..<end], as: UTF8.self)
      let host = URLs.host(url)
      if meetingHosts.contains(where: { host == $0 || hostEnds(host, "." + $0) }) { return url }
      from = end
    }
    return nil
  }

  static func hostEnds(_ host: String, _ suffix: String) -> Bool {
    let h = Array(host.utf8), s = Array(suffix.utf8)
    return h.count >= s.count && Array(h[(h.count - s.count)...]) == s
  }
}
