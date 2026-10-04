// Pop-ups in tabs (host side: Sources/DenHost/Services/Popups.swift). A page's window.open or
// target=_blank from a click arrives as `webviews.newWindow {id, url, webview}`: the host already
// made the web view, related to its opener (window.opener, postMessage, window.close()), and the
// tab adopts it right after the opener. `window.close()` from such a page closes its tab and goes
// back to the opener. Pop-ups without a click are blocked by the host; the URL pill shows a
// "Pop-up blocked" button that opens them and allows pop-ups on that site from then on.

#if !hasFeature(Embedded)
  import CordisValue
#endif

extension TabsCore {
  static let popupButton = "tabs.popups"

  /// A pop-up page the host made for `src`: a selected tab right after its opener (a private
  /// window's own tab when the opener is private).
  func openPopupTab(_ id: String, url: String, opener src: String) {
    if let w = privateWindow(of: src) {
      _ = openPrivate(url, in: w, background: false, adopt: id, after: src)
      popupOpener[id] = src
      return
    }
    var sid = spaceOf(src) ?? currentSpace
    var index: Int?
    if let (b, i) = locate(src), case let .today(s) = b {
      sid = s
      index = i + 1
    }
    let tid = open(url, space: sid, kind: "today", background: false, index: index, adopt: id)
    popupOpener[tid] = src
  }

  /// `webviews.closeRequested`: the page called `window.close()`. Its tab closes; if it was in
  /// front, its opener comes back.
  func popupCloseRequested(_ id: String, opener: String?) {
    let back = opener ?? popupOpener[id]
    popupOpener[id] = nil
    if ptabs[id] != nil {
      let w = privateWindow(of: id)
      let wasSelected = w.flatMap { privates[$0]?.selected } == id
      closePrivate(id)
      if wasSelected, let o = back, ptabs[o] != nil, privateWindow(of: o) == w { selectPrivate(o) }
      return
    }
    guard tabs[id] != nil else { return }
    let wasSelected = selectedId == id
    close(id)
    if wasSelected, let o = back, tabs[o] != nil { select(o) }
  }

  /// `webviews.popupBlocked {id, url, count}`: the pill's "Pop-up blocked" button while the page
  /// has blocked pop-ups (count 0 removes it).
  func popupBlocked(_ id: String, count: Int64) {
    guard tabs[id] != nil || ptabs[id] != nil else { return }
    var buttons: [Value] = []
    if count > 0 {
      let host = URLs.host(env.call("webviews", "get", ["id": .string(id)]).s("url"))
      let tip = (count == 1 ? "Pop-up blocked" : "Pop-ups blocked") + " — click to open and allow pop-ups" + (host.isEmpty ? "" : " on " + host)
      buttons = [["id": .string(Self.popupButton), "icon": "sf:rectangle.on.rectangle.slash", "tooltip": .string(tip), "active": true]]
    }
    _ = handle("pillButtons", ["webview": .string(id), "owner": .string(Self.popupButton), "buttons": .array(buttons)])
    if let w = privateWindow(of: id) { renderPrivate(w) }
  }

  /// The pill button: opens the page's blocked pop-ups and remembers the site (Shields' per-site
  /// "Pop-ups: Allow"; a private window remembers nothing).
  func allowPopups(_ id: String) {
    let url = env.call("webviews", "get", ["id": .string(id)]).s("url")
    env.call("webviews", "openBlocked", ["id": .string(id)])
    let host = URLs.host(url)
    if !host.isEmpty, ptabs[id] == nil { env.call("shields", "site", ["host": .string(host), "popups": "allow"]) }
  }

  func startPopups() {
    env.on("webviews.closeRequested") { [self] v in popupCloseRequested(v.s("id"), opener: v.sOpt("opener")) }
    env.on("webviews.popupBlocked") { [self] v in popupBlocked(v.s("id"), count: v.i("count")) }
  }
}
