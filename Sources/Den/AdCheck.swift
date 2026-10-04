import AppKit
import CordisValue
import DenHost
import WebKit

/// `--scenario adCheck --url "<url> <url>…"`: Shields against real ads, in den itself.
/// - YouTube watch pages are played muted (as after a click on play) and sampled every 2 s for
///   40 s: the player's `ad-showing` class, the ad fields of its player response, playback
///   progress, the anti-adblock dialog, and what den's scriptlets removed (`sitepolicy.get` →
///   `scripted`, which the panel's blocked count includes).
/// - `embed:<videoId>`: a page on another site (example.com) with that video in a YouTube embed;
///   a probe script reports from inside the embed frame whether den's scriptlets run there.
/// - Other pages report WebKit's blocked count after loading.
/// Exits 0 when no YouTube page or embed showed an ad and every one played.
@MainActor
final class AdCheck: NSObject, WKScriptMessageHandler {
  let rt: DenRuntime
  var urls: [String]
  var failures = 0
  var tab = ""
  var embedReports: [[String: Any]] = []

  init(rt: DenRuntime, urls: [String]) {
    self.rt = rt
    self.urls = urls.filter { !$0.isEmpty }
  }

  static let probe = """
    const p=document.getElementById('movie_player'),v=document.querySelector('video');
    const r=p&&p.getPlayerResponse?p.getPlayerResponse():null,ir=window.ytInitialPlayerResponse;
    if(p&&v&&v.paused&&!p.classList.contains('ad-showing')&&p.playVideo){if(p.mute)p.mute();p.playVideo();}
    const dlg=document.querySelector('ytd-enforcement-message-view-model');
    return JSON.stringify({player:!!p,ad:!!(p&&p.classList.contains('ad-showing')),
      fields:[r,ir].map(o=>o?['adPlacements','playerAds','adSlots'].filter(k=>o[k]!==undefined).join('+'):'-'),
      t:v?Math.round(v.currentTime*10)/10:-1,dur:v?Math.round(v.duration||0):-1,
      len:r&&r.videoDetails?+r.videoDetails.lengthSeconds:-1,status:r&&r.playabilityStatus?r.playabilityStatus.status:'',
      enforce:!!(dlg&&dlg.offsetParent!==null),adSlots:document.querySelectorAll('ytd-ad-slot-renderer,ytd-in-feed-ad-layout-renderer').length});
    """

  /// Runs in every frame of the embed page (page world, the scenario's own script): YouTube frames
  /// report their player state and whether den's scriptlets are there (`window[token]`).
  static func embedReporter(_ token: String) -> String {
    """
    (function(){ if (!/(^|\\.)(youtube\\.com|youtube-nocookie\\.com)$/.test(location.hostname)) return;
      setInterval(function(){ try {
        var p=document.getElementById('movie_player'),v=document.querySelector('video');
        if(p&&v&&v.paused&&!p.classList.contains('ad-showing')&&p.playVideo){if(p.mute)p.mute();p.playVideo();}
        var r=p&&p.getPlayerResponse?p.getPlayerResponse():null;
        var f=typeof window['\(token)']==='function';
        webkit.messageHandlers.denAdCheck.postMessage(JSON.stringify({host:location.hostname,hooked:f,count:f?window['\(token)']():-1,
          player:!!p,ad:!!(p&&p.classList.contains('ad-showing')),t:v?v.currentTime:-1,
          fields:r?['adPlacements','playerAds','adSlots'].filter(function(k){return r[k]!==undefined}).join('+'):'-'}));
      } catch(e) {} }, 2000); })();
    """
  }

  func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
    if let s = m.body as? String, let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] { embedReports.append(o) }
  }

  func start() {
    let ready = (rt.call("sitepolicy", "list").array ?? []).filter { $0.flag("ready") }
    guard ready.count >= 4 else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.start() }
      return
    }
    print("scenario.ad ready \(ready.map { "\($0.str("name")) cached=\($0.flag("cached"))\($0["allFrames"].isNull ? "" : " allFrames=\($0.flag("allFrames"))")" }.joined(separator: " "))")
    next()
  }

  func next() {
    guard !urls.isEmpty else {
      print("scenario.adDone ok=\(failures == 0) failures=\(failures)")
      fflush(stdout)
      exit(failures == 0 ? 0 : 1)
    }
    var url = urls.removeFirst()
    if !tab.isEmpty { rt.call("tabs", "close", ["id": .string(tab)]) }
    if url.hasPrefix("embed:") { return embed(String(url.dropFirst(6))) }
    // `noshields:<url>`: the same page with Shields off for its site (a baseline).
    if url.hasPrefix("noshields:") {
      url = String(url.dropFirst(10))
      rt.call("shields", "site", ["host": .string(url), "blocker": false])
    }
    if url.contains("twitch.tv/") { return twitch(url) }
    let id = rt.call("tabs", "open", ["url": .string(url)])["id"]
    rt.call("tabs", "select", ["id": id])
    tab = id.string ?? ""
    if url.contains("youtube.com/watch") { sample(url, n: 0, seen: []) } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
        let st = self.rt.call("sitepolicy", "get", ["id": .string(self.tab)])
        print("scenario.ad page url=\(url) blocked=\(st.num("blocked")) byList=\(st["blockedByList"]) scripts=\(st["scripts"])")
        self.next()
      }
    }
  }

  /// A page on example.com with a YouTube embed (autoplay, muted), probed from inside the frame.
  func embed(_ video: String) {
    let id = rt.call("tabs", "open", ["url": "about:blank"])["id"]
    rt.call("tabs", "select", ["id": id])
    tab = id.string ?? ""
    embedReports = []
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      guard let w = self.rt.webviews.record(self.tab)?.webView else { return self.next() }
      let ucc = w.configuration.userContentController
      ucc.add(self, contentWorld: .page, name: "denAdCheck")
      ucc.addUserScript(WKUserScript(source: Self.embedReporter(self.rt.sitePolicy.pageToken), injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .page))
      let html = "<h1>An article</h1><iframe width=640 height=360 src='https://www.youtube.com/embed/\(video)?autoplay=1&mute=1' allow='autoplay' allowfullscreen></iframe>"
      w.loadHTMLString(html, baseURL: URL(string: "https://example.com/article"))
      DispatchQueue.main.asyncAfter(deadline: .now() + 40) {
        let top = self.rt.call("sitepolicy", "get", ["id": .string(self.tab)])
        let r = self.embedReports.filter { $0["player"] as? Bool == true }
        let ads = r.filter { $0["ad"] as? Bool == true }.count
        let times = r.compactMap { $0["t"] as? Double }
        let played = (times.max() ?? 0) - (times.min() ?? 0)
        let hooked = r.contains { $0["hooked"] as? Bool == true }
        let fields = Set(r.compactMap { $0["fields"] as? String })
        let ok = !r.isEmpty && hooked && ads == 0 && played >= 5 && fields.allSatisfy { $0.isEmpty || $0 == "-" }
        if !ok { self.failures += 1 }
        print("scenario.ad embed video=\(video) ok=\(ok) reports=\(r.count) frameHooked=\(hooked) frameCount=\(r.last?["count"] ?? -1) adShowing=\(ads) "
          + "adFields=\(fields.sorted()) played=\(String(format: "%.1f", played))s topFrameScripted=\(top["scripted"])")
        ucc.removeScriptMessageHandler(forName: "denAdCheck", contentWorld: .page)
        self.next()
      }
    }
  }

  static let twitchProbe = """
    const v=document.querySelector('video');
    if(v&&v.paused){v.muted=true;v.play().catch(()=>{});}
    const gate=document.querySelector('[data-a-target="content-classification-gate-overlay-start-watching-button"],[data-a-target="player-overlay-mature-accept"]');
    if(gate)gate.click();
    const vis=s=>{const e=document.querySelector(s);return !!(e&&e.getBoundingClientRect().height>0&&getComputedStyle(e).display!=='none')};
    const p=document.querySelector('.video-player');
    return JSON.stringify({ad:vis('[data-a-target="video-ad-label"]')||vis('[data-a-target="video-ad-countdown"]')||/commercial break|ad \\d+ of \\d+/i.test(p?p.innerText:''),
      t:v?v.currentTime:-1,rs:v?v.readyState:-1,w:v?v.videoWidth:0,text:p?p.innerText.replace(/\\s+/g,' ').slice(0,80):''});
    """

  /// A Twitch channel: muted playback sampled every 2 s for 50 s (ad label or "Commercial break",
  /// progress).
  func twitch(_ url: String) {
    let id = rt.call("tabs", "open", ["url": .string(url)])["id"]
    rt.call("tabs", "select", ["id": id])
    tab = id.string ?? ""
    var seen: [[String: Any]] = []
    func step(_ n: Int) {
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        guard let w = self.rt.webviews.record(self.tab)?.webView else { return step(n + 1) }
        w.callAsyncJavaScript(Self.twitchProbe, arguments: [:], in: nil, in: .page) { result in
          MainActor.assumeIsolated {
            if let s = try? result.get() as? String, let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] { seen.append(o) }
            if n < 25 { return step(n + 1) }
            let ads = seen.filter { $0["ad"] as? Bool == true }.count
            let times = seen.compactMap { $0["t"] as? Double }.filter { $0 >= 0 }
            let played = (times.max() ?? 0) - (times.min() ?? 0)
            let st = self.rt.call("sitepolicy", "get", ["id": .string(self.tab)])
            print("scenario.ad twitch url=\(url) samples=\(seen.count) adSamples=\(ads) played=\(String(format: "%.1f", played))s "
              + "readyState=\(seen.last?["rs"] ?? -1) width=\(seen.last?["w"] ?? 0) blocked=\(st.num("blocked")) scripted=\(st["scripted"]) text=\(seen.last?["text"] ?? "")")
            self.next()
          }
        }
      }
    }
    step(0)
  }

  func sample(_ url: String, n: Int, seen: [[String: Any]]) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      guard let w = self.rt.webviews.record(self.tab)?.webView else { return self.sample(url, n: n + 1, seen: seen) }
      let scripted = self.rt.call("sitepolicy", "get", ["id": .string(self.tab)]).num("scripted")
      w.callAsyncJavaScript(Self.probe, arguments: [:], in: nil, in: .page) { result in
        MainActor.assumeIsolated {
          var seen = seen
          if let s = try? result.get() as? String, var o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
             o["player"] as? Bool == true {
            o["scripted"] = scripted
            seen.append(o)
          }
          if n < 20 { return self.sample(url, n: n + 1, seen: seen) }
          self.report(url, seen)
          self.next()
        }
      }
    }
  }

  func report(_ url: String, _ seen: [[String: Any]]) {
    let ads = seen.filter { $0["ad"] as? Bool == true }.count
    let fields = Set(seen.compactMap { ($0["fields"] as? [String])?.joined(separator: "/") })
    let times = seen.compactMap { $0["t"] as? Double }
    let played = (times.max() ?? 0) - (times.first(where: { $0 >= 0 }) ?? 0)
    let last = seen.last ?? [:]
    let enforce = seen.contains { $0["enforce"] as? Bool == true }
    let fieldsClean = fields.allSatisfy { $0 == "/" || $0 == "-/-" || $0 == "/-" || $0 == "-/" }
    let scripted = (last["scripted"] as? Double) ?? -1
    let ok = !seen.isEmpty && ads == 0 && played >= 5 && !enforce && fieldsClean && scripted >= 0
    if !ok { failures += 1 }
    print("scenario.ad youtube url=\(url) ok=\(ok) samples=\(seen.count) adShowing=\(ads) adFields=\(fields.sorted()) played=\(String(format: "%.1f", played))s "
      + "dur=\(last["dur"] ?? -1) len=\(last["len"] ?? -1) status=\(last["status"] ?? "") enforce=\(enforce) adSlots=\(last["adSlots"] ?? 0) scripted=\(Int(scripted))")
  }
}
