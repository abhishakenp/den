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
}
