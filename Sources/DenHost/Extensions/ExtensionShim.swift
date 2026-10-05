// thin-host: feature-specific, migrate to plugin (whole file)
import CordisValue
import Foundation

/// The extension APIs WebKit doesn't have. den's real ones (`bookmarks`, `history`, `sessions`,
/// `search`, `downloads`, `sidePanel`, `sidebarAction`, `identity`) are JavaScript here that calls
/// den over native messaging (ExtensionAPIs.swift); events WebKit leaves out of a namespace it has
/// get working stand-ins (below); `idle`, `offscreen` and `storage.session.setAccessLevel` are
/// answered so start-up code carries on.
///
/// den adds them to its own copy of a store or file install (never to a folder in
/// ~/.den/extensions): `__den/shim.js` runs first in the background, in every content script and
/// in the extension's own pages. Nothing is patched where WebKit has the real API.
public enum ExtensionShim {
  static let dir = "__den"
  static let script = "__den/shim.js"
  /// A classic service worker's wrapper, written next to the worker: bundlers load chunks
  /// relative to the worker's own URL (Bitwarden, Grammarly), so it must live in the same folder.
  static let workerName = "__den_worker.js"
  /// Where shim v1–4 put the wrapper (chunks then resolved under __den/ and failed to load).
  static let oldWorker = "__den/worker.js"
  /// Marks the background context (event subscriptions from it wake it again; it opens link-hint tabs).
  static let backgroundFlag = "__den/background.js"
  /// Bumped when `source` changes, so installed copies get the new one on their next load.
  static let version = 6
  /// Present when den added `nativeMessaging` to the manifest for its own APIs (ExtensionAPIs):
  /// granted at load, and never shown as something the extension asked for.
  static let addedNative = "__den/native-messaging"

  /// Whether den added `nativeMessaging` to this copy (it isn't the extension's own request).
  static func addedNativeMessaging(_ root: URL) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(addedNative).path) }

  /// Adds the shim to an unpacked extension. Idempotent; returns whether anything changed.
  /// `validPattern` says whether WebKit takes a match pattern: content script entries lose the
  /// ones it rejects, and an entry left with none is dropped, so one entry WebKit can't read
  /// doesn't leave the extension with a load error. `redirect` is `identity.getRedirectURL()`'s
  /// base when it isn't Chrome's (`https://<runtime.id>.chromiumapp.org/`): a Firefox Add-ons
  /// install's.
  @discardableResult
  public static func apply(to root: URL, validPattern: (String) -> Bool = { _ in true }, redirect: String? = nil) throws -> Bool {
    let fm = FileManager.default
    let manifestURL = root.appendingPathComponent("manifest.json")
    let data = try Data(contentsOf: manifestURL)
    let clean = data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
    guard var m = try JSONSerialization.jsonObject(with: clean) as? [String: Any] else { throw ExtensionPackageError("manifest.json is not valid JSON") }
    let marker = "// den-shim v\(version)"
    let shimURL = root.appendingPathComponent(script)
    let config = "globalThis.__denConfig = " + ValueJSON.string(["redirect": redirect.map { .string($0) } ?? .null]) + ";\n"
    let content = marker + "\n" + config + source
    let current = (try? String(contentsOf: shimURL, encoding: .utf8)) == content
    var changed = false
    if !current {
      try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
      try content.write(to: shimURL, atomically: true, encoding: .utf8)
      try "globalThis.__denBackground = true;\n".write(to: root.appendingPathComponent(backgroundFlag), atomically: true, encoding: .utf8)
      changed = true
    }
    // den's own APIs answer over native messaging (to den itself, never another app).
    if ExtensionAPIs.usesBridge(m) {
      var perms = (m["permissions"] as? [Any]) ?? []
      if !perms.contains(where: { ($0 as? String) == "nativeMessaging" }) {
        perms.append("nativeMessaging")
        m["permissions"] = perms
        try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        try "den added nativeMessaging for its own APIs\n".write(to: root.appendingPathComponent(addedNative), atomically: true, encoding: .utf8)
        changed = true
      }
    }
    var backgroundPage: String?

    // Background: a classic service worker gets a wrapper that loads the shim first. A module
    // service worker never finishes starting in WebKit (seen with Vimium on macOS 26.6: the same
    // code runs as Firefox's module background scripts), so it becomes module background
    // scripts, which WebKit runs for Manifest V3 too. Scripts and pages get the shim prepended.
    if var bg = m["background"] as? [String: Any] {
      if let sw = bg["service_worker"] as? String, (sw as NSString).lastPathComponent != workerName {
        var path = sw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path == oldWorker, let old = try? String(contentsOf: root.appendingPathComponent(oldWorker), encoding: .utf8),
           let orig = old.components(separatedBy: "\"").filter({ $0.hasPrefix("/") }).last {
          path = String(orig.dropFirst())
        }
        if (bg["type"] as? String) == "module" {
          bg["service_worker"] = nil
          bg["scripts"] = [path]
        } else {
          let folder = (path as NSString).deletingLastPathComponent
          let wrapper = folder.isEmpty ? workerName : folder + "/" + workerName
          try "importScripts(\"/\(backgroundFlag)\", \"/\(script)\", \"/\(path)\");\n".write(to: root.appendingPathComponent(wrapper), atomically: true, encoding: .utf8)
          bg["service_worker"] = wrapper
        }
        changed = true
      }
      if var scripts = bg["scripts"] as? [String], scripts.first != backgroundFlag {
        scripts.insert(contentsOf: [backgroundFlag, script], at: 0)
        bg["scripts"] = scripts
        changed = true
      }
      backgroundPage = (bg["page"] as? String).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
      m["background"] = bg
    }
    if var cs = m["content_scripts"] as? [[String: Any]] {
      for i in cs.indices {
        if let matches = cs[i]["matches"] as? [String] {
          let ok = matches.filter(validPattern)
          if ok.count != matches.count {
            cs[i]["matches"] = ok
            changed = true
          }
        }
        guard var js = cs[i]["js"] as? [String], !js.isEmpty, js.first != script else { continue }
        js.insert(script, at: 0)
        cs[i]["js"] = js
        changed = true
      }
      cs.removeAll { ($0["matches"] as? [String])?.isEmpty ?? true }
      m["content_scripts"] = cs
    }
    // The extension's own pages (popup, options, background page, UI frames).
    if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
      for case let u as URL in e where u.pathExtension.lowercased() == "html" {
        guard var html = try? String(contentsOf: u, encoding: .utf8), !html.contains("/\(script)"),
              let r = html.range(of: "<script", options: .caseInsensitive) else { continue }
        let rel = String(u.resolvingSymlinksInPath().path.dropFirst(root.resolvingSymlinksInPath().path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let flag = rel == backgroundPage ? "<script src=\"/\(backgroundFlag)\"></script>" : ""
        html.insert(contentsOf: flag + "<script src=\"/\(script)\"></script>", at: r.lowerBound)
        try html.write(to: u, atomically: true, encoding: .utf8)
        changed = true
      }
    }
    if changed {
      let out = try JSONSerialization.data(withJSONObject: m, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
      try out.write(to: manifestURL)
    }
    return changed
  }

  /// Runs in extension pages, service workers (classic or module) and content scripts. Strict-mode
  /// safe; defines only what is missing.
  static let source = #"""
    (() => {
      'use strict';
      const g = globalThis;
      if (g.__denShim) return;
      g.__denShim = true;
      const roots = [...new Set([g.chrome, g.browser].filter(x => x && typeof x === 'object'))];
      const api = roots[0];
      if (!api || !api.runtime) return;
      const inContent = typeof api.tabs === 'undefined';
      let perms = [];
      try { perms = api.runtime.getManifest().permissions || []; } catch (e) {}
      const unavailable = (what) => new Error(what + ' isn’t available in den');
      const event = () => {
        const ls = new Set();
        return {
          addListener: (f) => { ls.add(f); }, removeListener: (f) => { ls.delete(f); },
          hasListener: (f) => ls.has(f), hasListeners: () => ls.size > 0,
          fire: (...a) => ls.forEach((f) => { try { f(...a); } catch (e) { console.error(e); } }),
        };
      };
      // chrome.* style: a trailing callback, or a promise.
      const fn = (f) => function (...args) {
        const cb = typeof args[args.length - 1] === 'function' ? args.pop() : null;
        const p = Promise.resolve().then(() => f(...args));
        if (!cb) return p;
        p.then((r) => cb(r), (e) => { console.warn(String(e)); cb(); });
      };
      const define = (name, value) => {
        for (const r of roots) {
          if (r[name] != null) continue;
          try { Object.defineProperty(r, name, {value, configurable: true, enumerable: true, writable: true}); } catch (e) {}
        }
      };
      const local = api.storage && api.storage.local;
      const load = async (key, fallback) => {
        try { const o = await local.get(key); return o && o[key] || fallback; } catch (e) { return fallback; }
      };
      const save = (key, value) => { try { local.set({[key]: value}); } catch (e) {} };

      // Link hints (Vimium's F, and extensions like it) open a link in a new tab with a synthetic
      // ⌘/Ctrl-click. WebKit does nothing for one, so the content script asks its own background
      // (below) to open the tab. Only right after a key the user pressed, and only for web links.
      if (inContent) {
        let lastKey = 0;
        g.addEventListener('keydown', (e) => { if (e.isTrusted) lastKey = Date.now(); }, true);
        g.addEventListener('click', (e) => {
          if (e.isTrusted || !(e.metaKey || e.ctrlKey) || e.button !== 0 || Date.now() - lastKey > 2000) return;
          const a = e.target && e.target.closest ? e.target.closest('a[href]') : null;
          if (!a || !/^https?:/.test(a.href)) return;
          setTimeout(() => {
            if (e.defaultPrevented) return;
            try { api.runtime.connect({name: '__den.openTab'}).postMessage({url: a.href, active: e.shiftKey === true}); } catch (x) {}
          }, 0);
        }, true);
        return;
      }
      // Extensions that pick a Safari or a Chrome code path from the user agent alone. Bitwarden's
      // Chrome Web Store build, told it runs in Safari, sends Safari app-extension messages that
      // no desktop app answers (no biometric unlock) and waits on Safari-only calls. In its own
      // pages and background (never in web pages) it's told it runs in Chrome, which it does: the
      // Chrome build, the chrome.* API, Chrome's native messaging host.
      // By store id, or by name for a copy installed from a file (its id is den's own).
      const chromeIdentity = ['nngceckbapebfimnlniiiahkandclblb', 'hccnnhgbibccigepcmlgppchkpfdophk'];
      try {
        const nav = g.navigator;
        if (nav && (chromeIdentity.includes(api.runtime.id) || /^Bitwarden\b/.test(String(api.runtime.getManifest().name))) && !/ Chrome\//.test(nav.userAgent)) {
          const ua = nav.userAgent.replace(/ Version\/[\d.]+ Safari\/[\d.]+$/, '') + ' Chrome/140.0.0.0 Safari/537.36';
          const proto = Object.getPrototypeOf(nav);
          Object.defineProperty(proto, 'userAgent', {get: () => ua, configurable: true});
          Object.defineProperty(proto, 'appVersion', {get: () => ua.replace(/^Mozilla\//, ''), configurable: true});
          Object.defineProperty(proto, 'vendor', {get: () => 'Google Inc.', configurable: true});
        }
      } catch (e) {}
      const inBackground = g.__denBackground === true;
      if (inBackground && api.runtime.onConnect && api.tabs && api.tabs.create) {
        api.runtime.onConnect.addListener((port) => {
          if (port.name !== '__den.openTab') return;
          port.onMessage.addListener((m) => {
            if (m && typeof m.url === 'string' && /^https?:/.test(m.url)) api.tabs.create({url: m.url, active: m.active === true}).catch(() => {});
            try { port.disconnect(); } catch (x) {}
          });
        });
      }
      const report = g.__denShimReport = {events: [], wrapped: [], failed: []};

      // Events WebKit leaves out of a namespace it has. One missing event is enough to stop a
      // background at its first `.addListener` (Vimium: webNavigation.onHistoryStateUpdated), so
      // each gets a working stand-in; the namespace is wrapped when WebKit won't take a new key.
      const addToNamespace = (ns, extra) => {
        const target = api[ns];
        for (const [k, v] of Object.entries(extra)) { try { Object.defineProperty(target, k, {value: v, configurable: true, enumerable: true}); } catch (e) {} }
        if (Object.keys(extra).every((k) => target[k] != null)) return true;
        const wrapper = new Proxy(target, {
          get: (t, k) => {
            if (Object.prototype.hasOwnProperty.call(extra, k)) return extra[k];
            const v = Reflect.get(t, k);
            return typeof v === 'function' ? v.bind(t) : v;
          },
          has: (t, k) => Object.prototype.hasOwnProperty.call(extra, k) || Reflect.has(t, k),
        });
        for (const r of roots) { try { Object.defineProperty(r, ns, {value: wrapper, configurable: true, enumerable: true, writable: true}); } catch (e) {} }
        if (Object.keys(extra).every((k) => api[ns] && api[ns][k] != null)) { report.wrapped.push(ns); return true; }
        report.failed.push(ns);
        return false;
      };
      const EVENTS = {
        webNavigation: ['onBeforeNavigate', 'onCommitted', 'onDOMContentLoaded', 'onCompleted', 'onErrorOccurred', 'onCreatedNavigationTarget',
          'onReferenceFragmentUpdated', 'onTabReplaced', 'onHistoryStateUpdated'],
        tabs: ['onCreated', 'onUpdated', 'onMoved', 'onActivated', 'onHighlighted', 'onDetached', 'onAttached', 'onRemoved', 'onReplaced', 'onZoomChange'],
        windows: ['onCreated', 'onRemoved', 'onFocusChanged', 'onBoundsChanged'],
        runtime: ['onStartup', 'onInstalled', 'onSuspend', 'onSuspendCanceled', 'onUpdateAvailable', 'onConnect', 'onConnectExternal', 'onMessage', 'onMessageExternal'],
        action: ['onClicked'], storage: ['onChanged'], alarms: ['onAlarm'], commands: ['onCommand'], contextMenus: ['onClicked'],
        notifications: ['onClosed', 'onClicked', 'onButtonClicked', 'onShown'], permissions: ['onAdded', 'onRemoved'],
      };
      const urls = new Map();
      let watching = false;
      const navigation = {};
      // History-API and #fragment navigations, from the tab URL changes WebKit reports without a load.
      const watchURLs = () => {
        if (watching || !inBackground || !api.tabs || !api.tabs.onUpdated) return;
        watching = true;
        api.tabs.onUpdated.addListener((tabId, info, tab) => {
          const url = info.url || (tab && tab.url);
          if (!url) return;
          const prev = urls.get(tabId);
          urls.set(tabId, url);
          if (!info.url || !prev || prev === url || info.status === 'loading' || (tab && tab.status === 'loading')) return;
          const d = {tabId, url, frameId: 0, parentFrameId: -1, processId: 0, timeStamp: Date.now(), transitionType: 'link', transitionQualifiers: []};
          const e = prev.split('#')[0] === url.split('#')[0] ? navigation.onReferenceFragmentUpdated : navigation.onHistoryStateUpdated;
          if (e) e.fire(d);
        });
        if (api.tabs.onRemoved) api.tabs.onRemoved.addListener((id) => { urls.delete(id); });
      };
      for (const [ns, names] of Object.entries(EVENTS)) {
        if (!api[ns]) continue;
        const extra = {};
        for (const n of names) {
          if (api[ns][n] != null) continue;
          const e = event();
          if (ns === 'webNavigation' && (n === 'onHistoryStateUpdated' || n === 'onReferenceFragmentUpdated')) {
            navigation[n] = e;
            const add = e.addListener;
            e.addListener = (f) => { add(f); watchURLs(); };
          }
          extra[n] = e;
          report.events.push(ns + '.' + n);
        }
        if (Object.keys(extra).length) addToNamespace(ns, extra);
      }

      // storage.session.setAccessLevel (background and pages only: content scripts keep their
      // own fallbacks for a missing one).
      try {
        const s = api.storage && api.storage.session;
        if (s && typeof s.setAccessLevel !== 'function') {
          Object.defineProperty(s, 'setAccessLevel', {value: fn(() => undefined), configurable: true, writable: true});
        }
      } catch (e) {}

      // idle and offscreen: answered so start-up code that touches them carries on.
      if (perms.includes('idle')) {
        define('idle', {queryState: fn(() => 'active'), setDetectionInterval: () => {}, getAutoLockDelay: fn(() => 0), onStateChanged: event()});
      }
      if (perms.includes('offscreen')) {
        define('offscreen', {
          createDocument: fn(() => { throw unavailable('Offscreen documents'); }), closeDocument: fn(() => undefined),
          hasDocument: fn(() => false), Reason: {CLIPBOARD: 'CLIPBOARD', DOM_PARSER: 'DOM_PARSER', BLOBS: 'BLOBS', LOCAL_STORAGE: 'LOCAL_STORAGE'},
        });
      }

      // den's own APIs (ExtensionAPIs.swift): bookmarks, history, sessions, search, downloads,
      // sidePanel, sidebarAction and identity, answered by den over native messaging to den itself.
      const DEN = 'io.github.abhishakenp.den';
      const cfg = g.__denConfig || {};
      const call = (ns, method, ...args) => new Promise((resolve, reject) => {
        if (typeof api.runtime.sendNativeMessage !== 'function') return reject(unavailable(ns + '.' + method));
        const done = (r) => {
          if (r && typeof r.error === 'string') reject(new Error(r.error)); else resolve(r ? r.ok : undefined);
        };
        let p;
        try { p = api.runtime.sendNativeMessage(DEN, {__den: ns, method, args: args.map((a) => a === undefined ? null : a)}); } catch (e) { return reject(e); }
        if (p && typeof p.then === 'function') p.then(done, reject); else reject(unavailable(ns + '.' + method));
      });
      const subs = new Map();
      let port = null;
      const listening = () => [...subs].filter(([, e]) => e.hasListeners()).map(([n]) => n);
      const subscribe = (names) => {
        if (!port) {
          try { port = api.runtime.connectNative(DEN); } catch (e) { port = null; return; }
          port.onMessage.addListener((m) => { const e = m && subs.get(m.event); if (e) e.fire(...(m.args || [])); });
          port.onDisconnect.addListener(() => { port = null; setTimeout(() => { const l = listening(); if (l.length) subscribe(l); }, 1000); });
        }
        try { port.postMessage({subscribe: names, background: inBackground}); } catch (e) {}
      };
      const evt = (name) => {
        const e = event();
        const add = e.addListener;
        e.addListener = (f) => { add(f); subscribe([name]); };
        subs.set(name, e);
        return e;
      };
      const ns = (name, methods, events, extra) => {
        const o = Object.assign({}, extra || {});
        for (const m of methods) o[m] = fn((...a) => call(name, m, ...a));
        for (const e of events) o[e] = evt(name + '.' + e);
        define(name, o);
      };
      const manifest = (() => { try { return api.runtime.getManifest(); } catch (e) { return {}; } })();

      if (perms.includes('bookmarks')) {
        ns('bookmarks', ['getTree', 'getSubTree', 'get', 'getChildren', 'getRecent', 'search', 'create', 'update', 'move', 'remove', 'removeTree'],
          ['onCreated', 'onRemoved', 'onChanged', 'onMoved', 'onChildrenReordered', 'onImportBegan', 'onImportEnded'],
          {MAX_WRITE_OPERATIONS_PER_HOUR: 1000000, MAX_SUSTAINED_WRITE_OPERATIONS_PER_MINUTE: 1000000});
      }
      if (perms.includes('history')) {
        ns('history', ['search', 'getVisits', 'addUrl', 'deleteUrl', 'deleteRange', 'deleteAll'], ['onVisited', 'onVisitRemoved']);
      }
      if (perms.includes('sessions')) {
        ns('sessions', ['getRecentlyClosed', 'getDevices'], ['onChanged'], {
          MAX_SESSION_RESULTS: 25,
          restore: fn(async (sessionId) => {
            const s = await call('sessions', 'restore', sessionId == null ? null : sessionId);
            try { const [t] = await api.tabs.query({active: true, currentWindow: true}); if (t) s.tab = t; } catch (e) {}
            return s;
          }),
        });
      }
      if (perms.includes('search') && api.tabs) {
        define('search', {
          query: fn(async ({text, disposition, tabId} = {}) => {
            const {url} = await call('search', 'query', {text: text || ''});
            if (tabId != null) return void await api.tabs.update(tabId, {url});
            if (disposition === 'NEW_TAB') return void await api.tabs.create({url});
            if (disposition === 'NEW_WINDOW' && api.windows) return void await api.windows.create({url});
            const [t] = await api.tabs.query({active: true, currentWindow: true});
            if (t) await api.tabs.update(t.id, {url}); else await api.tabs.create({url});
          }),
        });
      }
      if (perms.includes('downloads')) {
        ns('downloads', ['download', 'search', 'pause', 'resume', 'cancel', 'getFileIcon', 'open', 'show', 'showDefaultFolder', 'erase', 'removeFile',
          'acceptDanger', 'setShelfEnabled', 'setUiOptions'], ['onCreated', 'onErased', 'onChanged'], {
          // den names files itself: this never fires.
          onDeterminingFilename: event(), drag: () => {},
        });
      }
      if (perms.includes('sidePanel') || manifest.side_panel) {
        ns('sidePanel', ['setOptions', 'getOptions', 'setPanelBehavior', 'getPanelBehavior', 'open', 'close', 'getLayout'], ['onOpened', 'onClosed'], {
          Side: {LEFT: 'left', RIGHT: 'right'},
        });
      }
      if (manifest.sidebar_action) {
        ns('sidebarAction', ['open', 'close', 'toggle', 'isOpen', 'setPanel', 'getPanel', 'setTitle', 'getTitle', 'setIcon'], []);
      }
      if (perms.includes('identity')) {
        const redirect = (path) => (cfg.redirect || 'https://' + api.runtime.id + '.chromiumapp.org/') + String(path || '').replace(/^\//, '');
        define('identity', {
          getRedirectURL: redirect,
          launchWebAuthFlow: fn((details) => call('identity', 'launchWebAuthFlow', details || {})),
          getAuthToken: fn(() => { throw new Error('den can’t sign extensions in to a Google account (identity.getAuthToken). Sign-in through the extension’s own page (launchWebAuthFlow) works.'); }),
          getProfileUserInfo: fn(() => ({email: '', id: ''})), getAccounts: fn(() => []),
          removeCachedAuthToken: fn(() => undefined), clearAllCachedAuthTokens: fn(() => undefined),
          onSignInChanged: event(),
        });
      }
    })();
    """#
}
