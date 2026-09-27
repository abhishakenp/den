import AppKit
import CordisValue
import WebKit

/// den's tabs as WebKit sees them. A tab is a `tabs` plugin tab whose id is also its `webviews` id.
/// Everything is read live through the host (`tabs.list`, `webviews`), so nothing is cached here
/// but the object identity WebKit needs.
@MainActor
final class ExtTab: NSObject, WKWebExtensionTab {
  let id: String
  unowned let svc: ExtensionsService
  init(id: String, svc: ExtensionsService) { (self.id, self.svc) = (id, svc) }

  var record: WebRecord? { svc.webviews.record(id) }

  func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { svc.tabIds().contains(id) ? svc.mainWindow : nil }
  func indexInWindow(for context: WKWebExtensionContext) -> Int { svc.tabIds().firstIndex(of: id) ?? NSNotFound }
  func webView(for context: WKWebExtensionContext) -> WKWebView? { record?.webView }
  func title(for context: WKWebExtensionContext) -> String? { record?.title }
  func url(for context: WKWebExtensionContext) -> URL? { record.flatMap { $0.webView?.url ?? URL(string: $0.url) } }
  func isPinned(for context: WKWebExtensionContext) -> Bool { ["pinned", "favorite"].contains(svc.tabKind(id)) }
  func isSelected(for context: WKWebExtensionContext) -> Bool { svc.selectedTabId() == id }
  func isPlayingAudio(for context: WKWebExtensionContext) -> Bool { record?.audio ?? false }
  func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(record?.loading ?? false) }
  func size(for context: WKWebExtensionContext) -> CGSize { record?.webView?.bounds.size ?? .zero }
  func zoomFactor(for context: WKWebExtensionContext) -> Double { Double(record?.webView?.pageZoom ?? 1) }
  func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
    record?.webView?.pageZoom = CGFloat(zoomFactor)
    completionHandler(nil)
  }
  /// `activeTab`: clicking an extension's button grants it this tab until it navigates away.
  func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

  func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
    completionHandler(svc.result(svc.call("tabs", "navigate", ["id": .string(id), "url": .string(url.absoluteString)])))
  }
  func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
    if fromOrigin { record?.webView?.reloadFromOrigin() } else { record?.webView?.reload() }
    completionHandler(nil)
  }
  func goBack(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
    record?.webView?.goBack()
    completionHandler(nil)
  }
  func goForward(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
    record?.webView?.goForward()
    completionHandler(nil)
  }
  func activate(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
    completionHandler(svc.result(svc.call("tabs", "select", ["id": .string(id)])))
  }
  func setSelected(_ selected: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
    if selected { activate(for: context, completionHandler: completionHandler) } else { completionHandler(nil) }
  }
  func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
    completionHandler(svc.result(svc.call("tabs", pinned ? "pin" : "unpin", ["id": .string(id)])))
  }
  func close(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
    completionHandler(svc.result(svc.call("tabs", "close", ["id": .string(id)])))
  }
  func duplicate(using configuration: WKWebExtension.TabConfiguration, for context: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void) {
    let r = svc.call("tabs", "duplicate", ["id": .string(id)])
    completionHandler(r["id"].string.map { svc.tab($0) }, svc.result(r))
  }
  func takeSnapshot(using configuration: WKSnapshotConfiguration, for context: WKWebExtensionContext, completionHandler: @escaping (NSImage?, Error?) -> Void) {
    guard let w = record?.webView else { return completionHandler(nil, ExtensionsService.failure("tab is not loaded")) }
    w.takeSnapshot(with: configuration) { img, err in completionHandler(img, err) }
  }
}

/// den's main window. Arc has one window per profile; den's extensions see the current space's
/// tabs (favorites first, then pinned, then today) as that window's tabs.
@MainActor
final class ExtWindow: NSObject, WKWebExtensionWindow {
  unowned let svc: ExtensionsService
  init(svc: ExtensionsService) { self.svc = svc }
  var nsWindow: NSWindow { svc.window.window }

  func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] { svc.tabIds().map { svc.tab($0) } }
  func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? { svc.selectedTabId().map { svc.tab($0) } }
  func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }
  func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
    if nsWindow.isMiniaturized { return .minimized }
    if nsWindow.styleMask.contains(.fullScreen) { return .fullscreen }
    return nsWindow.isZoomed ? .maximized : .normal
  }
  func isPrivate(for context: WKWebExtensionContext) -> Bool { false }
  func frame(for context: WKWebExtensionContext) -> CGRect { nsWindow.frame }
  func screenFrame(for context: WKWebExtensionContext) -> CGRect { nsWindow.screen?.frame ?? .zero }
  func setFrame(_ frame: CGRect, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
    nsWindow.setFrame(frame, display: true, animate: false)
    completionHandler(nil)
  }
  func focus(for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
    Presentation.activate()
    Presentation.show(nsWindow)
    completionHandler(nil)
  }
}

/// `WKWebExtensionControllerDelegate`: windows, new tabs, options pages, permission prompts and
/// action popups, all answered by `ExtensionsService`.
@MainActor
final class ExtensionControllerDelegate: NSObject, WKWebExtensionControllerDelegate {
  unowned let svc: ExtensionsService
  init(svc: ExtensionsService) { self.svc = svc }

  func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] { [svc.mainWindow] }
  func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
    svc.window.window.isKeyWindow || NSApp.isActive ? svc.mainWindow : nil
  }

  func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionTab)?, Error?) -> Void) {
    let (tab, err) = svc.openTab(configuration.url, active: configuration.shouldBeActive, pinned: configuration.shouldBePinned)
    completionHandler(tab, err)
  }

  /// den has one window: a new window from an extension opens as a tab.
  func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration, for extensionContext: WKWebExtensionContext, completionHandler: @escaping ((any WKWebExtensionWindow)?, Error?) -> Void) {
    for (i, u) in configuration.tabURLs.enumerated() { _ = svc.openTab(u, active: i == 0 && configuration.shouldBeFocused, pinned: false) }
    completionHandler(svc.mainWindow, nil)
  }

  func webExtensionController(_ controller: WKWebExtensionController, openOptionsPageFor extensionContext: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
    guard let u = extensionContext.optionsPageURL else { return completionHandler(ExtensionsService.failure("no options page")) }
    completionHandler(svc.openTab(u, active: true, pinned: false).1)
  }

  func webExtensionController(_ controller: WKWebExtensionController, promptForPermissions permissions: Set<WKWebExtension.Permission>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void) {
    svc.prompt(extensionContext, permissions: permissions.map(\.rawValue), patterns: []) { ok in
      completionHandler(ok ? permissions : [], nil)
    }
  }

  func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionToAccess urls: Set<URL>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<URL>, Date?) -> Void) {
    svc.prompt(extensionContext, permissions: [], patterns: urls.compactMap { $0.host }) { ok in completionHandler(ok ? urls : [], nil) }
  }

  func webExtensionController(_ controller: WKWebExtensionController, promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>, in tab: (any WKWebExtensionTab)?, for extensionContext: WKWebExtensionContext, completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void) {
    svc.prompt(extensionContext, permissions: [], patterns: matchPatterns.map(\.string)) { ok in completionHandler(ok ? matchPatterns : [], nil) }
  }

  func webExtensionController(_ controller: WKWebExtensionController, presentActionPopup action: WKWebExtension.Action, for context: WKWebExtensionContext, completionHandler: @escaping (Error?) -> Void) {
    completionHandler(svc.presentPopup(action, context: context))
  }

  func webExtensionController(_ controller: WKWebExtensionController, didUpdate action: WKWebExtension.Action, forExtensionContext context: WKWebExtensionContext) {
    svc.actionChanged(context)
  }
}
