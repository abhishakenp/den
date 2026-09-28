#if !hasFeature(Embedded)
  import CordisValue
#endif

/// Composes the hover cards from the host's generic nodes (`ui.card`; docs/host-api.md "Generic
/// nodes"). Every string, count and measurement of a card lives here, in the plugin.
///
/// Measurements are Dia's (docs/reference/dia-ui-spec.md): the tab card §2.3 (13 pt text inset,
/// title 13 semibold up to 2 lines, subtitle 13 regular, 6 pt, then equal 34 pt buttons inset 3 pt
/// with 2 pt gaps; 170–200 pt wide), the PR peek §3.2 (about 288 pt wide).
///
/// Provider data is either PR data (`kind: "pr"`, see `GitHub.prData`) or a card fragment: any of
/// `title`, `subtitle`, `accessory`, `badges`, `sections`, `actions`, `footer`, `empty`, `image`,
/// `imageVersion`, `imagePending`, plus `summary {text, style}` (a one-badge digest shown next to
/// the tab in folder cards), or `{error}`.
enum Cards {
  static let tabCard = "previews.tab"
  static let linkCard = "previews.link"
  static let wideWidth: Int64 = 288  // spec §3.2: the PR peek is about 288 pt wide
  static let linkWidth: Int64 = 300  // den: link cards carry an image, a little wider

  // MARK: Node helpers

  static func stack(_ children: [Value], axis: String = "v", spacing: Int64 = 0, padding: Value = .null, distribute: String = "",
                    align: String = "", height: Int64 = 0, id: String = "") -> Value {
    var v: Value = ["type": "stack", "axis": .string(axis), "children": .array(children)]
    if spacing != 0 { v.put("spacing", .int(spacing)) }
    if !padding.isNull { v.put("padding", padding) }
    if !distribute.isEmpty { v.put("distribute", .string(distribute)) }
    if !align.isEmpty { v.put("align", .string(align)) }
    if height > 0 { v.put("height", .int(height)) }
    if !id.isEmpty { v.put("id", .string(id)) }
    return v
  }

  static func pad(_ top: Int64, _ right: Int64, _ bottom: Int64, _ left: Int64) -> Value { [.int(top), .int(right), .int(bottom), .int(left)] }

  static func label(_ text: String, size: Double = 13, weight: String = "", tone: String = "primary", lines: Int64 = 1, lineHeight: Int64 = 0) -> Value {
    var v: Value = ["type": "label", "text": .string(text), "size": .double(size), "tone": .string(tone)]
    if !weight.isEmpty { v.put("weight", .string(weight)) }
    if lines > 1 { v.put("lines", .int(lines)) }
    if lineHeight > 0 { v.put("lineHeight", .int(lineHeight)) }
    return v
  }

  static func runs(_ parts: [Value], size: Double = 13, tone: String = "secondary") -> Value {
    ["type": "label", "runs": .array(parts), "size": .double(size), "tone": .string(tone)]
  }

  static func run(_ text: String, tone: String = "", weight: String = "") -> Value {
    var v: Value = ["text": .string(text)]
    if !tone.isEmpty { v.put("tone", .string(tone)) }
    if !weight.isEmpty { v.put("weight", .string(weight)) }
    return v
  }

  static func spacer(_ h: Int64) -> Value { ["type": "spacer", "height": .int(h)] }

  /// An icon button of the card's action row, or (`pill`) a filled button.
  static func action(_ id: String, icon: String, tooltip: String, shortcut: String = "", enabled: Bool = true, title: String = "",
                     pill: Bool = false, tone: String = "", menu: [Value] = [], value: Value = .null, width: Int64 = 0) -> Value {
    var v: Value = ["type": "action", "id": .string(id), "icon": .string(icon), "tooltip": .string(tooltip)]
    if !shortcut.isEmpty { v.put("shortcut", .string(shortcut)) }
    if !enabled { v.put("enabled", false) }
    if !title.isEmpty { v.put("title", .string(title)) }
    if pill { v.put("variant", "pill") }
    if !tone.isEmpty { v.put("tone", .string(tone)) }
    if !menu.isEmpty { v.put("menu", .array(menu)) }
    if !value.isNull { v.put("value", value) }
    if width > 0 { v.put("width", .int(width)) }
    return v
  }

  /// Dia's action row: equal-width 34 pt buttons, 2 pt apart, inset 3 pt from the card's edges.
  static func actionRow(_ actions: [Value]) -> Value {
    stack(actions, axis: "h", spacing: 2, padding: pad(0, 3, 0, 3), distribute: "equal", height: 34)
  }

  /// Width range for a card with `n` icon actions: Dia's 170–200, widened so each button keeps
  /// at least 30 pt (den shows more verbs than Dia's four).
  static func width(actions n: Int) -> Value {
    let need = Int64(n) * 30 + Int64(max(0, n - 1)) * 2 + 6
    return ["min": 170, "max": .int(max(200, need))]
  }

  static func tone(_ oldStyle: String) -> String {
    switch oldStyle {
    case "success": return "success"
    case "failure": return "danger"
    case "pending", "attention": return "warning"
    case "accent", "merged": return "accent"
    default: return "secondary"
    }
  }

  // MARK: Tab card (spec §2.3, §2.5)

  /// "github.com", or "github.com · #3752" for a pull request or issue (spec §2.3 subtitle).
  static func subtitle(_ url: String) -> String {
    let host = URLs.display(url)
    let seg = Pattern.segments(url)
    if seg.count >= 5, seg[0] == "github.com", seg[3] == "pull" || seg[3] == "issues", Text.int(seg[4]) != nil {
      return URLs.host(url) + " · #" + seg[4]
    }
    return URLs.host(url).isEmpty ? host : URLs.host(url)
  }

  /// The tab's verbs, in Dia's order adapted to den: pin (or reset + unpin) · split · duplicate ·
  /// copy link · mute (when audible) · move to space ▸ · archive/close. Tooltips carry shortcuts;
  /// while the card shows, those shortcuts act on this tab.
  static func tabActions(_ req: PreviewsCore.Request) -> [Value] {
    // A live folder's row is a PR or issue, not a tab: the card shows its data without tab verbs.
    if req.kind == "live" { return [] }
    let p = "previews.tab.act:"
    var out: [Value] = []
    switch req.kind {
    case "pinned":
      out.append(action(p + "reset", icon: "sf:arrow.uturn.backward", tooltip: req.drift ? "Back to Pinned URL" : "At Pinned URL", enabled: req.drift))
      out.append(action(p + "unpin", icon: "sf:pin.slash", tooltip: "Unpin Tab", shortcut: "cmd+d"))
    case "favorite":
      out.append(action(p + "reset", icon: "sf:arrow.uturn.backward", tooltip: req.drift ? "Back to Pinned URL" : "At Pinned URL", enabled: req.drift))
    default:
      out.append(action(p + "pin", icon: "sf:pin", tooltip: "Pin Tab", shortcut: "cmd+d"))
    }
    let splitTip = req.inSplit ? "Add to Split" : req.selected ? "Add Split View" : "Open as Split"
    out.append(action(p + "split", icon: "sf:rectangle.split.2x1", tooltip: splitTip, shortcut: "ctrl+shift+="))
    out.append(action(p + "duplicate", icon: "sf:plus.square.on.square", tooltip: "Duplicate Tab"))
    out.append(action(p + "copy", icon: "sf:link", tooltip: "Copy Link", shortcut: "cmd+shift+c"))
    if req.audio || req.muted {
      out.append(req.muted ? action(p + "unmute", icon: "sf:speaker.wave.2", tooltip: "Unmute Tab")
                           : action(p + "mute", icon: "sf:speaker.slash", tooltip: "Mute Tab"))
    }
    if !req.spaces.isEmpty {
      let items: [Value] = req.spaces.map { ["id": $0["id"], "title": .string($0.s("name")), "icon": "sf:square.grid.2x2"] }
      out.append(action(p + "move", icon: "sf:arrow.right.square", tooltip: "Move to Space", menu: items))
    }
    out.append(req.kind == "today" ? action(p + "close", icon: "sf:archivebox", tooltip: "Archive Tab", shortcut: "cmd+w")
                                   : action(p + "close", icon: "sf:xmark", tooltip: "Close Tab", shortcut: "cmd+w"))
    return out
  }

  /// The split row's card lists both panes (spec §2.5) with its own three verbs.
  static func splitActions(_ req: PreviewsCore.Request) -> [Value] {
    let p = "previews.tab.act:"
    return [
      action(p + "split", icon: "sf:rectangle.split.2x1", tooltip: "Add to Split", shortcut: "ctrl+shift+="),
      action(p + "copy", icon: "sf:link", tooltip: "Copy Link", shortcut: "cmd+shift+c"),
      action(p + "separate", icon: "sf:rectangle.split.2x1.slash", tooltip: "Separate Tabs"),
    ]
  }

  /// The plain tab card: optional compact snapshot, title (2 lines), host, action row.
  static func tab(_ req: PreviewsCore.Request, image: String = "", imageVersion: Int64 = 0, imagePending: Bool = false) -> Value {
    var kids: [Value] = []
    let snapshot = !image.isEmpty || imagePending
    if snapshot {
      var img: Value = ["type": "image", "id": "previews.snapshot", "aspect": 0.5, "placeholder": true]
      if !image.isEmpty {
        img.put("src", .string(image))
        img.put("version", .string(String(imageVersion)))
      }
      kids.append(img)
    }
    var text: [Value] = []
    if let panes = req.panes, !panes.isEmpty {
      for (i, pane) in panes.enumerated() {
        if i > 0 { text.append(spacer(8)) }
        text.append(label(URLs.pageTitle(pane.s("title"), pane.s("url")), weight: "semibold", lines: 2))
        text.append(label(subtitle(pane.s("url")), tone: "secondary", lineHeight: 18))
      }
    } else {
      text.append(label(req.url.isEmpty ? req.title : URLs.pageTitle(req.title, req.url), weight: "semibold", lines: 2))
      text.append(label(req.url.isEmpty ? "" : subtitle(req.url), tone: "secondary", lineHeight: 18))
    }
    kids.append(stack(text, padding: pad(snapshot ? 11 : 15, 14, 0, 13)))
    let acts = req.panes != nil ? splitActions(req) : tabActions(req)
    kids.append(spacer(6))
    kids.append(actionRow(acts))
    return stack(kids, padding: pad(0, 0, 3, 0), id: "previews.tab.root")
  }

  // MARK: PR peek (spec §3.2)

  /// `d` from `GitHub.prData` (or `GitHub.privateData`). `actions`: the tab's action row, or the
  /// link card's.
  static func pr(_ d: Value, title fallback: String, loading: Bool, actions: [Value]) -> Value {
    var kids: [Value] = []
    let title = d.sOpt("title") ?? fallback
    kids.append(label(title.isEmpty ? "Pull request" : title, weight: "semibold", lines: 2))
    kids.append(spacer(7))
    // avatar · author · #N
    var who: [Value] = []
    if !d.s("avatar").isEmpty { who.append(["type": "image", "src": d["avatar"], "width": 16, "height": 16, "radius": 8]) }
    var line = d.s("author")
    let num = d.i("number") > 0 ? "#" + String(d.i("number")) : ""
    if line.isEmpty { line = d.s("repo") }
    if !num.isEmpty { line = line.isEmpty ? num : line + " · " + num }
    who.append(label(line, tone: "secondary"))
    kids.append(stack(who, axis: "h", spacing: 6, align: "center", height: 16))
    if loading {
      kids.append(spacer(10))
      kids.append(label("Loading…", tone: "secondary"))
      kids.append(spacer(10))
      return prFrame(kids, actions)
    }
    if d.b("private") {
      kids.append(spacer(10))
      if d.b("connected") {
        kids.append(label(d.s("state").isEmpty ? "Private repository" : "Private repository · " + d.s("state"), tone: "secondary"))
        kids.append(spacer(4))
        kids.append(label("GitHub doesn't share checks or the diff for private repositories outside the page. Open it to see them.",
                          size: 12, tone: "secondary", lines: 3))
      } else {
        kids.append(label("Private repository", tone: "secondary"))
        kids.append(spacer(4))
        kids.append(label("Connect GitHub to see its state, author and branches here.", size: 12, tone: "secondary", lines: 2))
        kids.append(spacer(10))
        kids.append(stack([action("previews.pr:connect", icon: "https://github.com/favicon.ico", tooltip: "Sign in to GitHub in a new tab",
                                  title: "Connect GitHub", pill: true, tone: "primary")], axis: "h"))
      }
      kids.append(spacer(10))
      return prFrame(kids, actions)
    }
    if d.b("limited") {
      kids.append(spacer(10))
      kids.append(label("GitHub is limiting previews right now. Try again in a few minutes.", size: 12, tone: "secondary", lines: 2))
      kids.append(spacer(10))
      return prFrame(kids, actions)
    }
    kids.append(spacer(6))
    // +adds −dels · N files
    kids.append(runs([run("+" + String(d.i("additions")), tone: "add", weight: "semibold"), run(" "),
                      run("−" + String(d.i("deletions")), tone: "del", weight: "semibold"),
                      run(" · " + PV.plural(Int(d.i("files")), "file", "files"))]))
    let c = d["checks"]
    let total = c.i("total"), failed = c.i("failed"), pending = c.i("pending"), passed = c.i("passed")
    if total > 0 && !d.b("merged") {
      kids.append(spacer(10))
      kids.append(["type": "meter", "height": 6, "total": .int(total), "segments": [
        ["value": .int(passed), "tone": "success"], ["value": .int(pending), "tone": "warning"], ["value": .int(failed), "tone": "danger"],
      ]])
    }
    kids.append(spacer(8))
    let failing = d.a("failing")
    if d.b("merged") {
      kids.append(label("Merged", tone: "secondary"))
    } else if d.s("state") == "closed" {
      kids.append(label("Closed without merging", tone: "secondary"))
    } else if failed > 0 && !failing.isEmpty {
      var notes: [Value] = []
      for (i, f) in failing.prefix(3).enumerated() {
        notes.append(["type": "note", "id": .string("previews.pr:check:" + String(i)), "text": f["name"], "tone": "danger", "value": ["url": f["url"]]])
      }
      kids.append(stack(notes, spacing: 8))
    } else {
      kids.append(label(status(d), tone: "secondary"))
    }
    if d.b("conflicts") {
      kids.append(spacer(8))
      kids.append(["type": "note", "id": "previews.pr:conflicts", "text": .string("Conflicts with " + d.s("base")), "tone": "warning"])
    }
    kids.append(spacer(10))
    var buttons: [Value] = []
    if failed > 0 {
      buttons.append(action("previews.pr:failures", icon: "", tooltip: "Open the failing checks", title: "Show " + PV.plural(Int(failed), "failure", "failures"),
                            pill: true, tone: "destructive"))
    } else if d.b("conflicts") {
      buttons.append(action("previews.pr:conflicts", icon: "", tooltip: "Open the conflict editor", title: "Resolve conflicts",
                            pill: true, tone: "destructive"))
    }
    buttons.append(action("previews.pr:comments", icon: "sf:bubble.left", tooltip: "Open the conversation", title: "Show comments", pill: true, tone: "strong"))
    kids.append(stack(buttons, axis: "h", spacing: 6))
    kids.append(spacer(12))
    return prFrame(kids, actions)
  }

  /// The PR peek's status line (den's copy).
  static func status(_ d: Value) -> String {
    let c = d["checks"]
    let total = c.i("total"), pending = c.i("pending"), queued = c.i("queued"), failed = c.i("failed")
    if d.b("draft") && total == 0 { return "Draft" }
    if total == 0 { return d.b("draft") ? "Draft · no checks" : "No checks" }
    if failed > 0 { return PV.plural(Int(failed), "check is failing", "checks are failing") }
    if pending == 0 && queued == 0 { return "All checks passed" }
    if pending == 0 { return "Checks are queued" }
    return String(pending + queued) + " of " + String(total) + " checks still running"
  }

  static func prFrame(_ kids: [Value], _ actions: [Value]) -> Value {
    var all: [Value] = [stack(kids, padding: pad(13, 12, 0, 12))]
    if !actions.isEmpty { all.append(actionRow(actions)) }
    return stack(all, padding: pad(0, 0, actions.isEmpty ? 0 : 3, 0), id: "previews.pr.root")
  }

  // MARK: Fragment cards (Calendar, Gmail, Slack, issues, folders)

  static func fragment(_ req: PreviewsCore.Request, _ data: Value, loading: Bool, actions: [Value]) -> Value {
    var head: [Value] = []
    let title = data.sOpt("title") ?? (req.url.isEmpty ? req.title : URLs.pageTitle(req.title, req.url))
    var sub = data.sOpt("subtitle") ?? (req.url.isEmpty ? "" : subtitle(req.url))
    if let a = data.sOpt("accessory"), !a.isEmpty { sub = sub.isEmpty ? a : sub + " · " + a }
    head.append(label(title, weight: "semibold", lines: 2))
    head.append(label(sub, tone: "secondary", lineHeight: 18))
    var kids: [Value] = [stack(head, padding: pad(15, 14, 0, 13))]
    var body: [Value] = []
    let badges = data.a("badges")
    if !badges.isEmpty {
      body.append(stack(badges.prefix(4).map { b in
        var v: Value = ["type": "badge", "text": b["text"], "tone": .string(tone(b.s("style")))]
        if !b.s("icon").isEmpty { v.put("icon", b["icon"]) }
        return v
      }, axis: "h", spacing: 6, align: "start", height: 20))
    }
    if data.isErr {
      body.append(label(friendly(data.s("error")), size: 12, tone: "secondary", lines: 3))
    } else if loading {
      body.append(label("Loading…", size: 12, tone: "secondary"))
    }
    var n = 0
    for s in data.a("sections") {
      var rows: [Value] = []
      if !s.s("title").isEmpty { rows.append(label(s.s("title"), size: 11, weight: "semibold", tone: "secondary")) }
      for r in s.a("rows") {
        var item: Value = ["type": "item", "title": r["title"]]
        for k in ["subtitle", "icon", "accessory"] where !r[k].isNull { item.put(k, r[k]) }
        if !r.s("status").isEmpty { item.put("tone", .string(tone(r.s("status")))) }
        if !r.s("url").isEmpty {
          item.put("id", .string("previews.open:" + String(n)))
          var v: Value = ["url": r["url"]]
          if !r.s("tab").isEmpty { v.put("tab", r["tab"]) }  // a folder card's row: switch to that tab
          item.put("value", v)
          n += 1
        }
        rows.append(item)
      }
      body.append(stack(rows, spacing: 2))
    }
    if let e = data.sOpt("empty"), !e.isEmpty { body.append(label(e, size: 12, tone: "secondary", lines: 3)) }
    if !data.s("image").isEmpty || data.b("imagePending") {
      var img: Value = ["type": "image", "aspect": 0.625, "radius": 8, "placeholder": true]
      if !data.s("image").isEmpty { img.put("src", data["image"]); img.put("version", .string(String(data.i("imageVersion")))) }
      body.append(img)
    }
    let acts = data.a("actions")
    if !acts.isEmpty {
      body.append(stack(acts.enumerated().map { (i, a) in
        action("previews.open:a" + String(i), icon: a.s("icon"), tooltip: a.s("title"), title: a.s("title"), pill: true,
               tone: a.s("style") == "primary" ? "primary" : "", value: ["url": a["url"], "action": a["id"]])
      }, axis: "h", spacing: 6))
    }
    if let f = data.sOpt("footer"), !f.isEmpty { body.append(label(f, size: 11, tone: "secondary")) }
    if !body.isEmpty { kids.append(stack(body, spacing: 10, padding: pad(10, 8, 0, 8))) }
    kids.append(spacer(actions.isEmpty ? 12 : 8))
    if !actions.isEmpty { kids.append(actionRow(actions)) }
    return stack(kids, padding: pad(0, 0, actions.isEmpty ? 0 : 3, 0), id: "previews.fragment.root")
  }

  static func friendly(_ error: String) -> String {
    if Text.contains(error, "permission") { return "den can't read this site yet." }
    if Text.contains(error, "no service") || Text.contains(error, "unknown service") { return "Previews for this site need a newer den." }
    return "Couldn't load a preview right now."
  }

  /// A folder: its tabs, each with the cached digest from its provider when there is one
  /// (never a request: hovering a folder costs nothing).
  static func folder(_ req: PreviewsCore.Request, cached: (String) -> Value?) -> Value {
    var rows: [Value] = []
    for item in req.items.prefix(6) {
      let url = item.s("url")
      // A row with a url is clickable: it switches to that tab (PreviewsCore.action).
      var row: Value = ["id": item["id"], "title": .string(URLs.pageTitle(item.s("title"), url)), "subtitle": .string(URLs.display(url)),
                        "icon": .string(item.sOpt("icon") ?? "sf:globe"), "url": .string(url), "tab": item["id"]]
      if let d = cached(url), !d["summary"].isNull {
        row.put("accessory", d["summary"]["text"])
        row.put("status", d["summary"]["style"])
      }
      rows.append(row)
    }
    let n = req.items.count
    var data: Value = [
      "title": .string(req.title), "subtitle": .string(n == 1 ? "1 tab" : String(n) + " tabs"),
      "sections": .array(rows.isEmpty ? [] : [["rows": .array(rows)]]),
    ]
    if n > 6 { data.put("footer", .string("and " + String(n - 6) + " more")) }
    // Dia 1.28's flyout: "+ New Tab" at the end of the group.
    data.put("actions", [["id": "newTab", "title": "New Tab", "icon": "sf:plus", "style": "secondary"]])
    if n == 0 { data.put("empty", "This folder is empty.") }
    return fragment(req, data, loading: false, actions: [])
  }

  // MARK: Link card (⇧-hover)

  static func linkActions() -> [Value] {
    let p = "previews.link.act:"
    return [
      action(p + "peek", icon: "sf:eye", tooltip: "Open in Peek  ⇧-click"),
      action(p + "split", icon: "sf:rectangle.split.2x1", tooltip: "Open as Split", shortcut: "ctrl+shift+="),
      action(p + "copy", icon: "sf:link", tooltip: "Copy Link", shortcut: "cmd+shift+c"),
    ]
  }

  /// OpenGraph data (`OpenGraph.parse`): image, site, title, description.
  static func link(url: String, og: Value, loading: Bool) -> Value {
    var kids: [Value] = []
    if !og.s("image").isEmpty {
      kids.append(["type": "image", "id": "previews.link.image", "src": og["image"], "aspect": 0.5, "placeholder": true])
    }
    var text: [Value] = []
    var site = og.sOpt("site") ?? URLs.host(url)
    if site.isEmpty { site = URLs.display(url) }
    let icon = og.s("icon")
    text.append(stack([["type": "icon", "spec": .string(icon.isEmpty ? URLs.favicon(url) : icon), "size": 14, "letter": .string(site)],
                       label(site, size: 12, tone: "secondary")], axis: "h", spacing: 6, align: "center", height: 16))
    text.append(spacer(4))
    let title = og.sOpt("title") ?? URLs.display(url)
    text.append(label(title, weight: "semibold", lines: 2))
    if loading {
      text.append(spacer(2))
      text.append(label("Loading preview…", size: 12, tone: "secondary"))
    } else if let d = og.sOpt("description"), !d.isEmpty {
      text.append(spacer(2))
      text.append(label(d, size: 12, tone: "secondary", lines: 3))
    }
    kids.append(stack(text, padding: pad(12, 14, 0, 13)))
    kids.append(spacer(8))
    kids.append(actionRow(linkActions()))
    return stack(kids, padding: pad(0, 0, 3, 0), id: "previews.link.root")
  }

  // MARK: Fragment helpers (providers)

  static func badge(_ text: String, _ style: String, _ icon: String = "") -> Value {
    var b: Value = ["text": .string(text), "style": .string(style)]
    if !icon.isEmpty { b.put("icon", .string(icon)) }
    return b
  }

  static func row(_ title: String, subtitle: String = "", icon: String = "", status: String = "", accessory: String = "", url: String = "", id: String = "") -> Value {
    var r: Value = ["title": .string(title)]
    if !subtitle.isEmpty { r.put("subtitle", .string(subtitle)) }
    if !icon.isEmpty { r.put("icon", .string(icon)) }
    if !status.isEmpty { r.put("status", .string(status)) }
    if !accessory.isEmpty { r.put("accessory", .string(accessory)) }
    if !url.isEmpty { r.put("url", .string(url)) }
    r.put("id", .string(id.isEmpty ? title : id))
    return r
  }

  static func section(_ title: String, _ rows: [Value]) -> Value {
    var s: Value = ["rows": .array(rows)]
    if !title.isEmpty { s.put("title", .string(title)) }
    return s
  }
}

/// Plain-string helpers (no Foundation in plugins).
enum PV {
  static func plural(_ n: Int, _ one: String, _ many: String) -> String { String(n) + " " + (n == 1 ? one : many) }

  /// "2026-09-27T10:04:05Z" (or with a ±hh:mm offset) -> ms since 1970; 0 if unparsable.
  static func isoMs(_ s: String) -> Int64 {
    let b = Array(s.utf8)
    func num(_ from: Int, _ len: Int) -> Int64? {
      guard from + len <= b.count else { return nil }
      var n: Int64 = 0
      for i in from..<(from + len) {
        guard b[i] >= 48 && b[i] <= 57 else { return nil }
        n = n * 10 + Int64(b[i] - 48)
      }
      return n
    }
    guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2), let se = num(17, 2) else { return 0 }
    var i = 19
    if i < b.count, b[i] == 46 { i += 1; while i < b.count, b[i] >= 48 && b[i] <= 57 { i += 1 } }
    var offset: Int64 = 0
    if i < b.count, b[i] == 43 || b[i] == 45, let oh = num(i + 1, 2) {
      let om = num(i + 4, 2) ?? 0
      offset = (oh * 60 + om) * 60_000 * (b[i] == 45 ? -1 : 1)
    }
    let yy = mo <= 2 ? y - 1 : y
    let era = (yy >= 0 ? yy : yy - 399) / 400
    let yoe = yy - era * 400
    let doy = (153 * (mo > 2 ? mo - 3 : mo + 9) + 2) / 5 + d - 1
    let days = era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468
    return (days * 86_400 + h * 3600 + mi * 60 + se) * 1000 - offset
  }

  static func ago(_ ms: Int64, now: Int64) -> String {
    guard ms > 0 else { return "" }
    let s = max(0, (now - ms) / 1000)
    if s < 60 { return "now" }
    if s < 3600 { return String(s / 60) + "m" }
    if s < 86_400 { return String(s / 3600) + "h" }
    return String(s / 86_400) + "d"
  }

  static func encode(_ s: String) -> String {
    let hex: [UInt8] = Array("0123456789ABCDEF".utf8)
    var out: [UInt8] = []
    for c in s.utf8 {
      if (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 45 || c == 46 || c == 95 || c == 126 {
        out.append(c)
      } else {
        out.append(37)
        out.append(hex[Int(c >> 4)])
        out.append(hex[Int(c & 15)])
      }
    }
    return String(decoding: out, as: UTF8.self)
  }

  /// True when `s` is safe to splice into a script as a path segment.
  static func safeSegment(_ s: String) -> Bool {
    guard !s.isEmpty else { return false }
    for c in s.utf8 {
      let ok = (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 45 || c == 46 || c == 95
      if !ok { return false }
    }
    return true
  }

  // MARK: Tiny XML reader (Gmail's Atom feed)

  static func between(_ s: [UInt8], _ open: String, _ close: String, from: Int = 0) -> (String, Int)? {
    let o = Array(open.utf8), c = Array(close.utf8)
    guard let a = find(s, o, from: from) else { return nil }
    let start = a + o.count
    guard let b = find(s, c, from: start) else { return nil }
    return (String(decoding: s[start..<b], as: UTF8.self), b + c.count)
  }

  static func find(_ hay: [UInt8], _ needle: [UInt8], from: Int = 0) -> Int? {
    guard !needle.isEmpty, hay.count >= needle.count, from <= hay.count - needle.count else { return nil }
    var i = from
    while i <= hay.count - needle.count {
      if hay[i] == needle[0] {
        var ok = true
        for j in 1..<needle.count where hay[i + j] != needle[j] {
          ok = false
          break
        }
        if ok { return i }
      }
      i += 1
    }
    return nil
  }

  static func unescape(_ s: String) -> String {
    var out = s
    for (e, r) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")] {
      out = replace(out, e, r)
    }
    return out
  }

  static func replace(_ s: String, _ a: String, _ b: String) -> String {
    let hay = Array(s.utf8), needle = Array(a.utf8)
    guard !needle.isEmpty, hay.count >= needle.count else { return s }
    var out: [UInt8] = []
    var i = 0
    while i < hay.count {
      if i + needle.count <= hay.count {
        var match = true
        for j in 0..<needle.count where hay[i + j] != needle[j] {
          match = false
          break
        }
        if match {
          out += Array(b.utf8)
          i += needle.count
          continue
        }
      }
      out.append(hay[i])
      i += 1
    }
    return String(decoding: out, as: UTF8.self)
  }
}
