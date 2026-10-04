// Energy policy of the tabs plugin (docs/defaults.md "Energy"): battery saver, sites kept active,
// "Unload Space", pausing media nobody can see or hear, and blank tabs closing when you switch
// apps. The host only reports power (`app.power`) and does the native work (`webviews.suspend`,
// `pauseMedia`, `setAutoplay`); every rule lives here.

#if !hasFeature(Embedded)
  import CordisValue
#endif

extension TabsCore {
  /// Battery saver: idle tabs unload after this much den-frontmost time (or sooner, if the
  /// "Unload idle tabs" setting is shorter).
  static let saverSuspendAfterMs: Int64 = 60_000
  /// Silent media in a background tab pauses once there has been no input for this long, so a
  /// muted clip left playing never keeps the Mac awake.
  static let idlePauseSeconds: Double = 300

  /// On battery or in Low Power Mode, with battery saver on.
  var saving: Bool { batterySaver && (power.battery || power.lowPower) }

  var effectiveSuspendAfterMs: Int64 {
    guard suspendAfterMs > 0 else { return 0 }
    return saving ? min(suspendAfterMs, Self.saverSuspendAfterMs) : suspendAfterMs
  }

  func startEnergy() {
    let st = env.call("app", "state")
    power = (st.b("battery"), st.b("lowPower"))
    let saved = env.call("storage", "get", ["ns": .string(Self.ns), "key": "energy"])
    batterySaver = saved["batterySaver"].bool ?? true
    keepActive = saved.a("keepActive").compactMap { $0.string }
    env.on("app.power") { [self] v in
      power = (v.b("battery"), v.b("lowPower"))
      applySaver()
    }
    env.on("tabs.key.unloadSpace") { [self] _ in _ = unloadSpace(currentSpace) }
    applySaver()
  }

  func saveEnergy() {
    env.call("storage", "set", ["ns": .string(Self.ns), "key": "energy",
                                "value": ["batterySaver": .bool(batterySaver), "keepActive": .array(keepActive.map { .string($0) })]])
  }

  /// New pages don't autoplay while saving; background video pauses at once.
  func applySaver() {
    env.call("webviews", "setAutoplay", ["allowed": .bool(!saving)])
    pauseBackgroundMedia(userIdle: false)
  }

  /// The tab on screen, or every pane of the split on screen.
  func onScreenTabs() -> Set<String> { Set(splitOf(shown).flatMap { splits[$0]?.children } ?? [shown]) }

  // MARK: Keep active

  func siteOf(_ id: String) -> String? {
    guard let t = tabs[id], URLs.isWeb(t.url) else { return nil }
    return URLs.host(t.url)
  }

  /// The tab's site (or a parent domain of it) is on the "Always keep active" list.
  func isKeptActive(_ id: String) -> Bool {
    guard let h = siteOf(id) else { return false }
    return keepActive.contains { $0 == h || Text.hasSuffix(h, "." + $0) }
  }

  func toggleKeepActive(_ id: String) {
    guard let h = siteOf(id) else { return }
    let on = !isKeptActive(id)
    if on { keepActive.append(h) } else { keepActive.removeAll { $0 == h || Text.hasSuffix(h, "." + $0) } }
    saveEnergy()
    registerSettings()
    changed(spaceOf(id))
    env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "icon": .string(on ? "sf:bolt.fill" : "sf:moon.zzz"),
                                                     "text": .string(on ? h + " stays active" : h + " can unload again")]])
  }

  // MARK: Media nobody can see or hear

  /// Background pages' media: with battery saver on, video (and silent media) pauses; once you've
  /// been away `idlePauseSeconds`, silent media pauses. Audible audio (music, a podcast) keeps
  /// playing. The host refuses a page on screen (a pane, peek, Little Arc) or in picture in

  /// picture; sites kept active are left alone.
  func pauseBackgroundMedia(userIdle: Bool) {
    guard saving || userIdle else { return }
    let onScreen = onScreenTabs()
    for id in tabs.keys.sorted() where !onScreen.contains(id) && !isKeptActive(id) {
      let st = env.call("webviews", "get", ["id": .string(id)])
      let m = st["media"]
      guard st.b("live"), m.b("playing") else { continue }
      let silent = !m.b("audible") || st.b("muted")
      if silent || (saving && !m["video"].isNull) { env.call("webviews", "pauseMedia", ["id": .string(id)]) }
    }
  }

  // MARK: Unload a space

  /// "Unload Space" (⌃⌘U, the space's menu): every live tab of the space except the one on screen
  /// unloads now. The host keeps what must stay (media, a call, unsaved input). Returns how many.
  func unloadSpace(_ sid: String) -> Int {
    let onScreen = onScreenTabs()
    var n = 0
    for id in tabs.keys.sorted() where spaceOf(id) == sid && !onScreen.contains(id) {
      guard env.call("webviews", "get", ["id": .string(id)]).b("live") else { continue }
      if env.call("webviews", "suspend", ["id": .string(id)]).b("suspended") { n += 1 }
    }
    let text = n == 0 ? "Nothing to unload in " + spaceName(sid) : "Unloaded " + String(n) + (n == 1 ? " tab" : " tabs") + " in " + spaceName(sid)
    env.call("ui", "set", ["slot": "toast", "tree": ["type": "toast", "text": .string(text), "icon": "sf:moon.zzz"]])
    return n
  }

  // MARK: Blank tabs

  /// You switched to another app: blank tabs you left behind (never navigated, nothing loading)
  /// close, without an Archive entry; there is nothing to come back to. The tab on screen,
  /// favorites and split panes stay. Returns how many closed.
  @discardableResult
  func closeBlankTabs() -> Int {
    let onScreen = onScreenTabs()
    var spacesTouched: [String] = []
    var n = 0
    for id in tabs.keys.sorted() {
      guard let t = tabs[id], t.url == "about:blank", !onScreen.contains(id), splitOf(id) == nil, kindOf(id) != "favorite" else { continue }
      let st = env.call("webviews", "get", ["id": .string(id)])
      guard st.s("url").isEmpty || st.s("url") == "about:blank", !st.b("loading"), !st.b("canGoBack") else { continue }
      let sid = spaceOf(id) ?? currentSpace
      if selected[sid] == id { selected[sid] = replacement(for: id, in: sid) }
      archiveTab(id, space: sid)
      if archive.first?.s("id") == id { archive.removeFirst() }
      multi.removeAll { $0 == id }
      if !spacesTouched.contains(sid) { spacesTouched.append(sid) }
      n += 1
    }
    guard n > 0 else { return 0 }
    collectWebviews()
    for sid in spacesTouched { changed(sid) }
    return n
  }
}
