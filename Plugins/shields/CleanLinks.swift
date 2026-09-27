#if !hasFeature(Embedded)
  import CordisValue
#endif

/// den's own lists for clean navigation, written from public documentation (sources below), not
/// copied from any list: DuckDuckGo's are CC BY-NC-SA (not usable in an MIT app); Brave's
/// `query-filter.json` / `debounce.json` are MPL-2.0 (compatible as unmodified separate files, but
/// den's rule shapes differ and a list of public parameter names needs no second licence).
///
/// Sources for the parameters (each is the click or mail identifier of the named service):
/// - Firefox query stripping, strict list: https://firefox-source-docs.mozilla.org/toolkit/components/antitracking/anti-tracking/query-stripping/index.html
///   (mc_eid, oly_anon_id, oly_enc_id, __s, vero_id, _hsenc, mkt_tok, fbclid)
/// - Brave query filter: https://github.com/brave/brave-browser/wiki/Query-String-Filter
/// - Google Ads gclid/gbraid/wbraid/dclid/gclsrc and the cross-domain linker _gl:
///   https://support.google.com/google-ads/answer/9744275, https://support.google.com/analytics/answer/10071811
/// - Google Merchant Center srsltid: https://support.google.com/merchants/answer/11127659
/// - Microsoft Advertising msclkid: https://help.ads.microsoft.com/#apex/ads/en/60000
/// - Meta fbclid, Instagram igshid/igsh, TikTok ttclid, X twclid, LinkedIn li_fat_id, Yandex
///   yclid/ysclid, Pinterest epik, Snapchat ScCid: each vendor's conversion-tracking docs.
/// - HubSpot _hsenc/_hsmi/__hssc/__hstc/__hsfp/hsCtaTracking, Marketo mkt_tok, Mailchimp mc_eid,
///   Vero vero_id/vero_conv, Oracle Eloqua/Omeda oly_*: email-tracking docs of each service.
/// - utm_*: Google Analytics campaign parameters (https://support.google.com/analytics/answer/10917952).
enum CleanLinks {
  /// Removed from every http(s) navigation, on any site.
  static let params: [String] = [
    "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "srsltid", "_gl",
    "mc_eid", "igshid", "ttclid", "twclid", "li_fat_id", "yclid", "ysclid", "epik", "sccid", "rb_clickid",
    "_hsenc", "_hsmi", "__hssc", "__hstc", "__hsfp", "hsctatracking", "mkt_tok", "oly_anon_id", "oly_enc_id",
    "vero_id", "vero_conv", "__s", "wickedid", "_openstat",
  ]
  /// Removed from every navigation when the name starts with one of these.
  static let prefixes: [String] = ["utm_"]
  /// Removed only on these sites (the name means something else elsewhere).
  static let scoped: [(hosts: [String], params: [String])] = [
    (["youtube.com", "youtu.be", "open.spotify.com"], ["si"]),  // share-sheet tracking ids
    (["instagram.com"], ["igsh"]),
    (["x.com", "twitter.com"], ["s", "t", "ref_src"]),  // share source and share token
  ]

  static func hostMatches(_ host: String, _ suffixes: [String]) -> Bool {
    for s in suffixes where host == s || Text.hasSuffix(host, "." + s) { return true }
    return false
  }

  /// The URL without tracking parameters, and how many were removed. Keeps everything else
  /// byte-for-byte: scheme, host, path, the order and encoding of the other parameters, the fragment.
  static func strip(_ url: String) -> (url: String, removed: [String]) {
    let b = Array(url.utf8)
    guard let q = b.firstIndex(of: 63) else { return (url, []) }  // ?
    let hash = b.firstIndex(of: 35)  // #
    if let h = hash, h < q { return (url, []) }
    let end = hash ?? b.count
    let host = URLs.host(url)
    var extra: [String] = []
    for s in scoped where hostMatches(host, s.hosts) { extra += s.params }
    var kept: [[UInt8]] = []
    var removed: [String] = []
    var start = q + 1
    while start <= end {
      var stop = start
      while stop < end, b[stop] != 38 { stop += 1 }  // &
      let pair = Array(b[start..<stop])
      if !pair.isEmpty {
        var name = pair
        if let eq = pair.firstIndex(of: 61) { name = Array(pair[..<eq]) }
        let key = Text.lower(String(decoding: name, as: UTF8.self))
        if tracking(key, extra) { removed.append(key) } else { kept.append(pair) }
      }
      start = stop + 1
    }
    guard !removed.isEmpty else { return (url, []) }
    var out = Array(b[..<q])
    if !kept.isEmpty {
      out.append(63)
      for (i, p) in kept.enumerated() {
        if i > 0 { out.append(38) }
        out += p
      }
    }
    if let h = hash { out += b[h...] }
    return (String(decoding: out, as: UTF8.self), removed)
  }

  static func tracking(_ key: String, _ extra: [String]) -> Bool {
    if params.contains(key) || extra.contains(key) { return true }
    for p in prefixes where Text.hasPrefix(key, p) { return true }
    return false
  }

  // MARK: Bounce tracking

  /// Redirect services that only log the click and forward to a URL carried in a parameter.
  /// Security redirectors (Google's /url, Facebook's l.facebook.com, YouTube's /redirect, Steam's
  /// link filter) warn about dangerous links, so they are deliberately left alone (Brave does the same:
  /// https://github.com/brave/brave-browser/wiki/Debouncing).
  static let bounces: [(hosts: [String], path: String, param: String)] = [
    (["click.linksynergy.com"], "", "murl"),  // Rakuten Advertising deep links
    (["awin1.com"], "/cread.php", "ued"),  // Awin
    (["awin1.com"], "/awclick.php", "ued"),
    (["go.redirectingat.com"], "", "url"),  // Skimlinks
    (["dpbolvw.net", "anrdoezrs.net", "jdoqocy.com", "kqzyfj.com", "tkqlhce.com"], "", "url"),  // CJ Affiliate
    (["7eer.net", "sjv.io", "pxf.io", "evyy.net", "ojrq.net"], "", "u"),  // impact.com
    (["out.reddit.com"], "", "url"),  // Reddit outbound links
    (["slack-redir.net"], "/link", "url"),  // Slack
    (["t.umblr.com"], "/redirect", "z"),  // Tumblr
  ]

  /// The destination a bounce-tracking URL forwards to, or nil. Only http(s) destinations count.
  static func unwrap(_ url: String) -> String? {
    let host = URLs.host(url)
    let path = pathOf(url)
    for rule in bounces where hostMatches(host, rule.hosts) {
      if !rule.path.isEmpty, path != rule.path { continue }
      guard let raw = param(url, rule.param) else { continue }
      let dest = percentDecode(raw)
      let low = Text.lower(dest)
      guard Text.hasPrefix(low, "https://") || Text.hasPrefix(low, "http://") else { continue }
      guard !Text.contains(dest, " "), !Text.contains(dest, "\n") else { continue }
      return dest
    }
    return nil
  }

  static func pathOf(_ url: String) -> String {
    let b = Array(url.utf8)
    var i = 0
    if let r = URLs.find(b, Array("://".utf8)) { i = r + 3 }
    while i < b.count, b[i] != 47, b[i] != 63, b[i] != 35 { i += 1 }
    var j = i
    while j < b.count, b[j] != 63, b[j] != 35 { j += 1 }
    return i < j ? String(decoding: b[i..<j], as: UTF8.self) : "/"
  }

  static func param(_ url: String, _ name: String) -> String? {
    let b = Array(url.utf8)
    guard let q = b.firstIndex(of: 63) else { return nil }
    let end = b.firstIndex(of: 35) ?? b.count
    guard q < end else { return nil }
    var start = q + 1
    while start < end {
      var stop = start
      while stop < end, b[stop] != 38 { stop += 1 }
      let pair = Array(b[start..<stop])
      if let eq = pair.firstIndex(of: 61), Text.lower(String(decoding: pair[..<eq], as: UTF8.self)) == name {
        return String(decoding: pair[(eq + 1)...], as: UTF8.self)
      }
      start = stop + 1
    }
    return nil
  }

  static func percentDecode(_ s: String) -> String {
    let b = Array(s.utf8)
    var out: [UInt8] = []
    var i = 0
    func hex(_ c: UInt8) -> UInt8? {
      switch c {
      case 48...57: return c - 48
      case 65...70: return c - 55
      case 97...102: return c - 87
      default: return nil
      }
    }
    while i < b.count {
      if b[i] == 37, i + 2 < b.count, let h = hex(b[i + 1]), let l = hex(b[i + 2]) {
        out.append(h << 4 | l)
        i += 3
      } else {
        out.append(b[i])
        i += 1
      }
    }
    return String(decoding: out, as: UTF8.self)
  }
}

extension Text {
  static func hasSuffix(_ s: String, _ p: String) -> Bool {
    let a = Array(s.utf8), b = Array(p.utf8)
    guard a.count >= b.count else { return false }
    let off = a.count - b.count
    for j in 0..<b.count where a[off + j] != b[j] { return false }
    return true
  }
}
