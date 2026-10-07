#if !hasFeature(Embedded)
  import CordisValue
#endif

/// Google Calendar through the user's own signed-in session in den: today's events for the
/// briefing, a just-in-time meeting reminder with Join, and a countdown on the Calendar favorite.
///
/// - **Connected** when the profile has Google's `SID` sign-in cookie (auto-connect, like Gmail).
/// - **Today's events come from the Calendar page itself.** Whenever a calendar.google.com tab
///   finishes loading (a pinned or favorite Calendar tab is the usual case), and on each briefing
///   refresh while one is live, den reads the event chips Google already rendered for you
///   (`webviews.eval`, in an isolated world; nothing is fetched). They stay in memory for the day,
///   so the Calendar tab may unload afterwards. Google has no documented calendar data a web
///   session can read without OAuth, and its internal endpoints are unverified.
/// - **Fallback**: the calendar's "secret address in iCal format", pasted once in Settings ▸
///   Connections, fetched on each refresh (1 request) and read by `ICS`. Only needed without a tab.
/// - **Reminder**: `ui.card` in the window's top-right corner, `lead` minutes before a timed event
///   (2 by default; Settings), with Join (Meet, Zoom, Teams links), View and Dismiss. One timer to
///   the next moment that matters, only while connected; a minute tick only within the hour before
///   a meeting (the favorite's countdown, "in 8m").
final class CalendarCore {
  static let id = "calendar"
  static let icon = "https://www.google.com/s2/favicons?domain=calendar.google.com&sz=64"
  static let cardId = "calendar.reminder"
  static let countdownMs: Int64 = 60 * 60_000  // the favorite shows "in 8m" within the last hour
  static let lateMs: Int64 = 5 * 60_000  // the card stays up to 5 minutes into a meeting

  let env: PluginEnv
  let requests: Requests
  var registerAttempts = 0
  var refreshing = false
  /// Today's events `{id, title, start, end, allDay, link, location}` (ms, UTC), in memory only.
  var events: [Value] = []
  var eventsDay: Int64 = -1
  var source = ""  // "tab" | "address"
  var lastRead: Int64 = 0
  var tickGen = 0
  var cardEvent = ""
  var dismissed: [String] = []
  var badge = ""
  var lead: Int64 = 2
  var evals: [String: (Value) -> Void] = [:]
  var nextEval = 1
  var settingsObserved = false

  init(env: PluginEnv) {
    self.env = env
    requests = Requests(env: env, prefix: "calendar")
  }

  /// Overridable in storage ns `calendar` key `endpoints` {domain, host, web} (tests, mocks).
  var endpoints: Value { env.call("storage", "get", ["ns": "calendar", "key": "endpoints"]) }
  var domain: String { endpoints.sOpt("domain") ?? "google.com" }
  var host: String { endpoints.sOpt("host") ?? "calendar.google.com" }
  var web: String { endpoints.sOpt("web") ?? "https://calendar.google.com/calendar/r" }
  var address: String {
    var a = env.call("settings", "get", ["id": .string(Self.id), "key": "address"]).string ?? ""
    a = Web.oneLine(a)
    if Text.hasPrefix(Text.lower(a), "webcal://") { a = "https://" + Text.dropPrefix(Text.dropPrefix(a, "webcal://"), "WEBCAL://") }
    return a
  }

  func start() {
    env.on("connections.probe") { [self] v in
      if v.s("id") == Self.id { probe(profile: v.sOpt("profile") ?? "default", auto: v.s("reason") == "register") }
    }
    env.on("connections.changed") { [self] _ in
      if connection() == nil { clear() } else { tick() }
    }
    env.on("feed.refresh") { [self] _ in refresh() }
    env.on("session.cookiesChanged") { [self] v in
      if v.s("domain") == domain { autoProbe(v.sOpt("profile") ?? "default") }
    }
    env.on("webviews.evalResult") { [self] v in
      guard let done = evals.removeValue(forKey: v.s("request")) else { return }
      done(v)
    }
    // A Calendar page that finished loading: read today's events from it.
    env.on("webviews.progress") { [self] v in
      guard !v.b("loading"), connection() != nil, address.isEmpty else { return }
      let w = env.call("webviews", "get", ["id": v["id"]])
      guard isCalendarPage(w.s("url")), env.now() - lastRead > 10_000 else { return }
      read(v.s("id")) { [self] list in
        guard let list else { return }
        setEvents(list, from: "tab")
        emit()
      }
    }
    env.on("ui.action") { [self] v in action(v.s("id"), v.s("action")) }
    env.on("schedule.fire") { [self] v in
      // Wake: timers may have slept through a reminder.
      if v.s("reason") == "wake" { tick() }
    }
    register()
    registerSettings()
    env.call("session", "watchCookies", ["plugin": .string(Self.id), "domain": .string(domain), "profile": "default"])
    autoProbe("default")
  }

  func register() {
    let r = env.call("connections", "register", ["id": .string(Self.id), "title": "Google Calendar", "icon": .string(Self.icon),
                                                  "domain": "calendar.google.com", "signIn": .string(web), "owner": .string(Self.id),
                                                  "unit": "calendars", "order": 40])
    if r.isErr && registerAttempts < 60 {
      registerAttempts += 1
      env.timer(500, false) { [self] in register() }
    }
  }

  /// Settings ▸ Connections ▸ Google Calendar: reminder lead time and the optional address.
  func registerSettings() {
    let r = env.call("settings", "register", [
      "id": .string(Self.id), "section": "connections", "title": "Google Calendar", "icon": .string(Self.icon), "order": 41,
      "controls": [
        ["key": "reminder", "type": "choice", "title": "Meeting reminders",
         "subtitle": "A card in the corner of the window with a Join button", "default": 2,
         "options": [["value": 0, "title": "Off"], ["value": 1, "title": "1 minute before"], ["value": 2, "title": "2 minutes before"],
                     ["value": 5, "title": "5 minutes before"], ["value": 10, "title": "10 minutes before"]]],
        ["key": "address", "type": "text", "title": "Calendar address",
         "subtitle": "Optional. den reads today's events from your Calendar tab. If you'd rather not keep one open, paste the \u{201C}Secret address in iCal format\u{201D} from Google Calendar's settings.",
         "placeholder": "https://calendar.google.com/calendar/ical/…/basic.ics", "default": ""],
      ],
    ])
    guard !r.isErr, !settingsObserved else { return }
    settingsObserved = true
    lead = env.call("settings", "get", ["id": .string(Self.id), "key": "reminder"]).int ?? 2
    env.on("settings.changed") { [self] v in
      guard v.s("id") == Self.id else { return }
      if v.s("key") == "reminder" {
        lead = v["value"].int ?? 2
        tick()
      } else if v.s("key") == "address" {
        events = []
        eventsDay = -1
        // A new address connects on its own; clearing it falls back to the session.
        probe(profile: connection()?.sOpt("profile") ?? "default", auto: false)
        refresh()
      }
    }
  }

  func connection() -> Value? {
    let c = env.call("connections", "get", ["id": .string(Self.id)])
    // Not a bare `nil`: Value is ExpressibleByNilLiteral, so it became Optional(.null) and a
    // disconnected provider still looked connected to `guard let c = connection()`.
    return c.b("connected") ? c : Optional<Value>.none
  }

  // MARK: Connection

  func report(_ connected: Bool, profile: String, auto: Bool) {
    var args: Value = ["id": .string(Self.id), "connected": .bool(connected), "profile": .string(profile), "auto": .bool(auto)]
    if connected { args.put("note", .string(address.isEmpty ? "reads your Calendar tab" : "calendar address")) }
    env.call("connections", "report", args)
  }

  func probe(profile: String, auto: Bool) {
    if !address.isEmpty { return report(true, profile: profile, auto: auto) }
    requests.call("session", "cookies", ["plugin": .string(Self.id), "domain": .string(domain), "profile": .string(profile)]) { [self] r in
      // An address pasted while the cookies were being read still connects it.
      report(!GmailSid.of(r.a("cookies")).isEmpty || !address.isEmpty, profile: profile, auto: auto)
    }
  }

  /// Launch or a Google cookie change: no request to Calendar, only the sign-in cookie.
  func autoProbe(_ profile: String) {
    let c = env.call("connections", "get", ["id": .string(Self.id)])
    if c.b("declined") { return }
    if c.b("connected") {
      guard address.isEmpty, (c.sOpt("profile") ?? "default") == profile else { return }
      requests.call("session", "cookies", ["plugin": .string(Self.id), "domain": .string(domain), "profile": .string(profile)]) { [self] r in
        if GmailSid.of(r.a("cookies")).isEmpty { report(false, profile: profile, auto: true) }
      }
      return
    }
    probe(profile: profile, auto: true)
  }

  // MARK: Reading events

  /// Runs in the Calendar page (isolated world): today's event chips as absolute times.
  static let script = """
    const now = new Date();
    const today = now.toLocaleDateString('en-US', {month: 'long', day: 'numeric', year: 'numeric'});
    const mid = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    const mins = (s) => {
      const m = /(\\d{1,2})(?::(\\d{2}))?\\s*([ap])\\.?m?/i.exec(s) || /(\\d{1,2}):(\\d{2})/.exec(s);
      if (!m) return -1;
      let h = +m[1] % (m[3] ? 12 : 24); if (m[3] && m[3].toLowerCase() === 'p') h += 12;
      return h * 60 + (+m[2] || 0);
    };
    const out = [], seen = new Set();
    for (const el of document.querySelectorAll('[data-eventid]')) {
      const id = el.getAttribute('data-eventid');
      if (!id || seen.has(id)) continue;
      const t = (el.getAttribute('aria-label') || el.textContent || '').replace(/\\s+/g, ' ').trim();
      if (!t.includes(today)) continue;
      seen.add(id);
      const parts = t.split(', ');
      const all = /^all day/i.test(parts[0]);
      const range = all ? null : /^(.+?) to (.+)$/.exec(parts[0]);
      const s = all ? 0 : range ? mins(range[1]) : mins(parts[0]);
      const e = all ? 1440 : range ? mins(range[2]) : -1;
      if (s < 0) continue;
      const link = (/(https:\\/\\/(?:meet\\.google\\.com|[\\w.-]*zoom\\.us|teams\\.microsoft\\.com|teams\\.live\\.com)\\/[^\\s,]+)/.exec(t) || [])[1] || '';
      out.push({id, title: parts[1] || parts[0], start: mid + s * 60000, end: mid + (e < s ? s + 30 : e) * 60000, allDay: all, link});
    }
    return {day: mid, events: out.slice(0, 60)};
    """

  /// Reads today's events from a live Calendar page, or nil.
  func read(_ webview: String, _ done: @escaping ([Value]?) -> Void) {
    let request = "calendar-eval-" + String(nextEval)
    nextEval += 1
    evals[request] = { v in
      guard v.b("ok"), !v["value"].isNull else { return done(nil) }
      done(v["value"].a("events").map { e in
        ["id": e["id"], "title": .string(Web.oneLine(e.s("title"), max: 200)), "start": .int(e.i("start")), "end": .int(e.i("end")),
         "allDay": .bool(e.b("allDay")), "link": e["link"], "location": ""]
      })
    }
    let r = env.call("webviews", "eval", ["id": .string(webview), "plugin": .string(Self.id), "script": .string(Self.script),
                                          "request": .string(request), "timeoutMs": 4000])
    if r.isErr {
      evals[request] = nil
      done(nil)
    }
  }

  /// The first live Calendar tab, if any.
  func liveCalendarTab() -> String? {
    for id in env.call("webviews", "list").array ?? [] {
      let w = env.call("webviews", "get", ["id": id])
      if w.b("live") && isCalendarPage(w.s("url")) { return id.string }
    }
    return nil
  }

  /// calendar.google.com/calendar/… (the app's pages all live under /calendar).
  func isCalendarPage(_ url: String) -> Bool { URLs.host(url) == host && Text.contains(url, "/calendar") }

  /// Local midnight today (ms UTC) and the Mac's UTC offset, from the host clock.
  func today() -> (Int64, Int64) {
    let c = env.call("schedule", "clock", ["ms": .int(env.now())])
    let now = env.now()
    let off = c.i("offsetMinutes")
    let local = now + off * 60_000
    let day = ICS.floorDay(local)
    return (day * 86_400_000 - off * 60_000, off)
  }

  func setEvents(_ list: [Value], from: String) {
    events = list.sorted { $0.i("start") != $1.i("start") ? $0.i("start") < $1.i("start") : $0.s("title") < $1.s("title") }
    eventsDay = today().0
    source = from
    lastRead = env.now()
    tick()
  }

  // MARK: Refresh

  func refresh() {
    guard connection() != nil, !refreshing else { return }
    refreshing = true
    let finish: (String?) -> Void = { [self] error in
      refreshing = false
      emit(error: error)
    }
    let addr = address
    if !addr.isEmpty {
      requests.call("net", "fetch", ["plugin": .string(Self.id), "url": .string(addr), "as": "text", "maxBytes": 20_000_000, "timeoutMs": 30_000]) { [self] r in
        guard r.b("ok"), r.i("status") < 400, Text.contains(r.s("text"), "BEGIN:VCALENDAR") else {
          return finish(r.b("ok") ? "the calendar address returned " + String(r.i("status")) : "couldn't reach the calendar address")
        }
        let (midnight, off) = today()
        let day = ICS.floorDay(midnight + off * 60_000)
        setEvents(ICS.eventsOn(ICS.parse(r.s("text")), day: day, offsetMinutes: off), from: "address")
        finish(nil)
      }
      return
    }
    guard let tab = liveCalendarTab() else {
      // No Calendar tab loaded right now: what it showed earlier today still counts.
      return finish(eventsDay == today().0 ? nil : "open Google Calendar in a tab once today to include your events")
    }
    read(tab) { [self] list in
      if let list { setEvents(list, from: "tab") }
      finish(list == nil && eventsDay != today().0 ? "couldn't read your Calendar tab" : nil)
    }
  }

  /// Feed items for the briefing's Today section (`agenda: true`, never todos).
  func items() -> [Value] {
    let now = env.now()
    guard eventsDay == today().0 else { return [] }
    return events.filter { $0.b("allDay") || $0.i("end") > now }.map { e in
      let start = e.i("start"), end = e.i("end")
      let time = e.b("allDay") ? "All day" : clock(start) + " – " + clock(end)
      let call = Self.callName(e.s("link"))
      var detail = time
      if !call.isEmpty { detail += " · " + call } else if !e.s("location").isEmpty { detail += " · " + e.s("location") }
      let ongoing = !e.b("allDay") && start <= now
      let badge = e.b("allDay") ? "All day" : ongoing ? "Now" : Self.relative(start - now)
      let summary = e.b("allDay") ? "All day today: " + e.s("title") : "At " + clock(start) + ": " + e.s("title") + (call.isEmpty ? "" : " (" + call + ")")
      return ["id": .string("calendar:" + e.s("id")), "source": .string(Self.id), "kind": "event", "agenda": true,
              "title": e["title"], "detail": .string(detail), "url": .string(web + "/day"), "join": e["link"], "ts": .int(start),
              "end": .int(end), "allDay": e["allDay"], "time": .string(e.b("allDay") ? "All day" : clock(start)), "icon": .string(Self.icon),
              "badge": .string(badge), "actor": "", "where": "Calendar", "actionable": false, "summary": .string(summary)]
    }
  }

  func emit(error: String? = nil) {
    var payload: Value = ["source": .string(Self.id), "items": .array(items())]
    if let error { payload.put("error", .string(error)) }
    env.emit("feed.items", payload)
  }

  func clock(_ ms: Int64) -> String { env.call("schedule", "clock", ["ms": .int(ms)]).s("time") }

  static func callName(_ link: String) -> String {
    let h = URLs.host(link)
    if link.isEmpty { return "" }
    if h == "meet.google.com" { return "Google Meet" }
    if h == "zoom.us" || ICS.hostEnds(h, ".zoom.us") { return "Zoom" }
    if Text.hasPrefix(h, "teams.") { return "Microsoft Teams" }
    return "Video call"
  }

  /// "in 5m", "in 1h 20m".
  static func relative(_ ms: Int64) -> String {
    let m = max(1, (ms + 59_999) / 60_000)
    if m < 60 { return "in " + String(m) + "m" }
    return "in " + String(m / 60) + "h" + (m % 60 > 0 ? " " + String(m % 60) + "m" : "")
  }

  // MARK: Reminder and countdown

  /// Re-evaluates the reminder card and the favorite's countdown, then sleeps until the next
  /// moment that changes either (a minute tick only while one is showing).
  func tick() {
    tickGen += 1
    let gen = tickGen
    let now = env.now()
    guard connection() != nil, eventsDay == today().0 else {
      hideCard()
      setBadge("")
      return
    }
    let timed = events.filter { !$0.b("allDay") && $0.i("end") > now }
    // The meeting the card is about: starting within `lead` minutes, or started < 5 min ago.
    var due: Value?
    if lead > 0 {
      due = timed.first(where: { e in
        let s = e.i("start")
        return !dismissed.contains(e.s("id")) && now >= s - lead * 60_000 && now < s + Self.lateMs
      })
    }
    if let due { showCard(due, now: now) } else { hideCard() }
    // The favorite: "in 8m" within the hour before the next meeting, "now" during one.
    var text = ""
    if let next = timed.first(where: { $0.i("start") > now }), next.i("start") - now <= Self.countdownMs {
      text = Self.relative(next.i("start") - now)
    } else if timed.contains(where: { $0.i("start") <= now }) {
      text = "now"
    }
    setBadge(text)
    // Next wake-up.
    var wait: Int64 = -1
    if due != nil || !text.isEmpty {
      wait = 60_000 - now % 60_000
    } else if let next = timed.first(where: { $0.i("start") > now }) {
      let at = min(next.i("start") - Self.countdownMs, next.i("start") - max(lead, 0) * 60_000)
      wait = max(1000, at - now)
    }
    guard wait > 0 else { return }
    env.timer(UInt64(wait), false) { [self] in
      guard gen == tickGen else { return }
      tick()
    }
  }

  func setBadge(_ text: String) {
    guard text != badge else { return }
    badge = text
    env.call("tabs", "badge", ["owner": .string(Self.id), "host": .string(host), "text": .string(text)])
  }

  func showCard(_ e: Value, now: Int64) {
    cardEvent = e.s("id")
    let s = e.i("start")
    let when = s > now ? Self.relative(s - now).capitalizedWord : s + 60_000 > now ? "Now" : "Started " + String((now - s) / 60_000) + "m ago"
    let call = Self.callName(e.s("link"))
    var buttons: [Value] = []
    if !e.s("link").isEmpty {
      buttons.append(["type": "action", "id": "calendar.reminder.join", "icon": "sf:video.fill", "title": "Join", "variant": "pill", "tone": "primary",
                      "tooltip": .string("Join " + call)])
    }
    buttons.append(["type": "action", "id": "calendar.reminder.view", "icon": "sf:calendar", "title": "View", "variant": "pill", "tooltip": "Open Google Calendar"])
    buttons.append(["type": "action", "id": "calendar.reminder.dismiss", "icon": "sf:xmark", "title": "Dismiss", "variant": "pill", "tooltip": "Dismiss this reminder"])
    let tree: Value = ["type": "stack", "id": .string(Self.cardId), "axis": "v", "spacing": 8, "padding": [12, 12, 12, 12], "children": [
      ["type": "stack", "axis": "h", "spacing": 8, "align": "center", "children": [
        ["type": "icon", "spec": .string(e.s("link").isEmpty ? "sf:calendar" : "sf:video.fill"), "size": 15, "tone": "accent"],
        ["type": "label", "text": .string(when), "size": 12, "weight": "semibold", "tone": "accent"],
      ]],
      ["type": "label", "text": e["title"], "size": 14, "weight": "semibold", "tone": "primary", "lines": 2],
      ["type": "label", "text": .string(clock(s) + " – " + clock(e.i("end")) + (call.isEmpty ? "" : " · " + call)), "size": 12, "tone": "secondary"],
      ["type": "stack", "axis": "h", "spacing": 6, "distribute": "equal", "height": 30, "children": .array(buttons)],
    ]]
    env.call("ui", "card", ["id": .string(Self.cardId), "tree": tree, "rect": ["x": 100_000, "y": 0, "w": 0, "h": 0], "place": "below", "width": 280])
  }

  func hideCard() {
    guard !cardEvent.isEmpty else { return }
    cardEvent = ""
    env.call("ui", "card", ["id": .string(Self.cardId), "tree": nil])
  }

  func action(_ id: String, _ act: String) {
    if id == Self.cardId && act == "close" {
      cardEvent = ""  // closed by the host (a sheet or dialog opened); the next tick brings it back
      return
    }
    guard Text.hasPrefix(id, "calendar.reminder."), !cardEvent.isEmpty else { return }
    let e = events.first { $0.s("id") == cardEvent }
    switch Text.dropPrefix(id, "calendar.reminder.") {
    case "join":
      if let l = e?.sOpt("link") { env.call("tabs", "open", ["url": .string(l)]) }
      dismiss()
    case "view":
      env.call("tabs", "open", ["url": .string(web + "/day")])
      dismiss()
    case "dismiss":
      dismiss()
    default: break
    }
  }

  func dismiss() {
    if !cardEvent.isEmpty { dismissed.append(cardEvent) }
    if dismissed.count > 50 { dismissed.removeFirst(dismissed.count - 50) }
    hideCard()
    tick()
  }

  func clear() {
    events = []
    eventsDay = -1
    tickGen += 1
    hideCard()
    setBadge("")
  }
}

/// Google's sign-in cookie (shared with the gmail plugin's logic; each plugin compiles its own copy).
enum GmailSid {
  static func of(_ cookies: [Value]) -> String {
    for n in ["SID", "__Secure-3PSID", "__Secure-1PSID"] {
      if let c = cookies.first(where: { $0.s("name") == n && !$0.s("value").isEmpty }) { return c.s("value") }
    }
    return ""
  }
}

extension String {
  /// "in 5m" -> "In 5m".
  var capitalizedWord: String {
    var b = Array(utf8)
    if let f = b.first, f >= 97 && f <= 122 { b[0] = f - 32 }
    return String(decoding: b, as: UTF8.self)
  }
}
