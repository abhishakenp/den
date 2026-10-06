// The `media` plugin: the now-playing dock at the bottom of the sidebar (Arc's audio controller),
// and den's entry in Control Center's Now Playing and the media keys. See docs/plugin-services.md.

#if !hasFeature(Embedded)
  import CordisValue
#endif

/// Every tab whose page played something with sound, most recent first, from the host's
/// `webviews.nowPlaying` events (the page's own media events and Media Session metadata; no
/// polling). The dock shows them in the `sidebar.dock` slot: artwork, title, artist, and
/// previous / play-pause / next / mute / stop, plus the tab's volume and playback speed (the
/// host's `webviews.setVolume` / `setRate`, kept across discards); a click on the artwork or
/// title goes to the tab.
/// The tab on screen isn't listed (its controls are right there), like Arc; a tab whose video is
/// in picture in picture is, with a button that brings it back (den's controls around the system
/// PiP window, which den never draws over). With more than one, only the newest shows until
/// "N more" expands the stack.
///
/// The newest one is den's "now playing" (`nowplaying.set`): Control Center and the media keys
/// drive it (`nowplaying.command`), and so do ⌃⌘P, ⌃⌘← and ⌃⌘→. ⌥⌘P (View ▸ Picture in
/// Picture, the command bar's "Picture in Picture") puts the tab on screen's video, else the
/// newest one's, in WebKit's picture in picture, or takes it out (host `media.toggle`).
///
/// Cost: nothing is rendered or registered with the system until something plays; the slot is
/// cleared and `nowplaying.clear` called when the last one stops.
final class MediaCore {
  struct Entry {
    var id: String
    var now: Value
    var muted: Bool
    var icon: String
    var paused: Bool { now.b("paused") }
    var title: String { now.s("title") }
    var artist: String { now.s("artist") }
    var acts: [String] { now.a("acts").compactMap { $0.string } }
    var hasNext: Bool { acts.contains("nexttrack") }
    /// The now-playing element's volume and playback speed, as the page reports them.
    var vol: Double { now["vol"].double ?? 1 }
    var rate: Double { now["rate"].double ?? 1 }
  }

  static let slot = "sidebar.dock"
  static let toggleChord = "ctrl+cmd+p"
  static let nextChord = "ctrl+cmd+right"
  static let previousChord = "ctrl+cmd+left"
  static let pipChord = "cmd+opt+p"

  let env: PluginEnv
  var entries: [String: Entry] = [:]
  /// Most recent first: new entries, and entries that start playing again, move to the front.
  var order: [String] = []
  var selected: String?
  /// Tabs whose video is in picture in picture.
  var pip: [String] = []
  var expanded = false
  var rendered = false
  var published: Value = .null

  init(env: PluginEnv) { self.env = env }

  func start() {
    env.on("webviews.nowPlaying") { [self] v in nowPlaying(v.s("id"), v["now"], muted: v.b("muted")) }
    env.on("webviews.muted") { [self] v in
      guard entries[v.s("id")] != nil else { return }
      entries[v.s("id")]?.muted = v.b("muted")
      render()
    }
    env.on("webviews.volume") { [self] v in
      guard let e = entries[v.s("id")], !e.now.isNull else { return }
      var n = e.now
      n.put("vol", .double(v["volume"].double ?? 0))
      entries[v.s("id")]?.now = n
      render()
    }
    env.on("webviews.rate") { [self] v in
      guard let e = entries[v.s("id")], !e.now.isNull else { return }
      var n = e.now
      n.put("rate", .double(v["rate"].double ?? 1))
      entries[v.s("id")]?.now = n
      render()
    }
    env.on("webviews.closed") { [self] v in remove(v.s("id")) }
    env.on("webviews.favicon") { [self] v in
      guard entries[v.s("id")] != nil, let u = v.sOpt("url") else { return }
      entries[v.s("id")]?.icon = u
      render()
    }
    env.on("tabs.selected") { [self] v in
      selected = v.sOpt("id")
      render()
    }
    env.on("media.pip") { [self] v in
      let id = v.s("webview")
      pip.removeAll { $0 == id }
      if v.b("open") { pip.append(id) }
      render()
    }
    env.on("media.key.pip") { [self] _ in togglePip() }
    env.on("ui.action") { [self] v in action(v.s("id"), v.s("action"), v["value"]) }
    env.on("nowplaying.command") { [self] v in if let id = order.first { control(id, v.s("command")) } }
    env.on("media.key.toggle") { [self] _ in if let id = order.first { control(id, "toggle") } }
    env.on("media.key.next") { [self] _ in if let id = order.first { control(id, "next") } }
    env.on("media.key.previous") { [self] _ in if let id = order.first { control(id, "previous") } }
    selected = env.call("tabs", "selected")["id"].string
    for (chord, event, title) in [(Self.toggleChord, "media.key.toggle", "Play or Pause Media"), (Self.nextChord, "media.key.next", "Next Track"),
                                  (Self.previousChord, "media.key.previous", "Previous Track"), (Self.pipChord, "media.key.pip", "Picture in Picture")] {
      env.call("keys", "bind", ["chord": .string(chord), "event": .string(event), "title": .string(title), "menu": "View"])
    }
  }

  func stop() {
    for c in [Self.toggleChord, Self.nextChord, Self.previousChord, Self.pipChord] { env.call("keys", "unbind", ["chord": .string(c)]) }
    if rendered { env.call("ui", "set", ["slot": .string(Self.slot), "tree": .null]) }
    if !published.isNull { env.call("nowplaying", "clear") }
  }

  // MARK: State

  func nowPlaying(_ id: String, _ now: Value, muted: Bool) {
    guard !id.isEmpty else { return }
    if now.isNull { remove(id); return }
    let old = entries[id]
    if old == nil {
      let page = env.call("webviews", "get", ["id": .string(id)])
      entries[id] = Entry(id: id, now: now, muted: muted, icon: URLs.icon(page.sOpt("favicon"), page.s("url")))
    } else {
      entries[id]?.now = now
      entries[id]?.muted = muted
    }
    // Newly listed, or playing again: to the front.
    if old == nil || (old!.paused && !now.b("paused")) {
      order.removeAll { $0 == id }
      order.insert(id, at: 0)
    }
    render()
  }

  func remove(_ id: String) {
    guard entries.removeValue(forKey: id) != nil else { return }
    order.removeAll { $0 == id }
    render()
  }

  /// The entries the dock lists: everything except the tab on screen.
  var listed: [Entry] { order.compactMap { entries[$0] }.filter { $0.id != selected } }

  /// ⌥⌘P: out of picture in picture when a video is in it, else in, the tab on screen first and
  /// the newest playing one next (the host picks; WebKit shows it in the system PiP window).
  func togglePip() {
    var args: Value = [:]
    if let id = order.first { args.put("fallback", .string(id)) }
    env.call("media", "toggle", args)
  }

  // MARK: Actions

  func control(_ id: String, _ command: String, _ value: Value = .null) {
    guard let e = entries[id] else { return }
    switch command {
    case "mute": env.call("webviews", "setMuted", ["id": .string(id), "muted": .bool(!e.muted)])
    case "jump": env.call("tabs", "select", ["id": .string(id)])
    case "pip": env.call("media", pip.contains(id) ? "exit" : "enter", ["webview": .string(id)])
    case "next": if e.hasNext { env.call("webviews", "mediaControl", ["id": .string(id), "action": "next"]) }
    case "play", "pause", "toggle", "previous", "stop":
      env.call("webviews", "mediaControl", ["id": .string(id), "action": .string(command)])
    case "voldown", "volup":
      // One-hundredth steps, so any page value lands on round numbers; the host keeps it across
      // discards and the page reports the change back through nowPlaying.
      let v = min(1, max(0, ((e.vol * 100).rounded() + (command == "volup" ? 10 : -10)) / 100))
      var n = e.now
      n.put("vol", .double(v))
      entries[id]?.now = n
      render()
      env.call("webviews", "setVolume", ["id": .string(id), "volume": .double(v)])
    case "rate":
      guard let r = Double(value.string ?? ""), r >= 0.25, r <= 4 else { break }
      var n = e.now
      n.put("rate", .double(r))
      entries[id]?.now = n
      render()
      env.call("webviews", "setRate", ["id": .string(id), "rate": .double(r)])
    default: break
    }
  }

  /// Node ids: `media.<command>:<webview>` for the buttons, `media.jump:<webview>` for the
  /// artwork and title, `media.more` for the expand / collapse row. The speed button's menu
  /// items arrive as `action: "menu"` with the rate as the value.
  func action(_ nodeId: String, _ action: String, _ value: Value) {
    guard Text.hasPrefix(nodeId, "media."), action == "click" || action == "menu" else { return }
    if nodeId == "media.more" {
      expanded = !expanded
      render()
      return
    }
    let rest = Array(Text.dropPrefix(nodeId, "media.").utf8)
    guard let colon = rest.firstIndex(of: 58) else { return }  // ":"
    let command = String(decoding: rest[..<colon], as: UTF8.self)
    let id = String(decoding: rest[(colon + 1)...], as: UTF8.self)
    control(id, command, action == "menu" ? value : .null)
  }

  // MARK: Rendering

  func render() {
    publish()
    let items = listed
    if items.isEmpty {
      if rendered { env.call("ui", "set", ["slot": .string(Self.slot), "tree": .null]) }
      rendered = false
      return
    }
    if items.count < 2 { expanded = false }
    var kids: [Value] = []
    for (i, e) in items.enumerated() where expanded || i == 0 { kids.append(card(e, first: i == 0)) }
    if items.count > 1 {
      let more = items.count - 1
      let text = expanded ? "Show less" : (String(more) + " more playing")
      kids.append(["type": "stack", "id": "media.more", "axis": "h", "clickable": true, "radius": 6, "padding": [3, 8, 3, 8], "align": "center",
                   "children": [["type": "label", "text": .string(text), "size": 11.5, "weight": "medium", "tone": "secondary", "align": "center"]]])
    }
    env.call("ui", "set", ["slot": .string(Self.slot), "tree": ["type": "stack", "id": "media.dock", "axis": "v", "spacing": 4, "children": .array(kids)]])
    rendered = true
  }

  /// One playing tab: artwork (or the site's icon), title and artist over its controls. The
  /// newest one's buttons carry the media shortcuts.
  func card(_ e: Entry, first: Bool) -> Value {
    let id = e.id
    let art = e.now.s("art")
    let pic: Value = art.isEmpty
      ? ["type": "icon", "spec": .string(e.icon), "size": 32, "letter": .string(e.title)]
      : ["type": "image", "src": .string(art), "width": 36, "height": 36, "radius": 6]
    var text: [Value] = [["type": "label", "text": .string(e.title.isEmpty ? "Playing" : e.title), "size": 12.5, "weight": "medium", "tone": "primary"]]
    if !e.artist.isEmpty { text.append(["type": "label", "text": .string(e.artist), "size": 11, "tone": "secondary"]) }
    let head: Value = ["type": "stack", "id": .string("media.jump:" + id), "axis": "h", "spacing": 8, "clickable": true, "radius": 6, "padding": 2,
                       "value": .string(id), "children": [pic, ["type": "stack", "axis": "v", "spacing": 1, "children": .array(text)]]]
    func button(_ command: String, _ icon: String, _ tip: String, _ chord: String, enabled: Bool = true) -> Value {
      var b: Value = ["type": "action", "id": .string("media." + command + ":" + id), "icon": .string(icon), "tooltip": .string(tip),
                      "height": 28, "iconSize": 13, "enabled": .bool(enabled)]
      if first && !chord.isEmpty { b.put("shortcut", .string(chord)) }
      return b
    }
    var buttons: [Value] = [
      button("previous", "sf:backward.fill", "Previous Track", Self.previousChord),
      button("toggle", e.paused ? "sf:play.fill" : "sf:pause.fill", e.paused ? "Play" : "Pause", Self.toggleChord),
      button("next", "sf:forward.fill", "Next Track", Self.nextChord, enabled: e.hasNext),
      button("mute", e.muted ? "sf:speaker.slash.fill" : "sf:speaker.wave.2.fill", e.muted ? "Unmute Tab" : "Mute Tab", ""),
    ]
    if e.now.b("video") {
      let inPip = pip.contains(id)
      buttons.append(button("pip", inPip ? "sf:pip.exit" : "sf:pip.enter", inPip ? "Exit Picture in Picture" : "Picture in Picture", ""))
    }
    buttons.append(button("stop", "sf:xmark", "Stop", ""))
    let controls: Value = ["type": "stack", "axis": "h", "distribute": "equal", "spacing": 2, "children": .array(buttons)]

    return ["type": "stack", "id": .string("media.card:" + id), "axis": "v", "fill": "panel", "radius": 10, "padding": [6, 6, 2, 6], "spacing": 2,
            "children": [head, controls, playback(e)]]
  }

  /// The tab's volume and playback speed: step buttons around a volume meter and its percent,
  /// and a speed pill whose menu picks the rate. Both go to the host (`webviews.setVolume` /
  /// `setRate`), which keeps them across discards; the page reports the new values back.
  func playback(_ e: Entry) -> Value {
    let vol = min(1, max(0, e.vol))
    func step(_ command: String, _ icon: String, _ tip: String) -> Value {
      ["type": "action", "id": .string("media." + command + ":" + e.id), "icon": .string(icon), "tooltip": .string(tip),
       "height": 22, "iconSize": 10]
    }
    let speed: Value = ["type": "action", "id": .string("media.rate:" + e.id), "title": .string(Self.rateText(e.rate)), "variant": "pill",
                        "tooltip": .string("Playback Speed"), "height": 22,
                        "menu": .array(Self.rates.map {
                          ["id": .string(Self.rateId($0)), "title": .string(Self.rateText($0)), "checked": .bool(abs(e.rate - $0) < 0.01)]
                        })]
    return ["type": "stack", "axis": "h", "spacing": 4, "align": "center", "children": [
      step("voldown", "sf:speaker.minus.fill", "Quieter"),
      ["type": "meter", "segments": [["value": .double(vol), "tone": "accent"]], "total": 1, "height": 4],
      step("volup", "sf:speaker.plus.fill", "Louder"),
      ["type": "label", "text": .string("\(Int((vol * 100).rounded()))%"), "size": 10, "tone": "secondary", "align": "center", "width": 26],
      speed,
    ]]
  }

  /// The dock's playback speeds, and how one is shown ("1×", "1.25×") and identified in the
  /// menu ("1", "1.25": what `control` parses back).
  static let rates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]
  static func rateText(_ r: Double) -> String { r == r.rounded() ? "\(Int(r))×" : "\(r)×" }
  static func rateId(_ r: Double) -> String { r == r.rounded() ? String(Int(r)) : String(r) }

  /// Control Center's Now Playing follows the newest entry (listed or not: the tab on screen
  /// is still what the media keys should drive).
  func publish() {
    guard let id = order.first, let e = entries[id] else {
      if !published.isNull { env.call("nowplaying", "clear") }
      published = .null
      return
    }
    var commands: [Value] = ["play", "pause", "toggle", "previous", "stop"]
    if e.hasNext { commands.append("next") }
    let info: Value = ["title": .string(e.title), "artist": .string(e.artist), "album": e.now["album"], "artwork": e.now["art"],
                       "duration": e.now["dur"], "playing": .bool(!e.paused), "commands": .array(commands)]
    guard info != published else { return }
    published = info
    env.call("nowplaying", "set", info)
  }
}
