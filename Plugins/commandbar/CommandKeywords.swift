// Site-search keyword suggestions for the command bar.
//
// When the command bar opens on a site that supports rich search operators
// (GitHub, Stack Overflow, YouTube, Reddit, etc.), a one-time toast suggests
// useful operators and filters. The user has already seen it once; it only
// shows on first open per site.
//
// Example: on GitHub the toast reads "Search GitHub faster with operators:
// repos:mozilla org:google is:pr type:pr". Tapping it fills the bar with
// the suggestion.

#if !hasFeature(Embedded)
  import CordisValue
#endif

extension CommandBarCore {
  /// One toast row in the keyword suggestion.
  struct KeywordSuggestion {
    let operatorText: String  // the raw text that fills into the bar (e.g. "repos:mozilla is:pr")
    let description: String   // human label (e.g. "Restrict to a repository")
    let icon: String          // SF Symbol for the operator row
  }

  /// A site the plugin recognises as search-rich.
  struct SearchSite {
    let host: String
    let name: String
    let icon: String
    let tips: [KeywordSuggestion]
    /// A regex that decides whether the current URL is "on this site" (beyond just the host).
    /// nil means any URL with this host.
    let urlPattern: String? = nil
  }

  static let searchSites: [SearchSite] = [
    SearchSite(
      host: "github.com",
      name: "GitHub",
      icon: "sf:terminal",
      tips: [
        KeywordSuggestion(operatorText: "repos:", description: "Restrict to a repo", icon: "sf:leaf.circle"),
        KeywordSuggestion(operatorText: "org:", description: "Restrict to an organisation", icon: "sf:person.badge.plus"),
        KeywordSuggestion(operatorText: "user:", description: "Restrict to a user", icon: "sf:person"),
        KeywordSuggestion(operatorText: "is:issue is:open", description: "Open issues", icon: "sf:circle.lefthalf.filled"),
        KeywordSuggestion(operatorText: "is:pr", description: "Pull requests", icon: "sf:arrow.right.circle"),
        KeywordSuggestion(operatorText: "type:problem", description: "Code scanning alerts", icon: "sf:exclamationmark.triangle"),
      ]),
    SearchSite(
      host: "stackoverflow.com",
      name: "Stack Overflow",
      icon: "sf:questionmark.circle",
      tips: [
        KeywordSuggestion(operatorText: "site:stackoverflow.com", description: "Search SO only", icon: "sf:link.circle"),
        KeywordSuggestion(operatorText: "score:>10", description: "Top-voted answers", icon: "sf:arrow.up.circle"),
        KeywordSuggestion(operatorText: "answers:0", description: "Unanswered questions", icon: "sf:questionmark.circle.badge.plus"),
        KeywordSuggestion(operatorText: "has:answer", description: "Questions with answers", icon: "sf:checkmark.circle"),
        KeywordSuggestion(operatorText: "accepted:yes", description: "Accepted answer", icon: "sf:checkmark.seal"),
      ]),
    SearchSite(
      host: "youtube.com",
      name: "YouTube",
      icon: "sf:play.rectangle",
      tips: [
        KeywordSuggestion(operatorText: "duration:short", description: "Under 4 minutes", icon: "sf:clock"),
        KeywordSuggestion(operatorText: "duration:medium", description: "4–20 minutes", icon: "sf:clock.fill"),
        KeywordSuggestion(operatorText: "duration:long", description: "Over 20 minutes", icon: "sf:clock.badge.checkmark"),
        KeywordSuggestion(operatorText: "list=PL", description: "Search a playlist", icon: "sf:playlist"),
        KeywordSuggestion(operatorText: "upload_date:week", description: "Uploaded this week", icon: "sf:calendar.badge.clock"),
      ]),
    SearchSite(
      host: "reddit.com",
      name: "Reddit",
      icon: "sf:speaker.wave.3",
      tips: [
        KeywordSuggestion(operatorText: "sort:top", description: "Top comments", icon: "sf:arrow.up.circle"),
        KeywordSuggestion(operatorText: "sort:new", description: "Newest posts", icon: "sf:star"),
        KeywordSuggestion(operatorText: "sort:relevance", description: "Best match", icon: "sf:lightbulb"),
        KeywordSuggestion(operatorText: "flair:help", description: "Specific flair", icon: "sf:tag"),
        KeywordSuggestion(operatorText: "comment_count:>10", description: "Most discussed", icon: "sf:message.fill"),
      ]),
    SearchSite(
      host: "npmjs.com",
      name: "npm",
      icon: "sf:cube.box",
      tips: [
        KeywordSuggestion(operatorText: "keywords:typescript", description: "By keyword", icon: "sf:tag.circle"),
        KeywordSuggestion(operatorText: "author:facebook", description: "By author", icon: "sf:person"),
        KeywordSuggestion(operatorText: "deprecated:false", description: "Active packages only", icon: "sf:checkmark.seal"),
        KeywordSuggestion(operatorText: "publishdate:week", description: "Published this week", icon: "sf:calendar"),
      ]),
    SearchSite(
      host: "crates.io",
      name: "Crates.io",
      icon: "sf:hexagon",
      tips: [
        KeywordSuggestion(operatorText: "sort:downloads", description: "Most downloaded", icon: "sf:arrow.down.circle"),
        KeywordSuggestion(operatorText: "sort:new", description: "Newest crates", icon: "sf:sparkles"),
        KeywordSuggestion(operatorText: "range:1.0..2.0", description: "Version range", icon: "sf:number"),
      ]),
    SearchSite(
      host: "pypi.org",
      name: "PyPI",
      icon: "sf:square.and.arrow.down",
      tips: [
        KeywordSuggestion(operatorText: "version:3.*", description: "Specific version", icon: "sf:number"),
        KeywordSuggestion(operatorText: "created:>2024-01-01", description: "Uploaded recently", icon: "sf:calendar"),
        KeywordSuggestion(operatorText: "author:google", description: "By author", icon: "sf:person"),
      ]),
    SearchSite(
      host: "duckduckgo.com",
      name: "DuckDuckGo",
      icon: "sf:crosshair",
      tips: [
        KeywordSuggestion(operatorText: "site:github.com", description: "Restrict to a site", icon: "sf:link"),
        KeywordSuggestion(operatorText: "filetype:pdf", description: "PDF only", icon: "sf:doc"),
        KeywordSuggestion(operatorText: "inurl:blog", description: "URL contains word", icon: "sf:link.circle"),
      ]),
    SearchSite(
      host: "google.com",
      name: "Google",
      icon: "sf:globe",
      tips: [
        KeywordSuggestion(operatorText: "site:github.com", description: "Restrict to a site", icon: "sf:link"),
        KeywordSuggestion(operatorText: "filetype:pdf", description: "PDF only", icon: "sf:doc"),
        KeywordSuggestion(operatorText: "inurl:blog", description: "URL contains word", icon: "sf:link.circle"),
        KeywordSuggestion(operatorText: "intitle:template", description: "Title contains word", icon: "sf:textformat"),
      ]),
    SearchSite(
      host: "wikipedia.org",
      name: "Wikipedia",
      icon: "sf:globe.americas",
      tips: [
        KeywordSuggestion(operatorText: "site:wikipedia.org", description: "Wikipedia only", icon: "sf:globe"),
        KeywordSuggestion(operatorText: "insite:wikipedia.org", description: "Not on Wikipedia", icon: "sf:globe.slash"),
        KeywordSuggestion(operatorText: "filetype:pdf", description: "PDF documents", icon: "sf:doc.fill"),
      ]),
  ]

  // MARK: - Detection

  /// Returns the best-matching site for `url`, or nil when the URL doesn't match a known search site.
  static func detectSite(_ url: String) -> SearchSite? {
    let host = URLs.host(url)
    for site in searchSites {
      guard host == site.host else { continue }
      if let pattern = site.urlPattern, !Text.contains(host.lowercased(), pattern.lowercased()) { continue }
      return site
    }
    return nil
  }

  // MARK: - Toast display

  /// Shows a keyword-suggestion toast when the bar opens on a search-rich site.
  /// `currentURL` is the selected tab's URL at bar-open time.
  func showKeywordHint(_ currentURL: String) {
    guard let site = Self.detectSite(currentURL) else { return }
    guard let first = site.tips.first else { return }
    // Build the toast text from the site's top 3 tips.
    let topTips = Array(site.tips.prefix(3))
    let tipText = topTips.map { $0.operatorText + " " + $0.description }.joined(separator: " · ")
    let toastText = "Search " + site.name + " faster: " + tipText
    // Build operator chips as an action tree: each tip gets a tap target that fills its operator.
    var children: [Value] = []
    children.append([
      "type": "label", "text": .string("💡 " + site.name + " search tips"),
      "size": 12, "weight": "semibold",
    ])
    for tip in topTips {
      children.append([
        "type": "action", "id": .string("keyword." + tip.icon), "variant": "pill",
        "title": .string(tip.operatorText + " · " + tip.description), "height": 24, "tone": "primary",
      ])
    }
    children.append([
      "type": "action", "id": "commandbar.keywords.dismiss", "variant": "pill",
      "title": "Dismiss", "height": 24, "tone": "secondary",
    ])
    env.call("ui", "set", ["slot": "toast", "tree": [
      "type": "card",
      "id": "commandbar.keywords",
      "spacing": 6, "padding": [10, 10, 8, 8],
      "children": .array(children),
    ]])
    // Also keep a simple text toast for the old path.
    env.call("ui", "set", ["slot": "toast", "tree": [
      "type": "toast",
      "id": "commandbar.keywords.text",
      "text": .string(toastText),
      "icon": "sf:magnifyingglass",
      "duration": .int(7_000),
      "action": "Dismiss",
    ]])
  }

  /// Fills the command bar with the operator text from a suggested tip.
  func fillKeywordOperator(_ operatorText: String) {
    env.call("ui", "set", ["slot": "toast", "tree": .null])
    // Fill the text into the command bar input.
    if isOpen {
      query = operatorText
      env.call("ui", "set", ["slot": .string(Self.slot), "tree": [
        "type": "commandBar", "id": .string(Self.barId), "query": .string(operatorText), "replaceQuery": true,
        "selected": .string(""), "sections": .array([]), "headers": true,
        "inputMode": .string("search"),
      ]])
    }
  }
}