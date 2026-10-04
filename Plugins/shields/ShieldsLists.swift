// The filter lists den ships, compiled to WebKit content rules at release time by
// scripts/shields/build-lists.sh (EasyList sources → adblock-rust → WebKit validation → LZFSE).
// That script rewrites `version` and the counts below; the files are
// Plugins/shields/resources/<file>, installed as Contents/Resources/plugin-resources/shields/<file>.

enum ShieldsLists {
  /// The upstream lists' "Last modified" day, also the WebKit store version of every list.
  static let version = "2026.09.27-989747b8"

  struct List {
    let name: String  // WKContentRuleList identifier prefix (name@version)
    let file: String
    let rules: Int
    let source: String
    let licence: String
  }

  static let ads = List(name: "shields.ads", file: "ads.json.lzfse", rules: 67_827,
                        source: "EasyList (https://easylist.to), network rules and site-specific hiding",
                        licence: "CC BY-SA 3.0 (EasyList is dual GPL-3.0+/CC BY-SA 3.0+; den uses it under CC BY-SA). © The EasyList authors")
  static let trackers = List(name: "shields.trackers", file: "trackers.json.lzfse", rules: 56_105,
                             source: "EasyPrivacy (https://easylist.to), network rules",
                             licence: "CC BY-SA 3.0 (dual GPL-3.0+/CC BY-SA 3.0+). © The EasyList authors")
  static let cookies = List(name: "shields.cookies", file: "cookies.json.lzfse", rules: 25_239,
                            source: "EasyList Cookie List (https://easylist.to), blocking and hiding rules",
                            licence: "CC BY 3.0 (per the list header). © The EasyList authors")
  static let all = [ads, trackers, cookies]

  /// Scriptlets for what content rules can't do (YouTube's same-origin ads): the engine
  /// `scriptlets.js` (fixed code) runs the rules in `scriptlets.json` (data only), in the page's
  /// world, on the sites the data lists. The data is refreshed daily from `scriptletsURL`.
  static let scriptlets = "shields.scriptlets"
  static let scriptletsCode = "scriptlets.js"
  static let scriptletsData = "scriptlets.json"
  static let scriptletsURL = "https://raw.githubusercontent.com/abhishakenp/den/main/Plugins/shields/resources/scriptlets.json"
  /// uBlock Origin's site scriptlets (anti-adblock walls, pop-unders) for ~20,000 sites, built by
  /// scripts/shields/build-scriptlets.swift; split per site by the host (`perSite`).
  static let sites = "shields.sites"
  static let sitesData = "sites.json"
  static let sitesURL = "https://raw.githubusercontent.com/abhishakenp/den/main/Plugins/shields/resources/sites.json"
  static let sitesSource = "Site scriptlets from uBlock Origin's filters (https://github.com/uBlockOrigin/uAssets). GPL-3.0"
  /// Data files refreshed daily: (file, url).
  static let refreshed = [(scriptletsData, scriptletsURL), (sitesData, sitesURL)]
  static let scriptletsSource = "Scriptlets for YouTube, translated from uBlock Origin's filters (https://github.com/uBlockOrigin/uAssets). GPL-3.0"
}
