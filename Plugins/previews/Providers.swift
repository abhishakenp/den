#if !hasFeature(Embedded)
  import CordisValue
#endif

/// The built-in preview providers. Each one reads the site the way the integrations plugins do:
/// public APIs where they exist, otherwise the user's own den session for that site (`net.fetch
/// {session: true}`, `session.eval`) or the loaded tab itself (`webviews.eval`). Permissions are
/// declared in permissions.json. Endpoints can be pointed elsewhere for tests and mocks through
/// storage ns `previews`, key `endpoints` {githubApi, githubWeb, gmail, slackApi, slackOrigin}.
enum Builtins {
  static func register(_ core: PreviewsCore) {
    func add(_ id: String, _ patterns: [String], ttl: Int64, _ fetch: @escaping (PreviewsCore.Request, @escaping (Value) -> Void) -> Void) {
      for p in patterns { core.providers.append(PreviewsCore.Provider(id: id, pattern: p, owner: nil, ttlMs: ttl, fetch: fetch)) }
    }
    add("github.pr", ["github.com/*/*/pull/*"], ttl: 60_000) { r, d in GitHub.pr(core, r, d) }
    add("github.issue", ["github.com/*/*/issues/*"], ttl: 120_000) { r, d in GitHub.issue(core, r, d) }
    add("calendar", ["calendar.google.com/*"], ttl: 60_000) { r, d in Calendar.fetch(core, r, d) }
    add("gmail", ["mail.google.com/*"], ttl: 60_000) { r, d in Gmail.fetch(core, r, d) }
    add("slack", ["app.slack.com/*", "*.slack.com/*"], ttl: 30_000) { r, d in Slack.fetch(core, r, d) }
    // (The closures keep `core` alive; it lives as long as the plugin anyway.)
    // Every other page: a snapshot of the tab (PreviewsCore.showPage), no provider fetch.
    core.providers.append(PreviewsCore.Provider(id: "page", pattern: "*", owner: nil, ttlMs: 0, fetch: nil))
  }

  static func endpoint(_ core: PreviewsCore, _ key: String, _ fallback: String) -> String {
    core.env.call("storage", "get", ["ns": "previews", "key": "endpoints"]).sOpt(key) ?? fallback
  }
}

// MARK: - GitHub

enum GitHub {
  static let headers: Value = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]

  /// ("owner/repo", number) from a github.com pull or issue URL.
  static func parse(_ url: String) -> (String, Int)? {
    let seg = Pattern.segments(url)
    guard seg.count >= 5, let n = Text.int(seg[4]), PV.safeSegment(seg[1]), PV.safeSegment(seg[2]) else { return nil }
    return (seg[1] + "/" + seg[2], n)
  }

  static func ok(_ r: Value) -> Bool { r.b("ok") && r.i("status") < 400 && !r["json"].isNull }

  /// PR: `pulls/<n>`, then its head commit's check runs and legacy statuses, in parallel (public
  /// repositories need no sign-in: GitHub's public API). A private repository (404) or a rate
  /// limit falls back to the github.com page the user is signed in to, if they are.
  static func pr(_ core: PreviewsCore, _ req: PreviewsCore.Request, _ done: @escaping (Value) -> Void) {
    guard let (repo, n) = parse(req.url) else { return done(.err("not a pull request")) }
    let api = Builtins.endpoint(core, "githubApi", "https://api.github.com") + "/repos/" + repo
    core.requests.fetch(api + "/pulls/" + String(n), headers: headers) { r in
      guard ok(r) else {
        let limited = r.i("status") == 403 || r.i("status") == 429
        return sessionPR(core, req, repo: repo, n: n, limited: limited, done)
      }
      let pr = r["json"]
      let sha = pr["head"].s("sha")
      var checks: Value = .null, statuses: Value = .null
      var left = 2
      let step: () -> Void = {
        left -= 1
        if left == 0 { done(prData(pr, checks: checks, statuses: statuses, repo: repo, n: n)) }
      }
      core.requests.fetch(api + "/commits/" + sha + "/check-runs?per_page=100", headers: headers) { c in
        if ok(c) { checks = c["json"] }
        step()
      }
      core.requests.fetch(api + "/commits/" + sha + "/status", headers: headers) { s in
        if ok(s) { statuses = s["json"] }
        step()
      }
    }
  }

  struct Check {
    var name: String
    var state: String  // failure | pending | queued | success
    var url: String
  }

  /// Check runs plus legacy commit statuses, latest per name, failures first.
  static func checkList(_ checks: Value, _ statuses: Value) -> [Check] {
    var out: [Check] = []
    var seen: [String: Bool] = [:]
    for c in checks.a("check_runs") {
      let name = c.s("name")
      if name.isEmpty || seen[name] == true { continue }
      seen[name] = true
      let concl = c.s("conclusion")
      var state = "success"
      let status = c.s("status")
      if status == "queued" || status == "waiting" || status == "requested" || status == "pending" {
        state = "queued"
      } else if status != "completed" {
        state = "pending"
      } else if ["failure", "timed_out", "cancelled", "action_required", "startup_failure", "stale"].contains(concl) {
        state = "failure"
      }
      out.append(Check(name: name, state: state, url: c.sOpt("html_url") ?? c.s("details_url")))
    }
    for s in statuses.a("statuses") {
      let name = s.s("context")
      if name.isEmpty || seen[name] == true { continue }
      seen[name] = true
      let st = s.s("state")
      out.append(Check(name: name, state: st == "success" ? "success" : st == "pending" ? "pending" : "failure", url: s.s("target_url")))
    }
    func rank(_ s: String) -> Int { s == "failure" ? 0 : s == "pending" ? 1 : s == "queued" ? 2 : 3 }
    var indexed: [(Int, Check)] = []
    for (i, c) in out.enumerated() { indexed.append((i, c)) }
    indexed.sort { rank($0.1.state) != rank($1.1.state) ? rank($0.1.state) < rank($1.1.state) : $0.0 < $1.0 }
    return indexed.map { $0.1 }
  }

  /// The PR peek's data (docs/reference/dia-ui-spec.md §3.2, §3.4) from the REST API's pull, check
  /// runs and statuses: `{kind: "pr", title, author, avatar, repo, number, state, draft, merged,
  /// additions, deletions, files, comments, base, conflicts, checks {total, passed, pending,
  /// queued, failed}, failing [{name, url}], summary}`.
  static func prData(_ pr: Value, checks: Value, statuses: Value, repo: String, n: Int) -> Value {
    let merged = pr.b("merged") || !pr["merged_at"].isNull
    let open = pr.s("state") == "open"
    let list = checkList(checks, statuses)
    let failed = list.filter { $0.state == "failure" }
    let pending = list.filter { $0.state == "pending" }.count
    let queued = list.filter { $0.state == "queued" }.count
    let passed = list.count - failed.count - pending - queued
    let conflicts = open && !merged && (pr.s("mergeable_state") == "dirty" || pr["mergeable"].bool == false)
    var avatar = pr["user"].s("avatar_url")
    if !avatar.isEmpty { avatar += (Text.contains(avatar, "?") ? "&" : "?") + "s=32" }
    var summary: Value = .null
    if merged { summary = Cards.badge("Merged", "merged") }
    else if !open { summary = Cards.badge("Closed", "neutral") }
    else if !failed.isEmpty { summary = Cards.badge("CI failing", "failure") }
    else if conflicts { summary = Cards.badge("Conflicts", "attention") }
    else if pending + queued > 0 { summary = Cards.badge("CI pending", "pending") }
    else if pr.b("draft") { summary = Cards.badge("Draft", "neutral") }
    else if !list.isEmpty { summary = Cards.badge("Passing", "success") }
    var d: Value = [
      "kind": "pr", "title": .string(pr.s("title")), "author": .string(pr["user"].s("login")), "avatar": .string(avatar),
      "repo": .string(repo), "number": .int(Int64(n)), "state": .string(merged ? "merged" : pr.s("state")), "draft": .bool(pr.b("draft")),
      "merged": .bool(merged), "additions": .int(pr.i("additions")), "deletions": .int(pr.i("deletions")), "files": .int(pr.i("changed_files")),
      "comments": .int(pr.i("comments") + pr.i("review_comments")), "base": .string(pr["base"].s("ref")), "conflicts": .bool(conflicts),
      "checks": ["total": .int(Int64(list.count)), "passed": .int(Int64(passed)), "pending": .int(Int64(pending)), "queued": .int(Int64(queued)),
                 "failed": .int(Int64(failed.count))],
      "failing": .array(failed.map { ["name": .string($0.name), "url": .string($0.url)] }),
    ]
    if !summary.isNull { d.put("summary", summary) }
    return d
  }

  /// Private repositories (or a rate-limited API): read the pull request page with the user's
  /// github.com session in den, when they're signed in there. The page embeds the PR's title,
  /// state, author and branches as JSON; checks and the diff load client-side on that page, so
  /// the card says so. Not signed in: `private` without `connected`, and the card offers Connect.
  static func sessionPR(_ core: PreviewsCore, _ req: PreviewsCore.Request, repo: String, n: Int, limited: Bool, _ done: @escaping (Value) -> Void) {
    let web = Builtins.endpoint(core, "githubWeb", "https://github.com")
    let script = "const r = await fetch('/" + repo + "/pull/" + String(n) + "', {credentials: 'include'});\n" + """
      if (!r.ok) return {status: r.status};
      const m = (await r.text()).match(/<script type="application\\/json" data-target="react-app.embeddedData">([\\s\\S]*?)<\\/script>/);
      if (!m) return {status: r.status};
      let d; try { d = JSON.parse(m[1]); } catch (e) { return {status: r.status}; }
      const L = d.payload && d.payload.pullRequestsLayoutRoute;
      if (!L || !L.pullRequest) return {status: r.status};
      const p = L.pullRequest;
      return {status: r.status, state: p.state || '', title: p.title || '', head: p.headBranch || '', base: p.baseBranch || '',
              author: (p.author && p.author.login) || '', avatar: (p.author && p.author.avatarUrl) || '', merged: !!p.mergedTime};
      """
    let base: Value = ["kind": "pr", "repo": .string(repo), "number": .int(Int64(n)), "noCache": true]
    core.requests.call("session", "eval", ["origin": .string(web), "script": .string(script), "profile": .string(req.profile), "timeoutMs": 10_000]) { r in
      let v = r["value"]
      guard r.b("ok"), !v.s("state").isEmpty else {
        var d = base
        // A public PR that GitHub rate-limits isn't private; say what's going on instead.
        d.put(limited ? "limited" : "private", true)
        return done(d)
      }
      let state = Text.lower(v.s("state"))
      var d = base
      d.put(limited ? "limited" : "private", true)
      d.put("connected", true)
      d.put("title", v["title"])
      d.put("author", v["author"])
      d.put("avatar", v["avatar"])
      d.put("base", v["base"])
      d.put("state", .string(v.b("merged") ? "merged" : state == "open" ? "open" : state))
      d.put("merged", .bool(v.b("merged") || state == "merged"))
      done(d)
    }
  }

  static func issue(_ core: PreviewsCore, _ req: PreviewsCore.Request, _ done: @escaping (Value) -> Void) {
    guard let (repo, n) = parse(req.url) else { return done(.err("not an issue")) }
    let api = Builtins.endpoint(core, "githubApi", "https://api.github.com") + "/repos/" + repo
    core.requests.fetch(api + "/issues/" + String(n), headers: headers) { r in
      guard ok(r) else {
        return done(["empty": "This issue is private or GitHub is rate limiting den. Open it to see more.", "subtitle": .string(repo),
                     "accessory": .string("#" + String(n)), "noCache": true])
      }
      done(issueCard(r["json"], repo: repo, n: n, now: core.env.now()))
    }
  }

  static func issueCard(_ i: Value, repo: String, n: Int, now: Int64) -> Value {
    var badges: [Value] = []
    var summary: Value
    if i.s("state") == "open" {
      badges.append(Cards.badge("Open", "success", "sf:smallcircle.filled.circle"))
      summary = Cards.badge("Open", "success")
    } else if i.s("state_reason") == "not_planned" {
      badges.append(Cards.badge("Not planned", "neutral", "sf:slash.circle"))
      summary = Cards.badge("Not planned", "neutral")
    } else {
      badges.append(Cards.badge("Closed", "merged", "sf:checkmark.circle.fill"))
      summary = Cards.badge("Closed", "merged")
    }
    for l in i.a("labels").prefix(3) { badges.append(Cards.badge(l.s("name"), "neutral")) }
    var sections: [Value] = []
    let assignees = i.a("assignees").map { $0.s("login") }.filter { !$0.isEmpty }
    if !assignees.isEmpty {
      sections.append(Cards.section("Assignees", assignees.prefix(3).map { Cards.row($0, icon: "sf:person.crop.circle", id: "assignee:" + $0) }))
    }
    var footer = PV.plural(Int(i.i("comments")), "comment", "comments")
    let author = i["user"].s("login")
    if !author.isEmpty { footer += " · opened by " + author }
    let updated = PV.isoMs(i.s("updated_at"))
    if updated > 0 { footer += " · " + PV.ago(updated, now: now) }
    return ["title": .string(i.s("title")), "subtitle": .string(repo), "accessory": .string("#" + String(n)), "badges": .array(badges),
            "sections": .array(sections), "footer": .string(footer), "summary": summary]
  }
}

// MARK: - Google Calendar

/// Reads today's events from the Calendar tab itself (it must be loaded; nothing is fetched).
/// Google Calendar labels each event chip with its time, title and date; the script parses those
/// in the page's own locale and time zone.
enum Calendar {
  static let script = """
    const now = new Date();
    const today = now.toLocaleDateString('en-US', {month: 'long', day: 'numeric', year: 'numeric'});
    const mins = (s) => {
      const m = /(\\d{1,2})(?::(\\d{2}))?\\s*([ap])\\.?m?/i.exec(s) || /(\\d{1,2}):(\\d{2})/.exec(s);
      if (!m) return -1;
      let h = +m[1] % (m[3] ? 12 : 24); if (m[3] && m[3].toLowerCase() === 'p') h += 12;
      return h * 60 + (+m[2] || 0);
    };
    const out = [], seen = new Set();
    for (const el of document.querySelectorAll('[data-eventid]')) {
      const id = el.getAttribute('data-eventid');
      if (seen.has(id)) continue;
      const t = (el.getAttribute('aria-label') || el.textContent || '').replace(/\\s+/g, ' ').trim();
      if (!t.includes(today)) continue;
      seen.add(id);
      const parts = t.split(', ');
      const all = /^all day/i.test(parts[0]);
      const range = all ? null : /^(.+?) to (.+)$/.exec(parts[0]);
      const link = (/(https:\\/\\/(?:meet\\.google\\.com|[\\w.-]*zoom\\.us|teams\\.microsoft\\.com|teams\\.live\\.com)\\/[^\\s,]+)/.exec(t) || [])[1] || '';
      out.push({title: parts[1] || parts[0], start: all ? 0 : range ? mins(range[1]) : mins(parts[0]),
                end: all ? 1440 : range ? mins(range[2]) : -1, label: all ? 'All day' : parts[0], link, allDay: all});
    }
    out.sort((a, b) => a.start - b.start);
    return {now: now.getHours() * 60 + now.getMinutes(), date: now.toLocaleDateString(undefined, {weekday: 'long', month: 'long', day: 'numeric'}), events: out.slice(0, 40)};
    """

  static func fetch(_ core: PreviewsCore, _ req: PreviewsCore.Request, _ done: @escaping (Value) -> Void) {
    guard !req.webview.isEmpty else { return done(notLoaded()) }
    core.requests.call("webviews", "eval", ["id": .string(req.webview), "script": .string(script), "timeoutMs": 3000], idKey: "request") { r in
      guard r.b("ok"), !r["value"].isNull else { return done(notLoaded()) }
      done(card(r["value"]))
    }
  }

  static func notLoaded() -> Value {
    ["empty": "Open Calendar once and den will glimpse the rest of your day here.", "noCache": true]
  }

  static func relative(_ minutes: Int64) -> String {
    if minutes < 60 { return "in " + String(minutes) + "m" }
    let h = minutes / 60, m = minutes % 60
    return "in " + String(h) + "h" + (m > 0 ? " " + String(m) + "m" : "")
  }

  /// `v` = {now (minutes since local midnight), date, events: [{title, start, end, label, link, allDay}]}.
  static func card(_ v: Value) -> Value {
    let now = v.i("now")
    // The rest of the day: timed events that haven't ended, all-day events first.
    let events = v.a("events").filter { e in
      e.b("allDay") || (e.i("end", -1) > now) || (e.i("end", -1) < 0 && e.i("start") >= now)
    }
    let timed = events.filter { !$0.b("allDay") }
    let next = timed.first
    var badges: [Value] = []
    var actions: [Value] = []
    if let e = next {
      let start = e.i("start")
      if start <= now {
        badges.append(Cards.badge("Now · " + e.s("title"), "success", "sf:circle.fill"))
      } else {
        badges.append(Cards.badge(relative(start - now).capitalizedFirst + " · " + e.s("title"), "accent", "sf:clock.fill"))
      }
    }
    // Join: the first current-or-upcoming event with a meeting link.
    if let e = timed.first(where: { !$0.s("link").isEmpty }) {
      actions.append(["id": "join", "title": .string("Join " + e.s("title")), "icon": "sf:video.fill", "style": "primary", "url": e["link"]])
    }
    var rows: [Value] = []
    let upcoming = events.firstIndex { !$0.b("allDay") && $0.i("start") > now }
    for (i, e) in events.prefix(5).enumerated() {
      let ongoing = !e.b("allDay") && e.i("start") <= now
      var accessory = ""
      if ongoing { accessory = "Now" } else if i == upcoming { accessory = relative(e.i("start") - now) }
      rows.append(Cards.row(e.s("title"), subtitle: e.s("label"), icon: e.s("link").isEmpty ? "sf:calendar" : "sf:video.fill",
                            status: ongoing ? "success" : e.b("allDay") ? "" : "accent", accessory: accessory, url: e.s("link"), id: "event:" + String(i)))
    }
    var card: Value = ["title": "Rest of today", "subtitle": .string(v.s("date")), "badges": .array(badges), "actions": .array(actions)]
    if rows.isEmpty {
      card.put("empty", "Nothing else on your calendar today.")
    } else {
      card.put("sections", [Cards.section("", rows)])
    }
    if events.count > 5 { card.put("footer", .string(String(events.count - 5) + " more later today")) }
    if let e = next { card.put("summary", Cards.badge(e.i("start") <= now ? "Now" : relative(e.i("start") - now), "accent")) }
    return card
  }
}

extension String {
  /// "in 5m" -> "In 5m".
  var capitalizedFirst: String {
    var b = Array(utf8)
    if let f = b.first, f >= 97 && f <= 122 { b[0] = f - 32 }
    return String(decoding: b, as: UTF8.self)
  }
}

// MARK: - Gmail

/// Unread mail from Gmail's Atom feed (`/mail/u/<n>/feed/atom`), read with the user's Google
/// session: sender, subject and time of the newest unread threads, and the unread count.
enum Gmail {
  static func account(_ url: String) -> String {
    let seg = Pattern.segments(url)
    if let i = seg.firstIndex(of: "u"), i + 1 < seg.count, Text.int(seg[i + 1]) != nil { return seg[i + 1] }
    return "0"
  }

  static func fetch(_ core: PreviewsCore, _ req: PreviewsCore.Request, _ done: @escaping (Value) -> Void) {
    let base = Builtins.endpoint(core, "gmail", "https://mail.google.com")
    let u = account(req.url)
    core.requests.fetch(base + "/mail/u/" + u + "/feed/atom", json: false, session: true, profile: req.profile) { r in
      let text = r.s("text")
      guard r.b("ok"), r.i("status") < 400, Text.contains(text, "<feed") else {
        return done(["empty": "Sign in to Gmail in den to see your unread mail here.", "noCache": true])
      }
      done(card(text, base: base, account: u, now: core.env.now()))
    }
  }

  static func card(_ xml: String, base: String, account: String, now: Int64) -> Value {
    let b = Array(xml.utf8)
    let count = Text.int(PV.between(b, "<fullcount>", "</fullcount>")?.0 ?? "") ?? 0
    var email = ""
    if let t = PV.between(b, "<title>", "</title>")?.0, let r = PV.find(Array(t.utf8), Array(" for ".utf8)) {
      email = String(decoding: Array(t.utf8)[(r + 5)...], as: UTF8.self)
    }
    var rows: [Value] = []
    var pos = 0
    while rows.count < 4, let (entry, next) = PV.between(b, "<entry>", "</entry>", from: pos) {
      pos = next
      let e = Array(entry.utf8)
      let subject = PV.unescape(PV.between(e, "<title>", "</title>")?.0 ?? "")
      let author = PV.unescape(PV.between(e, "<name>", "</name>")?.0 ?? "")
      let issued = PV.isoMs(PV.between(e, "<issued>", "</issued>")?.0 ?? PV.between(e, "<modified>", "</modified>")?.0 ?? "")
      var link = ""
      if let l = PV.between(e, "<link", ">")?.0, let h = PV.between(Array(l.utf8), "href=\"", "\"")?.0 { link = PV.unescape(h) }
      rows.append(Cards.row(author.isEmpty ? "(unknown sender)" : author, subtitle: subject.isEmpty ? "(no subject)" : subject, icon: "sf:envelope.fill",
                            status: "accent", accessory: PV.ago(issued, now: now), url: link, id: "mail:" + String(rows.count)))
    }
    var card: Value = [
      "title": "Inbox", "subtitle": .string(email.isEmpty ? "Gmail" : email),
      "badges": [count > 0 ? Cards.badge(PV.plural(count, "unread", "unread"), "accent", "sf:envelope.badge.fill") : Cards.badge("All caught up", "success", "sf:checkmark.circle.fill")],
      "actions": [["id": "compose", "title": "Compose", "icon": "sf:square.and.pencil", "style": "secondary",
                   "url": .string(base + "/mail/u/" + account + "/#inbox?compose=new")]],
      "summary": count > 0 ? Cards.badge(String(count), "accent") : Cards.badge("0", "neutral"),
    ]
    if rows.isEmpty {
      card.put("empty", "No unread mail.")
    } else {
      card.put("sections", [Cards.section("Unread", rows)])
      if count > rows.count { card.put("footer", .string(PV.plural(count - rows.count, "more unread", "more unread"))) }
    }
    return card
  }
}

// MARK: - Slack

/// Unread counts from Slack's web client API with the user's Slack session (the same web-client
/// token the `slack` plugin reads from app.slack.com, kept in memory only).
enum Slack {
  static let configScript = """
    const raw = localStorage.getItem('localConfig_v2');
    if (!raw) return [];
    let c; try { c = JSON.parse(raw); } catch (e) { return []; }
    const out = [];
    for (const k in (c.teams || {})) { const t = c.teams[k] || {}; if (t.token) out.push({id: t.id || k, name: t.name || '', url: t.url || '', token: t.token}); }
    return out;
    """

  /// Team id from app.slack.com/client/T123/…, or the workspace domain from <name>.slack.com.
  static func teamHint(_ url: String) -> String {
    let seg = Pattern.segments(url)
    if let i = seg.firstIndex(of: "client"), i + 1 < seg.count { return seg[i + 1] }
    if let host = seg.first, Text.contains(host, ".slack.com"), host != "app.slack.com" { return host }
    return ""
  }

  static func fetch(_ core: PreviewsCore, _ req: PreviewsCore.Request, _ done: @escaping (Value) -> Void) {
    let origin = Builtins.endpoint(core, "slackOrigin", "https://app.slack.com")
    let cached = core.slackTeams
    let withTeams: ([Value]) -> Void = { teams in
      let hint = teamHint(req.url)
      guard let team = teams.first(where: { $0.s("id") == hint || (!hint.isEmpty && Text.contains($0.s("url"), hint)) }) ?? teams.first else {
        return done(["empty": "Sign in to Slack in den to see unread messages here.", "noCache": true])
      }
      counts(core, req, team, done)
    }
    if let cached { return withTeams(cached) }
    core.requests.call("session", "eval", ["origin": .string(origin), "script": .string(configScript), "profile": .string(req.profile)]) { r in
      let teams = r["value"].array ?? []
      if !teams.isEmpty { core.slackTeams = teams }
      withTeams(teams)
    }
  }

  static func counts(_ core: PreviewsCore, _ req: PreviewsCore.Request, _ team: Value, _ done: @escaping (Value) -> Void) {
    let api = Builtins.endpoint(core, "slackApi", "https://slack.com/api/")
    core.requests.fetch(api + "client.counts", session: true, profile: req.profile, method: "POST",
                        headers: ["Content-Type": "application/x-www-form-urlencoded"], body: "token=" + PV.encode(team.s("token"))) { r in
      let j = r["json"]
      guard r.b("ok"), j.b("ok") else {
        let e = j.s("error")
        if e == "invalid_auth" || e == "not_authed" || e == "token_revoked" { core.slackTeams = nil }
        return done(["empty": "Sign in to Slack in den to see unread messages here.", "noCache": true])
      }
      done(card(j, team: team.s("name")))
    }
  }

  static func card(_ j: Value, team: String) -> Value {
    func tally(_ list: [Value]) -> (Int, Int) {
      var unread = 0, mentions = 0
      for c in list {
        if c.b("has_unreads") || c.i("mention_count") > 0 { unread += 1 }
        mentions += Int(c.i("mention_count"))
      }
      return (unread, mentions)
    }
    let (ch, chm) = tally(j.a("channels"))
    let (dm, dmm) = tally(j.a("ims") + j.a("mpims"))
    let th = j["threads"]
    let thUnread = th.b("has_unreads"), thm = Int(th.i("mention_count"))
    let mentions = chm + dmm + thm
    var badges: [Value] = []
    if mentions > 0 { badges.append(Cards.badge(PV.plural(mentions, "mention", "mentions"), "failure", "sf:at")) }
    if dm > 0 { badges.append(Cards.badge(PV.plural(dm, "DM", "DMs"), "accent", "sf:bubble.left.fill")) }
    if ch > 0 { badges.append(Cards.badge(PV.plural(ch, "channel", "channels"), "neutral", "sf:number")) }
    if badges.isEmpty { badges.append(Cards.badge("All caught up", "success", "sf:checkmark.circle.fill")) }
    var rows: [Value] = [
      Cards.row("Direct messages", icon: "sf:bubble.left.and.bubble.right.fill", status: dm > 0 ? "accent" : "",
                accessory: dm > 0 ? String(dm) + " unread" + (dmm > 0 ? " · " + String(dmm) + " @" : "") : "None", id: "dms"),
      Cards.row("Channels", icon: "sf:number", status: chm > 0 ? "failure" : "",
                accessory: ch > 0 ? String(ch) + " unread" + (chm > 0 ? " · " + String(chm) + " @" : "") : "None", id: "channels"),
    ]
    if thUnread || thm > 0 {
      rows.append(Cards.row("Threads", icon: "sf:text.bubble.fill", status: thm > 0 ? "failure" : "accent", accessory: thm > 0 ? String(thm) + " @" : "Unread", id: "threads"))
    }
    return ["title": .string(team.isEmpty ? "Slack" : team), "subtitle": "Slack", "badges": .array(badges), "sections": [Cards.section("", rows)],
            "summary": mentions > 0 ? Cards.badge(String(mentions) + " @", "failure") : dm + ch > 0 ? Cards.badge(String(dm + ch), "accent") : Cards.badge("0", "neutral")]
  }
}
