import AppKit
import CordisValue
import DenHost
import WebKit

/// `--scenario consentCheck --url "<url> <url>…"`: Shields' consent answering on real sites, in den.
/// Each URL opens in a tab once the consent list is ready; den waits for Shields' answer (at most
/// 90 s), then reports what the page and the consent platform show:
/// `scenario.consent url=… cmp=… result=… detail=… dialog=[…] tcf={…} cookies={…}`.
/// - `dialog`: the platforms' dialog elements still on the page (visible / hidden).
/// - `tcf`: the IAB TCF answer from the page's own `__tcfapi('getTCData')` (purposes and vendors
///   with consent or legitimate interest on).
/// - `cookies`: what the platforms stored (OptanonConsent groups, didomi_token, euconsent-v2,
///   CookieConsent, notice_preferences/notice_gdpr_prefs/cmapi_cookie_privacy, consentUUID).
/// Prefixes: `nocookies:<url>` turns "Hide cookie banners" off for the site first (so the cookie
/// list doesn't block the platform), `noblock:<url>` turns "Block trackers and ads" off (EasyPrivacy
/// blocks some platforms' geolocation calls, and then no dialog shows), `noconsent:<url>` turns
/// answering off (a baseline). Prefixes combine (`noblock:nocookies:<url>`).
/// Then `scenario.consentDone answered=<n>` and den exits.
@MainActor
final class ConsentCheck {
  let rt: DenRuntime
  var urls: [String]
  var tab = ""
  var answered = 0
  var shieldsOff = ""

  init(rt: DenRuntime, urls: [String]) {
    self.rt = rt
    self.urls = urls.filter { !$0.isEmpty }
  }

  func start() {
    let lists = rt.call("sitepolicy", "list").array ?? []
    let ready = lists.filter { $0.flag("ready") }.map { $0.str("name") }
    guard ready.contains("shields.consent"), ready.contains("shields.consentFrames") else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.start() }
      return
    }
    print("scenario.consent ready \(lists.filter { $0.str("name").hasPrefix("shields.consent") })")
    next()
  }

  static let probe = """
    const out = {};
    const vis = s => { const e = document.querySelector(s); return e ? (e.getClientRects().length && getComputedStyle(e).visibility !== 'hidden' ? 'visible' : 'hidden') : ''; };
    out.dialog = ['#onetrust-banner-sdk','#onetrust-pc-sdk','#didomi-notice','#didomi-popup','#qc-cmp2-ui','#CybotCookiebotDialog','#truste-consent-track','.truste_popframe','div[id^=sp_message_container_]']
      .map(s => vis(s) ? s + ':' + vis(s) : '').filter(Boolean);
    if (typeof __tcfapi === 'function') {
      out.tcf = await new Promise(res => {
        const t = setTimeout(() => res('timeout'), 3000);
        try {
          __tcfapi('getTCData', 2, (d, ok) => {
            clearTimeout(t);
            if (!ok || !d) return res('no data');
            const n = o => Object.values(o || {}).filter(Boolean).length;
            res({ eventStatus: d.eventStatus, purposeConsents: n(d.purpose && d.purpose.consents), purposeLI: n(d.purpose && d.purpose.legitimateInterests),
                  vendorConsents: n(d.vendor && d.vendor.consents), vendorLI: n(d.vendor && d.vendor.legitimateInterests), tcString: (d.tcString || '').slice(0, 24) });
          });
        } catch (e) { res('error ' + e.message); }
      });
    }
    return JSON.stringify(out);
    """

  static let cookieNames = ["OptanonConsent", "OptanonAlertBoxClosed", "didomi_token", "euconsent-v2", "CookieConsent", "notice_preferences",
                            "notice_gdpr_prefs", "cmapi_cookie_privacy", "consentUUID"]

  func next() {
    guard !urls.isEmpty else {
      print("scenario.consentDone answered=\(answered)")
      fflush(stdout)
      exit(0)
    }
    var url = urls.removeFirst()
    if !tab.isEmpty { rt.call("tabs", "close", ["id": .string(tab)]) }
    tab = ""
    if url.hasPrefix("cost:") { return cost(String(url.dropFirst(5)), round: 0, samples: [:]) }
    if url.hasPrefix("evalcost:") { return evalCost(String(url.dropFirst(9))) }
    var off: [String] = []
    while let (prefix, key) = [("nocookies:", "cookies"), ("noconsent:", "consent"), ("noblock:", "blocker")].first(where: { url.hasPrefix($0.0) }) {
      url = String(url.dropFirst(prefix.count))
      off.append(key)
    }
    for key in off { rt.call("shields", "site", ["host": .string(url), key: false]) }
    shieldsOff = off.joined(separator: ",")
    let id = rt.call("tabs", "open", ["url": .string(url)])["id"]
    rt.call("tabs", "select", ["id": id])
    tab = id.string ?? ""
    let t0 = Date()
    func poll(_ n: Int) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        let r = self.rt.call("shields", "get", ["host": .string(url), "webview": .string(self.tab)])["consentResult"]
        // A result, or 90 s; `none` never lands in consentResult, so a page without a dialog waits.
        guard r.isNull, n < 90 else { return self.report(url, r, seconds: Date().timeIntervalSince(t0)) }
        poll(n + 1)
      }
    }
    poll(0)
  }

  // MARK: Cost

  /// Opens `url` and calls `done` with the web view once it finished loading (and 1 s more).
  func load(_ url: String, _ done: @escaping @MainActor (WKWebView?) -> Void) {
    let id = rt.call("tabs", "open", ["url": .string(url)])["id"]
    rt.call("tabs", "select", ["id": id])
    tab = id.string ?? ""
    func wait(_ n: Int) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        let st = self.rt.call("webviews", "get", ["id": id])
        guard st.flag("loading") || st.str("url").isEmpty, n < 120 else {
          return DispatchQueue.main.asyncAfter(deadline: .now() + 1) { done(self.rt.webviews.record(self.tab)?.webView) }
        }
        wait(n + 1)
      }
    }
    wait(0)
  }

  static let timing = """
    const n = performance.getEntriesByType('navigation')[0];
    return JSON.stringify({dcl: n ? Math.round(n.domContentLoadedEventEnd) : -1, load: n ? Math.round(n.loadEventEnd) : -1,
      resources: performance.getEntriesByType('resource').length, frames: frames.length});
    """

  /// `cost:<url>`: 12 loads of the page, consent answering on and off for its site in turn. Per
  /// load: the navigation timing, and whether Shields' consent script was evaluated in the page
  /// (its global in Shields' world). Medians per state.
  func cost(_ url: String, round: Int, samples: [Bool: [(Int, Int)]]) {
    let on = round % 2 == 0
    guard round < 12 else {
      func med(_ a: [Int]) -> Int { let s = a.sorted(); return s.isEmpty ? -1 : s[s.count / 2] }
      for state in [true, false] {
        let s = samples[state] ?? []
        print("scenario.consentCost url=\(url) consent=\(state ? "on" : "off") loads=\(s.count) medianDCL=\(med(s.map { $0.0 }))ms medianLoad=\(med(s.map { $0.1 }))ms dcl=\(s.map { $0.0 }) load=\(s.map { $0.1 })")
      }
      return next()
    }
    rt.call("shields", "site", ["host": .string(url), "consent": .bool(on)])
    load(url) { w in
      guard let w else { return self.cost(url, round: round + 1, samples: samples) }
      w.callAsyncJavaScript(Self.timing, arguments: [:], in: nil, in: .page) { r in
        MainActor.assumeIsolated {
          let t = ((try? r.get()) as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] } ?? [:]
          w.callAsyncJavaScript("return typeof window.__denConsent", arguments: [:], in: nil, in: .world(name: "den.plugin.shields")) { g in
            MainActor.assumeIsolated {
              let lists = self.rt.call("sitepolicy", "get", ["id": .string(self.tab)])
              print("scenario.consentCost load url=\(url) consent=\(on ? "on" : "off") timing=\(t) consentScript=\((try? g.get()) as? String ?? "?") lists=\(lists["active"]) scripts=\(lists["scripts"])")
              var s = samples
              s[on, default: []].append((t["dcl"] as? Int ?? -1, t["load"] as? Int ?? -1))
              self.rt.call("tabs", "close", ["id": .string(self.tab)])
              self.tab = ""
              self.cost(url, round: round + 1, samples: s)
            }
          }
        }
      }
    }
  }

  /// `evalcost:<url>`: what evaluating Shields' consent scripts costs in that page, 5 times each in
  /// fresh isolated worlds: time inside the page (performance.now() around running the source) and
  /// the round trip from den. consent.js only defines its functions; consent-frame.js, in a frame
  /// that isn't a consent platform's (here the main frame), returns at its first check.
  func evalCost(_ url: String) {
    guard let pageJS = rt.permissions.resource("shields", "consent.js").flatMap({ try? String(contentsOf: $0, encoding: .utf8) }),
          let frameJS = rt.permissions.resource("shields", "consent-frame.js").flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) else {
      print("scenario.consentEval no scripts")
      return next()
    }
    let sources = [("consent.js", pageJS), ("consent-frame.js", "(function (denData, denToken) {\n" + frameJS + "\n})(null, \"x\");")]
    load(url) { w in
      guard let w else { return self.next() }
      var runs: [(String, Int)] = []
      for (name, _) in sources { for i in 0..<5 { runs.append((name, i)) } }
      @MainActor func step(_ k: Int, _ inPage: [String: [Double]], _ trip: [String: [Double]]) {
        guard k < runs.count else {
          for (name, src) in sources {
            print("scenario.consentEval url=\(url) script=\(name) bytes=\(src.utf8.count) inPageMs=\(inPage[name] ?? []) roundTripMs=\(trip[name] ?? [])")
          }
          return self.next()
        }
        let (name, i) = runs[k]
        let src = sources.first { $0.0 == name }!.1
        let world = WKContentWorld.world(name: "den.measure.\(name).\(i)")
        let t0 = Date()
        w.callAsyncJavaScript("const t = performance.now(); (new Function(src))(); return performance.now() - t", arguments: ["src": src], in: nil, in: world) { r in
          MainActor.assumeIsolated {
            let ms = Date().timeIntervalSince(t0) * 1000
            var a = inPage, b = trip
            if let v = (try? r.get()) as? Double { a[name, default: []].append((v * 100).rounded() / 100) } else { print("scenario.consentEval error \(r)") }
            b[name, default: []].append((ms * 10).rounded() / 10)
            step(k + 1, a, b)
          }
        }
      }
      step(0, [:], [:])
    }
  }

  func report(_ url: String, _ r: Value, seconds: Double) {
    if r.str("result") == "rejected" { answered += 1 }
    // A moment for the platform to finish storing, then the page's own view of it.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
      guard let w = self.rt.webviews.record(self.tab)?.webView else { return self.next() }
      w.callAsyncJavaScript(Self.probe, arguments: [:], in: nil, in: .page) { result in
        MainActor.assumeIsolated {
          let page = (try? result.get()) as? String ?? "probe failed"
          w.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            MainActor.assumeIsolated {
              let host = w.url?.host ?? ""
              let mine = cookies.filter { c in Self.cookieNames.contains(c.name) && (host == c.domain.trimmingCharacters(in: ["."]) || host.hasSuffix(c.domain.hasPrefix(".") ? c.domain : "." + c.domain)) }
              let stored = mine.map { "\($0.name)=\(($0.value.removingPercentEncoding ?? $0.value).prefix(160))" }.joined(separator: " ")
              print("scenario.consent url=\(url) off=[\(self.shieldsOff)] cmp=\(r.str("cmp")) result=\(r.isNull ? "none" : r.str("result")) after=\(Int(seconds))s detail=\"\(r.str("detail"))\" page=\(page) cookies={\(stored)}")
              self.next()
            }
          }
        }
      }
    }
  }
}
