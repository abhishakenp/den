// thin-host: feature-specific, migrate to plugin (whole file)
import Foundation

/// Stand-ins for extension APIs WebKit doesn't have, so an extension that calls them keeps
/// running instead of stopping at the first `undefined`: `bookmarks` (empty), `history` (pages
/// visited while the extension runs), `sessions` (tabs closed while it runs), `search` (a Google
/// search in a tab) and `storage.session.setAccessLevel` (no-op).
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
  /// Marks the background context, where the shim records visits and closed tabs.
  static let backgroundFlag = "__den/background.js"
  /// Bumped when `source` changes, so installed copies get the new one on their next load.
  static let version = 6

  /// Adds the shim to an unpacked extension. Idempotent; returns whether anything changed.
  /// `validPattern` says whether WebKit takes a match pattern: content script entries lose the
  /// ones it rejects, and an entry left with none is dropped, so one entry WebKit can't read
  /// doesn't leave the extension with a load error.
  @discardableResult
  public static func apply(to root: URL, validPattern: (String) -> Bool = { _ in true }) throws -> Bool {
    let fm = FileManager.default
    let manifestURL = root.appendingPathComponent("manifest.json")
    let data = try Data(contentsOf: manifestURL)
    let clean = data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
    guard var m = try JSONSerialization.jsonObject(with: clean) as? [String: Any] else { throw ExtensionPackageError("manifest.json is not valid JSON") }
    let marker = "// den-shim v\(version)"
    let shimURL = root.appendingPathComponent(script)
    let current = (try? String(contentsOf: shimURL, encoding: .utf8))?.hasPrefix(marker) == true
    var changed = false
    if !current {
      try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
      try (marker + "\n" + source).write(to: shimURL, atomically: true, encoding: .utf8)
      try "globalThis.__denBackground = true;\n".write(to: root.appendingPathComponent(backgroundFlag), atomically: true, encoding: .utf8)
      changed = true
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
      const extCall = (action, method, params = {}) =>
        new Promise((resolve, reject) => {
          api.runtime.sendNativeMessage('__den.ext', {
            ...params, action, method, __ns: api.runtime.id
          }, (r) => {
            if (r && r.error) reject(new Error(r.error));
            else resolve((r && r.result));
          });
        });

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

      // idle, sidePanel, offscreen: answered so start-up code that touches them carries on.
      if (perms.includes('idle')) {
        define('idle', {queryState: fn(() => 'active'), setDetectionInterval: () => {}, getAutoLockDelay: fn(() => 0), onStateChanged: event()});
      }
      if (perms.includes('sidePanel')) {
        define('sidePanel', {
          setOptions: fn(() => undefined), getOptions: fn(() => ({enabled: false})), setPanelBehavior: fn(() => undefined),
          getPanelBehavior: fn(() => ({openPanelOnActionClick: false})),
          open: fn((p) => extCall('sidePanel', 'open', p)),
        });
      }
      if (perms.includes('offscreen')) {
        define('offscreen', {
          createDocument: fn(() => { throw unavailable('Offscreen documents'); }), closeDocument: fn(() => undefined),
          hasDocument: fn(() => false), Reason: {CLIPBOARD: 'CLIPBOARD', DOM_PARSER: 'DOM_PARSER', BLOBS: 'BLOBS', LOCAL_STORAGE: 'LOCAL_STORAGE'},
        });
      }

      // downloads: bridge to den's download system.
      if (perms.includes('downloads')) {
        const dl = (method, p) => extCall('downloads', method, p);
        define('downloads', {
          download: fn((p) => dl('download', p)),
          pause: fn((id) => dl('pause', {id})),
          resume: fn((id) => dl('resume', {id})),
          cancel: fn((id) => dl('cancel', {id})),
          getItem: fn((id) => dl('getItem', {id})),
          getItemIcon: fn((id) => dl('getItemIcon', {id})),
          setShelfEnabled: fn(() => undefined), getShelfEnabled: fn(() => true),
          showDefaultUI: fn(() => undefined), show: fn(() => undefined),
          onCreated: event(), onDownloadRemoving: event(), onDownloadRemoved: event(),
          onDeterminingFilename: event(), onChanged: event(), onError: event(),
        });
      }

      // identity: stub with current user info (den has no user auth).
      if (perms.includes('identity')) {
        const id = (method, p) => extCall('identity', method, p || {});
        define('identity', {
          getProfileEmail: fn(() => Promise.reject(new Error('identity: den has no user authentication'))),
          launchWebAuthFlow: fn((p) => id('launchWebAuthFlow', p)),
          getAuthToken: fn(() => Promise.reject(new Error('identity: not available'))),
          getProfile: fn(() => Promise.resolve({email: 'user@example.com', displayName: 'Den User'})),
          removeAuthToken: fn(() => undefined),
        });
      }

      // bookmarks: local storage per extension namespace.
      if (perms.includes('bookmarks')) {
        const tree = () => [{id: '0', title: '', children: [{id: '1', parentId: '0', title: 'Bookmarks', children: []}]}];
        define('bookmarks', {
          getTree: fn(() => extCall('bookmarks', 'getTree')),
          getSubTree: fn((parentId) => extCall('bookmarks', 'getSubTree', {parentId})),
          get: fn((id) => extCall('bookmarks', 'get', {id}).then(r => r || [])),
          getChildren: fn((parentId) => extCall('bookmarks', 'getChildren', {parentId})),
          getRecent: fn((count = 10) => extCall('bookmarks', 'getRecent', {count})),
          search: fn((q) => extCall('bookmarks', 'search', {query: q || ''})),
          create: fn((p) => extCall('bookmarks', 'create', p)),
          update: fn((id, p) => extCall('bookmarks', 'update', {...p, id})),
          move: fn((id, p) => extCall('bookmarks', 'move', {...p, id})),
          remove: fn((id) => extCall('bookmarks', 'remove', {id})),
          removeTree: fn((id) => extCall('bookmarks', 'remove', {id})),
          onCreated: event(), onRemoved: event(), onChanged: event(), onMoved: event(),
          onChildrenReordered: event(), onImportBegan: event(), onImportEnded: event(),
        });
      }

      // history and sessions: what the extension sees while it runs, kept in its own storage.
      const titles = new Map();
      const HKEY = '__den.history', CKEY = '__den.closed';
      if (perms.includes('history') && api.tabs && api.tabs.onUpdated) {
        const onVisited = event(), onVisitRemoved = event();
        const record = async (url, title) => {
          if (!/^https?:/.test(url)) return;
          const h = await load(HKEY, []);
          const i = h.findIndex((x) => x.url === url);
          const item = i >= 0 ? h.splice(i, 1)[0] : {id: String(Date.now()), url, title: '', visitCount: 0, typedCount: 0};
          item.title = title || item.title;
          item.visitCount += 1;
          item.lastVisitTime = Date.now();
          h.unshift(item);
          if (h.length > 2000) h.length = 2000;
          save(HKEY, h);
          onVisited.fire(item);
        };
        if (inBackground) api.tabs.onUpdated.addListener((id, info, tab) => {
          if (info.status === 'complete' && tab && tab.url) record(tab.url, tab.title);
        });
        const hl = (method, p) => extCall('history', method, p);
        define('history', {
          search: fn((q = {}) => hl('search', q)),
          getVisits: fn(({url}) => hl('getVisits', {url})),
          addUrl: fn(({url, title}) => record(url, title)),
          deleteUrl: fn(async ({url}) => { save(HKEY, (await load(HKEY, [])).filter((x) => x.url !== url)); onVisitRemoved.fire({allHistory: false, urls: [url]}); }),
          deleteRange: fn(async ({startTime, endTime}) => { save(HKEY, (await load(HKEY, [])).filter((x) => x.lastVisitTime < startTime || x.lastVisitTime > endTime)); onVisitRemoved.fire({allHistory: false, urls: []}); }),
          deleteAll: fn(() => { save(HKEY, []); onVisitRemoved.fire({allHistory: true, urls: []}); }),
          onVisited, onVisitRemoved,
        });
      }
      if (perms.includes('sessions') && api.tabs && api.tabs.onRemoved) {
        const onChanged = event();
        if (inBackground && api.tabs.onUpdated) api.tabs.onUpdated.addListener((id, info, tab) => { if (tab && tab.url) titles.set(id, {url: tab.url, title: tab.title || ''}); });
        if (inBackground) api.tabs.onRemoved.addListener(async (id) => {
          const t = titles.get(id);
          titles.delete(id);
          if (!t || !/^https?:/.test(t.url)) return;
          const c = await load(CKEY, []);
          c.unshift({lastModified: Math.floor(Date.now() / 1000), tab: {sessionId: String(Date.now()), url: t.url, title: t.title}});
          if (c.length > 25) c.length = 25;
          save(CKEY, c);
          onChanged.fire();
        });
        define('sessions', {
          MAX_SESSION_RESULTS: 25,
          getRecentlyClosed: fn(async (f = {}) => (await load(CKEY, [])).slice(0, f.maxResults || 25)),
          getDevices: fn(() => []),
          restore: fn(async (sessionId) => {
            const c = await load(CKEY, []);
            const i = sessionId == null ? 0 : c.findIndex((x) => x.tab.sessionId === sessionId);
            if (i < 0 || !c[i]) throw unavailable('That closed tab');
            const [s] = c.splice(i, 1);
            save(CKEY, c);
            onChanged.fire();
            const tab = await api.tabs.create({url: s.tab.url, active: true});
            return {lastModified: s.lastModified, tab};
          }),
          onChanged,
        });
      }

      // search.query: a web search in the current tab, a new tab or a new window.
      if (perms.includes('search') && api.tabs) {
        define('search', {
          query: fn(async ({text, disposition, tabId}) => {
            const url = 'https://www.google.com/search?q=' + encodeURIComponent(text || '');
            if (tabId != null) return void await api.tabs.update(tabId, {url});
            if (disposition === 'NEW_TAB') return void await api.tabs.create({url});
            if (disposition === 'NEW_WINDOW' && api.windows) return void await api.windows.create({url});
            const [t] = await api.tabs.query({active: true, currentWindow: true});
            if (t) await api.tabs.update(t.id, {url}); else await api.tabs.create({url});
          }),
        });
      }
    })();
    """#
}
