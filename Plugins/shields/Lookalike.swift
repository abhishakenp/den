#if !hasFeature(Embedded)
  import CordisValue
#endif

/// Lookalike domains: a site whose name reads like a well-known one ("аpple.com" with a Cyrillic
/// "а", "g00gle.com", "arnazon.com") but isn't it. Both names are reduced to a skeleton (letters that
/// look alike become one letter, like Unicode's confusables skeleton, UTS #39 §4, on a small table)
/// and compared with den's list of widely used and often-impersonated sites. Chrome's lookalike
/// warning works the same way (skeletons against top domains), with a far larger table.
enum Lookalike {
  /// den's own list: widely used sites and the brands phishing most often imitates (public
  /// knowledge; e.g. APWG phishing trend reports name banks, payment, mail, social and shops).
  static let top: [String] = [
    "google.com", "youtube.com", "gmail.com", "apple.com", "icloud.com", "microsoft.com", "live.com", "outlook.com", "office.com",
    "microsoftonline.com", "bing.com", "amazon.com", "amazon.co.uk", "amazon.de", "amazon.fr", "amazon.co.jp", "amazon.in",
    "facebook.com", "instagram.com", "whatsapp.com", "messenger.com", "meta.com", "x.com", "twitter.com", "linkedin.com", "tiktok.com",
    "snapchat.com", "reddit.com", "pinterest.com", "discord.com", "telegram.org", "signal.org", "zoom.us", "slack.com", "notion.so",
    "github.com", "gitlab.com", "bitbucket.org", "stackoverflow.com", "wikipedia.org", "netflix.com", "spotify.com", "twitch.tv",
    "disneyplus.com", "hulu.com", "primevideo.com", "paypal.com", "stripe.com", "venmo.com", "cash.app", "wise.com", "revolut.com",
    "chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com", "capitalone.com", "usbank.com", "americanexpress.com", "discover.com",
    "hsbc.com", "barclays.co.uk", "santander.com", "lloydsbank.com", "natwest.com", "ing.com", "bnpparibas.com", "deutsche-bank.de",
    "coinbase.com", "binance.com", "kraken.com", "metamask.io", "blockchain.com", "ledger.com", "opensea.io",
    "ebay.com", "etsy.com", "walmart.com", "target.com", "bestbuy.com", "aliexpress.com", "alibaba.com", "shopify.com", "costco.com",
    "ikea.com", "booking.com", "airbnb.com", "expedia.com", "uber.com", "lyft.com", "doordash.com",
    "dropbox.com", "box.com", "docusign.com", "adobe.com", "salesforce.com", "okta.com", "zendesk.com", "atlassian.com", "yahoo.com",
    "aol.com", "proton.me", "protonmail.com", "fastmail.com", "zoho.com", "yandex.ru", "mail.ru", "baidu.com", "naver.com", "qq.com",
    "steampowered.com", "steamcommunity.com", "epicgames.com", "roblox.com", "playstation.com", "xbox.com", "nintendo.com",
    "fedex.com", "ups.com", "usps.com", "dhl.com", "irs.gov", "ssa.gov", "gov.uk", "openai.com", "chatgpt.com", "anthropic.com", "claude.ai",
    "cloudflare.com", "godaddy.com", "namecheap.com", "wordpress.com", "medium.com", "duckduckgo.com", "mozilla.org", "brave.com",
  ]

  /// One letter for letters that look alike: Latin look-alikes from Cyrillic and Greek, accented
  /// Latin letters without their marks, then the ASCII tricks (0→o, 1→l, rn→m, vv→w).
  static func skeleton(_ s: [UInt32]) -> [UInt32] {
    var out: [UInt32] = []
    for c in s {
      if let l = IDN.latinLookalike(c) { out.append(l); continue }
      if let l = unaccented(c) { out.append(l); continue }
      if c >= 0x41 && c <= 0x5A { out.append(c + 32); continue }
      if (0x300...0x36F).contains(c) { continue }  // combining marks
      out.append(c)
    }
    var ascii: [UInt32] = []
    var i = 0
    while i < out.count {
      let c = out[i]
      let next = i + 1 < out.count ? out[i + 1] : 0
      if c == 0x72, next == 0x6E { ascii.append(0x6D); i += 2; continue }  // rn → m
      if c == 0x76, next == 0x76 { ascii.append(0x77); i += 2; continue }  // vv → w
      if c == 0x30 { ascii.append(0x6F); i += 1; continue }  // 0 → o
      if c == 0x31 || c == 0x49 { ascii.append(0x6C); i += 1; continue }  // 1, I → l
      ascii.append(c)
      i += 1
    }
    return ascii
  }

  static func unaccented(_ c: UInt32) -> UInt32? {
    switch c {
    case 0xE0...0xE5, 0x101, 0x103, 0x105, 0x1CE: return 0x61
    case 0xE7, 0x107, 0x109, 0x10B, 0x10D: return 0x63
    case 0x10F, 0x111: return 0x64
    case 0xE8...0xEB, 0x113, 0x115, 0x117, 0x119, 0x11B: return 0x65
    case 0x11D, 0x11F, 0x121, 0x123: return 0x67
    case 0xEC...0xEF, 0x129, 0x12B, 0x12D, 0x12F: return 0x69
    case 0x13A, 0x13C, 0x13E, 0x140, 0x142: return 0x6C
    case 0xF1, 0x144, 0x146, 0x148: return 0x6E
    case 0xF2...0xF6, 0xF8, 0x14D, 0x14F, 0x151: return 0x6F
    case 0x155, 0x157, 0x159: return 0x72
    case 0x15B, 0x15D, 0x15F, 0x161: return 0x73
    case 0x163, 0x165, 0x167: return 0x74
    case 0xF9...0xFC, 0x169, 0x16B, 0x16D, 0x16F, 0x171, 0x173: return 0x75
    case 0xFD, 0xFF, 0x177: return 0x79
    case 0x17A, 0x17C, 0x17E: return 0x7A
    default: return nil
    }
  }

  /// The part of a host people recognise: the last two labels, or three under a two-level public
  /// suffix such as co.uk (a short list, not the Public Suffix List).
  static func site(_ labels: [[UInt32]]) -> [[UInt32]] {
    guard labels.count > 2 else { return labels }
    let second = IDN.string(labels[labels.count - 2])
    let tld = labels[labels.count - 1]
    let twoLevel = ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or"].contains(second) && tld.count == 2
    return Array(labels.suffix(twoLevel ? 3 : 2))
  }

  static func join(_ labels: [[UInt32]]) -> [UInt32] {
    var out: [UInt32] = []
    for (i, l) in labels.enumerated() {
      if i > 0 { out.append(46) }
      out += l
    }
    return out
  }

  nonisolated(unsafe) static var skeletons: [(key: [UInt32], domain: String)] = []

  /// The well-known site `host` imitates, or nil. A host that is that site, or one of its
  /// subdomains, is not a lookalike.
  static func target(_ host: String) -> String? {
    guard let ls = IDN.unicodeLabels(host), ls.count >= 2 else { return nil }
    let siteLabels = site(ls)
    let s = IDN.string(join(siteLabels))
    if top.contains(s) { return nil }
    if skeletons.isEmpty {
      for d in top { skeletons.append((skeleton(IDN.scalars(d)), d)) }
    }
    let key = skeleton(join(siteLabels))
    for (k, d) in skeletons where k == key && d != s {
      // "mail.google.com" is google.com itself; only a different registrable name is a lookalike.
      return d
    }
    // A subdomain spelled like a top site on another domain ("paypal.com.secure-login.net") is a
    // classic trick too, but it is plain ASCII and readable in the pill; not flagged here.
    return nil
  }
}
