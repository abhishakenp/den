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
  static let worker = "__den/worker.js"
  /// Marks the background context, where the shim records visits and closed tabs.
  static let backgroundFlag = "__den/background.js"
  /// Bumped when `source` changes, so installed copies get the new one on their next load.
  static let version = 2

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
      if let sw = bg["service_worker"] as? String, sw != worker {
        let path = sw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if (bg["type"] as? String) == "module" {
          bg["service_worker"] = nil
          bg["scripts"] = [path]
        } else {
          try "importScripts(\"/\(backgroundFlag)\", \"/\(script)\", \"/\(path)\");\n".write(to: root.appendingPathComponent(worker), atomically: true, encoding: .utf8)
          bg["service_worker"] = worker
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

      if (inContent) return;
      const inBackground = g.__denBackground === true;

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
          getPanelBehavior: fn(() => ({openPanelOnActionClick: false})), open: fn(() => { throw unavailable('The side panel'); }),
        });
      }
      if (perms.includes('offscreen')) {
        define('offscreen', {
          createDocument: fn(() => { throw unavailable('Offscreen documents'); }), closeDocument: fn(() => undefined),
          hasDocument: fn(() => false), Reason: {CLIPBOARD: 'CLIPBOARD', DOM_PARSER: 'DOM_PARSER', BLOBS: 'BLOBS', LOCAL_STORAGE: 'LOCAL_STORAGE'},
        });
      }

      // bookmarks: den keeps none an extension can read.
      if (perms.includes('bookmarks')) {
        const tree = () => [{id: '0', title: '', children: [{id: '1', parentId: '0', title: 'Bookmarks', children: []}]}];
        define('bookmarks', {
          getTree: fn(tree), getSubTree: fn(() => []), get: fn(() => []), getChildren: fn(() => []),
          getRecent: fn(() => []), search: fn(() => []),
          create: fn(() => { throw unavailable('Bookmarks'); }), update: fn(() => { throw unavailable('Bookmarks'); }),
          move: fn(() => { throw unavailable('Bookmarks'); }), remove: fn(() => { throw unavailable('Bookmarks'); }),
          removeTree: fn(() => { throw unavailable('Bookmarks'); }),
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
        define('history', {
          search: fn(async (q = {}) => {
            const text = (q.text || '').toLowerCase(), start = q.startTime || 0, end = q.endTime || Infinity;
            const max = q.maxResults == null ? 100 : q.maxResults;
            const h = await load(HKEY, []);
            const out = h.filter((x) => x.lastVisitTime >= start && x.lastVisitTime <= end &&
              (!text || x.url.toLowerCase().includes(text) || (x.title || '').toLowerCase().includes(text)));
            return max > 0 ? out.slice(0, max) : out;
          }),
          getVisits: fn(async ({url}) => (await load(HKEY, [])).filter((x) => x.url === url).map((x) => ({id: x.id, visitId: x.id, visitTime: x.lastVisitTime, transition: 'link'}))),
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
