import AppKit
import CordisValue
import DenHost
import WebKit

/// `--scenario adCheck --url "<url> <url>…"`: Shields against real ads, in den itself.
/// YouTube watch pages are played muted (as after a click on play) and sampled every 2 s for 30 s:
/// the player's `ad-showing` class, the ad fields of its player response, playback progress, the
/// anti-adblock dialog. Other pages report WebKit's blocked count after loading. Exits 0 when no
/// YouTube page showed an ad and every one played.
@MainActor
final class AdCheck {
  let rt: DenRuntime
  var urls: [String]
  var failures = 0
  var tab = ""

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
      enforce:!!(dlg&&dlg.offsetParent!==null),adSlots:document.querySelectorAll('ytd-ad-slot-renderer,ytd-in-feed-ad-layout-renderer').length,
      hooked:!!window.__denScriptlets});
    """

  func start() {
    let ready = (rt.call("sitepolicy", "list").array ?? []).filter { $0.flag("ready") }
    guard ready.count >= 4 else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.start() }
      return
    }
    print("scenario.ad ready \(ready.map { "\($0.str("name")) cached=\($0.flag("cached"))" }.joined(separator: " "))")
    next()
  }

  func next() {
    guard !urls.isEmpty else {
      print("scenario.adDone ok=\(failures == 0) failures=\(failures)")
      fflush(stdout)
      exit(failures == 0 ? 0 : 1)
    }
    let url = urls.removeFirst()
    if !tab.isEmpty { rt.call("tabs", "close", ["id": .string(tab)]) }
    let id = rt.call("tabs", "open", ["url": .string(url)])["id"]
    rt.call("tabs", "select", ["id": id])
    tab = id.string ?? ""
    let t0 = Date()
    if url.contains("youtube.com/watch") { sample(url, t0, n: 0, seen: []) } else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
        let st = self.rt.call("sitepolicy", "get", ["id": .string(self.tab)])
        print("scenario.ad page url=\(url) blocked=\(st.num("blocked")) byList=\(st["blockedByList"]) scripts=\(st["scripts"])")
        self.next()
      }
    }
  }

  func sample(_ url: String, _ t0: Date, n: Int, seen: [[String: Any]]) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
      guard let w = self.rt.webviews.record(self.tab)?.webView else { return self.sample(url, t0, n: n + 1, seen: seen) }
      w.callAsyncJavaScript(Self.probe, arguments: [:], in: nil, in: .page) { result in
        MainActor.assumeIsolated {
          var seen = seen
          if let s = try? result.get() as? String, let d = s.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
             o["player"] as? Bool == true { seen.append(o) }
          if n < 20 { return self.sample(url, t0, n: n + 1, seen: seen) }
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
    let ok = !seen.isEmpty && ads == 0 && played >= 5 && !enforce && fieldsClean
    if !ok { failures += 1 }
    print("scenario.ad youtube url=\(url) ok=\(ok) samples=\(seen.count) adShowing=\(ads) adFields=\(fields.sorted()) played=\(String(format: "%.1f", played))s "
      + "dur=\(last["dur"] ?? -1) len=\(last["len"] ?? -1) status=\(last["status"] ?? "") enforce=\(enforce) adSlots=\(last["adSlots"] ?? 0) hooked=\(last["hooked"] ?? false)")
  }
}
