// den Shields scriptlets: a small engine for the uBlock Origin-style scriptlets that content rules
// can't express (docs/plugin-services.md#shields-plugin-shields). The host runs it at document
// start in the page's own world, in every frame of the sites `scriptlets.json` lists (a YouTube
// embed on any site too), as `(function (denData, denToken) { <this file> })(<scriptlets.json>, "<random>")`.
//
// The data is rules, never code: each rule is [name, ...arguments] (strings, or plain JSON objects
// where noted), and only the names below exist. A newer scriptlets.json (delivered with a plugin
// update or over the air) can change what is pruned, replaced, edited or hidden, but can't run
// anything this file doesn't define. Every rule is wrapped in try/catch: a rule that no longer
// fits the site never breaks the page.
//
// Patterns: "/re/flags" is a regular expression, anything else a plain substring.
//   ["set", "a.b.c", "undefined"|"null"|"true"|"false"|"0"|"''"|"[]"|"{}"]   (uBO set-constant)
//   ["json-prune", "paths", "needles?"]                       JSON.parse results
//   ["json-prune-fetch-response", "paths", "urlPattern"]      fetch() JSON bodies
//   ["json-prune-xhr-response", "paths", "urlPattern"]        XMLHttpRequest JSON bodies
//   ["replace-fetch-response", "pattern", "replacement", "urlPattern"]
//   ["replace-xhr-response", "pattern", "replacement", "urlPattern"]
//   ["edit-outbound-json", {when, merge?, set?, now?, replace?}]   objects about to be JSON.stringify'd
//   ["neutralize-callback", "Promise.prototype.then", "pattern"]  callbacks whose source matches become no-ops
//   ["youtube-recover", {markers, adStats, unplayable, pageType, premium, skip, stallSnackbar, stallChunks, reloadTag}]
//   ["prevent-dom-bypass", "fetch"]   an appended about:blank iframe gets this window's patched method
//   ["remove-node-text", "script", "pattern"]   empties matching inline scripts before they run
//   ["adjust-setTimeout", "pattern", "delay", "factor"]
//   ["hide", "css selector list"]
// Paths follow uBO's json-prune: "a.b" deletes b of a, "[]" / "{}" / "*" walk every element,
// "[-]" removes array elements that contain the rest of the path.
//
// What it removed is counted; `window[denToken]()` returns the count (plus the hidden elements
// on the page), which den adds to the page's blocked count. Nothing else is left on `window`.

'use strict';
const host = location.hostname;
const W = window;
const token = typeof denToken === 'string' && denToken ? denToken : '';

const rules = [];
for (const set of (denData && denData.sets) || []) {
  const hosts = set.hosts || [];
  if (hosts.some(h => host === h || host.endsWith('.' + h))) rules.push(...(set.rules || []));
}
if (!rules.length) return;
let removed = 0;

// Natives, taken before the page can touch them.
const JSONparse = JSON.parse, JSONstringify = JSON.stringify;
const hasOwn = Object.prototype.hasOwnProperty;
const defineProperty = Object.defineProperty, getDesc = Object.getOwnPropertyDescriptor;
const ReflectApply = Reflect.apply;
const NativeResponse = W.Response;
const responseJSON = NativeResponse.prototype.json, responseText = NativeResponse.prototype.text;
const responseClone = NativeResponse.prototype.clone;

const pattern = p => {
  if (typeof p !== 'string' || p === '') return null;
  const m = /^\/(.+)\/([gimsuy]*)$/s.exec(p);
  if (m) { try { return new RegExp(m[1], m[2]); } catch (e) { return null; } }
  return { test: s => s.indexOf(p) !== -1, source: p, plain: true };
};
const matches = (re, s) => { if (!re) return true; if (re.lastIndex) re.lastIndex = 0; return re.test(String(s)); };
const urlOf = a => (typeof a === 'string' ? a : (a && typeof a.url === 'string' ? a.url : String(a)));

// --- json-prune paths ---
/** Follows `keys` from `node`: removes the last key (`remove`) or tells whether it exists. */
const walk = (node, keys, i, remove) => {
  if (node === null || typeof node !== 'object') return false;
  const key = keys[i];
  if (i === keys.length - 1) {
    if (!remove) return hasOwn.call(node, key);
    if (key === '*') {
      const all = Object.keys(node);
      for (const k of all) delete node[k];
      removed += all.length;
      return all.length > 0;
    }
    if (!hasOwn.call(node, key)) return false;
    delete node[key];
    removed++;
    return true;
  }
  let hit = false;
  if (key === '[-]' && Array.isArray(node)) {
    // Drop the elements that contain the rest of the path.
    for (let j = node.length - 1; j >= 0; j--) if (walk(node[j], keys, i + 1, false)) { node.splice(j, 1); hit = true; removed++; }
    return hit;
  }
  if (key === '{-}') {
    for (const k of Object.keys(node)) if (walk(node[k], keys, i + 1, false)) { delete node[k]; hit = true; removed++; }
    return hit;
  }
  if ((key === '[]' && Array.isArray(node)) || key === '{}' || key === '*') {
    for (const k of Object.keys(node)) if (walk(node[k], keys, i + 1, remove)) hit = true;
    return hit;
  }
  return hasOwn.call(node, key) && walk(node[key], keys, i + 1, remove);
};
const has = (obj, path) => walk(obj, path.split('.'), 0, false);
const splitPaths = s => (typeof s === 'string' && s.trim() ? s.trim().split(/ +/) : []);
/** Prunes `obj` in place when every needle path exists; true when something was removed. */
const prune = (obj, paths, needles) => {
  if (typeof obj !== 'object' || obj === null) return false;
  for (const n of needles) if (!has(obj, n)) return false;
  let hit = false;
  for (const p of paths) if (walk(obj, p.split('.'), 0, true)) hit = true;
  return hit;
};

// --- hooks, installed once and shared by every rule of a kind ---
const parsePruners = [], fetchRules = [], xhrRules = [];

let jsonHooked = false;
const hookJSON = () => {
  if (jsonHooked) return;
  jsonHooked = true;
  JSON.parse = new Proxy(JSON.parse, {
    apply(t, self, args) {
      const v = ReflectApply(t, self, args);
      for (const r of parsePruners) { try { prune(v, r.paths, r.needles); } catch (e) {} }
      return v;
    },
  });
};

/** Applies the fetch/xhr rules for `url` to a response body. Returns the new text, or null. */
const rewriteBody = (list, url, text) => {
  let out = text, changed = false, obj;
  for (const r of list) {
    if (!matches(r.url, url)) continue;
    try {
      if (r.kind === 'replace') {
        if (!matches(r.re, out)) continue;
        const re = r.re.plain ? r.re.source : r.re;
        const next = r.re.plain ? out.split(re).join(r.with) : out.replace(re, r.with);
        if (next !== out) { out = next; changed = true; obj = undefined; removed++; }
      } else {
        if (obj === undefined) { try { obj = JSONparse(out); } catch (e) { obj = null; } }
        if (obj && prune(obj, r.paths, [])) { out = JSONstringify(obj); changed = true; }
      }
    } catch (e) {}
  }
  return changed ? out : null;
};

let fetchHooked = false;
const hookFetch = () => {
  if (fetchHooked || typeof W.fetch !== 'function') return;
  fetchHooked = true;
  W.fetch = new Proxy(W.fetch, {
    apply(t, self, args) {
      const p = ReflectApply(t, self, args);
      let url = '';
      try { url = urlOf(args[0]); } catch (e) {}
      if (!fetchRules.some(r => matches(r.url, url))) return p;
      return p.then(res => {
        let copy;
        try { copy = ReflectApply(responseClone, res, []); } catch (e) { return res; }
        return ReflectApply(responseText, copy, []).then(text => {
          const out = rewriteBody(fetchRules, url, text);
          if (out === null) return res;
          const after = new NativeResponse(out, { status: res.status, statusText: res.statusText, headers: res.headers });
          try {
            defineProperty(after, 'url', { value: res.url });
            defineProperty(after, 'redirected', { value: res.redirected });
            defineProperty(after, 'type', { value: res.type });
          } catch (e) {}
          return after;
        }, () => res);
      });
    },
  });
};

let xhrHooked = false;
const hookXHR = () => {
  if (xhrHooked || typeof W.XMLHttpRequest !== 'function') return;
  xhrHooked = true;
  const proto = W.XMLHttpRequest.prototype;
  const urls = new WeakMap(), cache = new WeakMap();
  const open = proto.open;
  proto.open = new Proxy(open, {
    apply(t, self, args) {
      try { const u = urlOf(args[1]); if (xhrRules.some(r => matches(r.url, u))) urls.set(self, u); else urls.delete(self); } catch (e) {}
      cache.delete(self);
      return ReflectApply(t, self, args);
    },
  });
  const wrap = (name) => {
    const d = getDesc(proto, name);
    if (!d || !d.get) return;
    const get = d.get;
    defineProperty(proto, name, {
      configurable: true, enumerable: d.enumerable,
      get: new Proxy(get, {
        apply(t, self, args) {
          const v = ReflectApply(t, self, args);
          const url = urls.get(self);
          if (url === undefined || self.readyState !== 4) return v;
          const c = cache.get(self);
          if (c && c.from === v) return c.to;
          let to = v;
          if (typeof v === 'string') { const out = rewriteBody(xhrRules, url, v); if (out !== null) to = out; }
          else if (v && typeof v === 'object' && !(v instanceof ArrayBuffer) && !(typeof Blob === 'function' && v instanceof Blob) && !(v instanceof Document)) {
            try { const out = rewriteBody(xhrRules, url, JSONstringify(v)); if (out !== null) to = JSONparse(out); } catch (e) {}
          }
          cache.set(self, { from: v, to });
          return to;
        },
      }),
    });
  };
  wrap('response');
  wrap('responseText');
};

// --- set-constant ---
// uBO's set-constant values: fixed constants, small integers and do-nothing functions; never code.
const constants = {
  undefined: () => undefined, null: () => null, true: () => true, false: () => false, "''": () => '', '""': () => '', emptyStr: () => '',
  '[]': () => [], emptyArr: () => [], '{}': () => ({}), emptyObj: () => ({}), yes: () => 'yes', no: () => 'no',
  noopFunc: () => function () {}, trueFunc: () => function () { return true; }, falseFunc: () => function () { return false; },
  throwFunc: () => function () { throw new Error(); }, noopPromiseResolve: () => function () { return Promise.resolve(); },
};
const isConstant = v => Object.prototype.hasOwnProperty.call(constants, v) || /^-?\d{1,5}$/.test(v);
const constant = v => (Object.prototype.hasOwnProperty.call(constants, v) ? constants[v]() : /^-?\d{1,5}$/.test(v) ? parseInt(v, 10) : undefined);
const trapLists = new WeakMap();  // our accessor getters -> the property paths they trap
const setConstant = (chain, raw) => {
  if (!/^[\w$]+(\.[\w$]+)*$/.test(chain) || !isConstant(raw)) return;
  const value = () => constant(raw);
  const trap = (owner, path) => {
    const dot = path.indexOf('.');
    if (dot === -1) {
      const d = getDesc(owner, path);
      if (d && !d.configurable) return;
      if (d && 'value' in d && d.value !== undefined && d.value !== constant(raw)) removed++;
      defineProperty(owner, path, { configurable: true, enumerable: false, get: value, set() {} });
      return;
    }
    const prop = path.slice(0, dot), rest = path.slice(dot + 1);
    const d = getDesc(owner, prop);
    if (d && !d.configurable) { if (owner[prop] instanceof Object) trap(owner[prop], rest); return; }
    const traps = [rest];
    const mine = d && d.get && trapLists.get(d.get);
    if (mine) { mine.push(rest); return void (owner[prop] instanceof Object && trap(owner[prop], rest)); }
    let cur = d ? (d.get ? d.get.call(owner) : d.value) : undefined;
    const get = function () { return cur; };
    trapLists.set(get, traps);
    defineProperty(owner, prop, {
      configurable: true, enumerable: true, get,
      set(v) { cur = v; if (v instanceof Object) for (const r of traps) { try { trap(v, r); } catch (e) {} } },
    });
    if (cur instanceof Object) trap(cur, rest);
  };
  trap(W, chain);
};

// --- the rest ---
const preventDomBypass = (chain) => {
  if (!/^[\w$]+(\.[\w$]+)*$/.test(chain)) return;
  const parts = chain.split('.'), last = parts.pop();
  const owner = w => { let o = w; for (const p of parts) o = o && o[p]; return o; };
  for (const [proto, name] of [[Node.prototype, 'appendChild'], [Node.prototype, 'insertBefore'], [Element.prototype, 'append'], [Element.prototype, 'prepend']]) {
    const f = proto[name];
    if (typeof f !== 'function') continue;
    proto[name] = new Proxy(f, {
      apply(t, self, args) {
        const r = ReflectApply(t, self, args);
        for (const el of args) {
          try {
            if (!(el instanceof HTMLIFrameElement) && !(el instanceof HTMLFrameElement)) continue;
            const cw = el.contentWindow;
            if (!cw || cw.location.href !== 'about:blank') continue;
            const mine = owner(W), theirs = owner(cw);
            if (mine && theirs) theirs[last] = mine[last];
          } catch (e) {}
        }
        return r;
      },
    });
  }
};

/** uBO's trailing "key, value" arguments. */
const varargs = list => { const o = {}; for (let i = 0; i + 1 < list.length; i += 2) o[String(list[i])] = String(list[i + 1]); return o; };
const removeNodeText = (nodeName, pat, extra = []) => {
  const re = pattern(pat);
  if (!re) return;
  const opts = varargs(extra);
  const exclude = opts.excludes ? pattern(opts.excludes) : null;
  const include = opts.includes || opts.condition ? pattern(opts.includes || opts.condition) : null;
  const name = String(nodeName || 'script').toUpperCase();
  const handle = n => {
    if (n.nodeName !== name || n === document.currentScript) return;
    try {
      const t = n.textContent;
      if (!matches(re, t) || (exclude && matches(exclude, t)) || (include && !matches(include, t))) return;
      n.textContent = '';
      removed++;
    } catch (e) {}
  };
  const observer = new MutationObserver(ms => { for (const m of ms) for (const n of m.addedNodes) handle(n); });
  observer.observe(document, { childList: true, subtree: true });
  if (document.documentElement) document.querySelectorAll(name).forEach(handle);
  const stop = () => { for (const m of observer.takeRecords()) for (const n of m.addedNodes) handle(n); observer.disconnect(); };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', stop, { once: true }); else stop();
};

/** uBO's nano-stb / nano-sib: scale a timer's delay when the callback and delay match. */
const adjustTimer = (name, pat, delayArg, factorArg) => {
  const re = pattern(pat);
  const delay = delayArg === '*' ? -1 : parseInt(delayArg, 10) || 1000;
  let f = parseFloat(factorArg);
  f = isFinite(f) ? Math.min(Math.max(f, 0.001), 50) : 0.05;
  W[name] = new Proxy(W[name], {
    apply(t, self, args) {
      try { if ((delay === -1 || args[1] === delay) && matches(re, fnText(args[0]))) args[1] = args[1] * f; } catch (e) {}
      return ReflectApply(t, self, args);
    },
  });
};
const adjustSetTimeout = (pat, delayArg, factorArg) => adjustTimer('setTimeout', pat, delayArg, factorArg);

// --- edit-outbound-json: edits request objects as the page serializes them (uBO's
// trusted-edit-inbound-object on JSON.stringify). Paths are plain dotted keys; "" is the object.
const getPath = (o, path) => { if (path === '') return o; for (const k of path.split('.')) { if (o === null || typeof o !== 'object' || !hasOwn.call(o, k)) return undefined; o = o[k]; } return o; };
const setPath = (o, path, v) => {
  const keys = path.split('.'), last = keys.pop();
  for (const k of keys) { if (o === null || typeof o !== 'object' || !hasOwn.call(o, k)) return false; o = o[k]; }
  if (o === null || typeof o !== 'object') return false;
  o[last] = v;
  return true;
};
const plain = v => (v && typeof v === 'object' ? JSONparse(JSONstringify(v)) : v);
const outboundEdits = [];
const editOutbound = obj => {
  for (const e of outboundEdits) {
    try {
      const ok = e.when.every(([path, op, arg]) => {
        const v = getPath(obj, path);
        switch (op) {
          case 'exists': return v !== undefined;
          case 'equals': return v === arg;
          case 'contains': return typeof v === 'string' && v.includes(String(arg));
          case 'matches': { const re = pattern(String(arg)); return typeof v === 'string' && !!re && matches(re, v); }
          default: return false;
        }
      });
      if (!ok) continue;
      for (const [path, add] of e.merge) { const t = getPath(obj, path); if (t && typeof t === 'object' && add && typeof add === 'object') Object.assign(t, plain(add)); }
      for (const [path, v] of e.set) setPath(obj, path, plain(v));
      for (const path of e.now) setPath(obj, path, String(Date.now()));
      for (const [path, re, repl] of e.replace) {
        const v = getPath(obj, path), r = pattern(String(re));
        if (typeof v === 'string' && r) setPath(obj, path, r.plain ? v.split(r.source).join(String(repl)) : v.replace(r, String(repl)));
      }
    } catch (err) {}
  }
};
let stringifyHooked = false;
const hookStringify = () => {
  if (stringifyHooked) return;
  stringifyHooked = true;
  JSON.stringify = new Proxy(JSON.stringify, {
    apply(t, self, args) {
      const o = args[0];
      if (o && typeof o === 'object' && !Array.isArray(o)) editOutbound(o);
      return ReflectApply(t, self, args);
    },
  });
};
const addOutboundEdit = spec => {
  if (!spec || typeof spec !== 'object' || !Array.isArray(spec.when) || !spec.when.length) return;
  const list = k => (Array.isArray(spec[k]) ? spec[k].filter(x => Array.isArray(x) || typeof x === 'string') : []);
  outboundEdits.push({ when: spec.when.filter(Array.isArray), merge: list('merge'), set: list('set'), now: list('now').filter(x => typeof x === 'string'), replace: list('replace') });
  hookStringify();
};

// --- neutralize-callback: a callback whose source matches becomes a no-op (uBO's quick fix for
// YouTube's `onAbnormalityDetected`, which stops playback when it sees a blocker).
const neutralizeCallback = (chain, pat) => {
  const re = pattern(pat);
  if (!re || chain !== 'Promise.prototype.then') return;
  const seen = new WeakMap();
  const noop = function () {};
  const hit = f => {
    if (typeof f !== 'function') return false;
    let v = seen.get(f);
    if (v === undefined) { v = matches(re, Function.prototype.toString.call(f)); seen.set(f, v); }
    return v;
  };
  Promise.prototype.then = new Proxy(Promise.prototype.then, {
    apply(t, self, args) {
      try { if (hit(args[0])) { args[0] = noop; removed++; } } catch (e) {}
      return ReflectApply(t, self, args);
    },
  });
};

// --- youtube-recover: uBO's YouTube quick fix (quick-fixes.txt, "serverContract"), as engine code
// driven by data. When a logged-in watch page answers with "This content isn't available" (an
// anti-adblock UNPLAYABLE) or stalls with an empty buffer, it tags the client's user agent with the
// next marker (the `edit-outbound-json` rules turn a tagged player request into one YouTube serves
// without stitched ads) and reloads the video where it was. A server-stitched ad that still plays
// ("SSAP, AD" in the player's stats) is skipped by seeking to its end.
const youtubeRecover = o => {
  if (!o || typeof o !== 'object') return;
  const all = Array.isArray(o.markers) ? o.markers.map(String) : [];
  let markers = all.slice(), pending = false, baseUA = null, last = 0, timer = 0;
  const client = () => { try { return W.ytcfg.data_.INNERTUBE_CONTEXT.client; } catch (e) { return null; } };
  const setMarker = m => {
    const c = client();
    if (!c || typeof c.userAgent !== 'string') return;
    if (baseUA === null) baseUA = c.userAgent;
    const pre = (baseUA.match(/Mozilla\/5\.0 \([^)]+/) || [])[0];
    c.userAgent = m && pre ? baseUA.replace(pre, pre + '; ' + m) : baseUA;
  };
  const premium = () => {
    if (!o.premium) return false;
    try { if (W.ytInitialData.topbar.desktopTopbarRenderer.logo.topbarLogoRenderer.iconImage.iconType === o.premium) return true; } catch (e) {}
    const m = document.getElementById('masthead');
    return !!(m && m.getAttribute('logo-type') === o.premium);
  };
  const state = () => {
    const player = document.getElementById('movie_player');
    const call = n => { try { return player && typeof player[n] === 'function' ? player[n]() : undefined; } catch (e) { return undefined; } };
    const ps = call('getPlayerStateObject');
    return { player, response: call('getPlayerResponse'), stats: call('getStatsForNerds'), progress: call('getProgressState'), buffering: !!(ps && ps.isBuffering) };
  };
  const stalled = s => s.buffering && !!s.stats && s.stats.buffer_health_seconds === '0.00 s' && s.stats.resolution === '0x0' && markers.length > 0;
  const noteStall = () => {
    const s = state();
    if (!s.player || !stalled(s)) return;
    try { if (String(s.response.playbackTracking.videostatsPlaybackUrl.baseUrl).includes(o.reloadTag || 'reloadxhr')) markers = markers.slice(1); } catch (e) {}
    pending = true;
  };
  const errorRuns = r => {
    const e = r && r.playabilityStatus && r.playabilityStatus.errorScreen;
    if (!e) return '';
    try {
      const a = e.playerErrorMessageRenderer && e.playerErrorMessageRenderer.subreason && e.playerErrorMessageRenderer.subreason.runs;
      const b = e.playerInterstitialRenderer && e.playerInterstitialRenderer.content && e.playerInterstitialRenderer.content.interstitialViewModel
        && e.playerInterstitialRenderer.content.interstitialViewModel.description && e.playerInterstitialRenderer.content.interstitialViewModel.description.commandRuns;
      return JSONstringify(a || b) || '';
    } catch (err) { return ''; }
  };
  const check = () => {
    const s = state(), p = s.progress, r = s.response;
    if (!s.player || !location.href.includes('/watch?')) { markers = all.slice(); return; }
    const live = !!(r && r.videoDetails && r.videoDetails.isLive);
    const playing = p && p.duration > 0 && (p.loaded < p.duration || p.duration - p.current > 1);
    if (!playing && !live) return;
    const dbg = s.stats && s.stats.debug_info;
    if (o.adStats && typeof dbg === 'string' && dbg.startsWith(o.adStats)) {
      if (p && p.duration > 0 && typeof s.player.seekTo === 'function') { s.player.seekTo(p.duration); removed++; }
      return;
    }
    const id = r && r.videoDetails && r.videoDetails.videoId;
    const start = (r && r.playerConfig && r.playerConfig.playbackStartConfig && r.playerConfig.playbackStartConfig.startSeconds) || 0;
    const load = () => { if (id && typeof s.player.loadVideoById === 'function') s.player.loadVideoById(id, start); };
    const status = r && r.playabilityStatus;
    const runs = errorRuns(r);
    const captcha = !!(status && status.errorScreen && status.errorScreen.playerErrorMessageRenderer && status.errorScreen.playerErrorMessageRenderer.playerCaptchaViewModel);
    if (status && status.status === 'UNPLAYABLE' && !captcha && o.pageType && o.unplayable && runs.includes(o.pageType) && runs.includes(o.unplayable)) {
      markers = markers.slice(1);
      setMarker(markers[0] || '');
      pending = false;
      load();
    } else if (markers.length === 0) {
      pending = false;
      setMarker('');
    } else if (stalled(s) && pending) {
      setMarker(markers[0]);
      pending = false;
      load();
    } else if (!pending && p && p.current - start < 5 && location.href.includes('&list=') && typeof s.player.getPlaylistId === 'function' && s.player.getPlaylistId() === null) {
      // A reloaded video loses its playlist panel: put it back.
      const m = document.querySelector('yt-playlist-manager');
      const data = m && typeof m.getPlaylistData === 'function' ? m.getPlaylistData() : null;
      if (data) {
        if (typeof m.setPlaylistData === 'function') m.setPlaylistData(data);
        if (typeof m.setPlayerPlaybackControlData === 'function') m.setPlayerPlaybackControlData({ playlistPanelRenderer: data });
      }
    }
  };
  // At most every 100 ms (the page mutates constantly), with a trailing check.
  const schedule = () => {
    const now = performance.now();
    if (now - last >= 100) { last = now; try { check(); } catch (e) {} return; }
    if (!timer) timer = setTimeout(() => { timer = 0; last = performance.now(); try { check(); } catch (e) {} }, 100);
  };
  const begin = () => {
    if (premium() || (o.skip || []).some(x => location.href.startsWith(String(x)))) return;
    schedule();
    new MutationObserver(schedule).observe(document, { childList: true, subtree: true });
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', begin, { once: true }); else begin();
  // Stall signals the player gives before its buffer runs dry.
  if (o.stallSnackbar) {
    Map.prototype.has = new Proxy(Map.prototype.has, {
      apply(t, self, args) { if (args[0] === o.stallSnackbar && !pending) { try { noteStall(); } catch (e) {} } return ReflectApply(t, self, args); },
    });
  }
  const chunks = Array.isArray(o.stallChunks) ? o.stallChunks.map(Number) : [];
  if (chunks.length) {
    Array.prototype.push = new Proxy(Array.prototype.push, {
      apply(t, self, args) {
        const x = args[0];
        if (x instanceof Uint8Array && x.buffer && x.buffer.byteLength === x.length && chunks.includes(x.length)) { try { noteStall(); } catch (e) {} }
        return ReflectApply(t, self, args);
      },
    });
  }
};

// --- uBO's common site scriptlets (anti-adblock walls, pop-unders), same names and arguments.
/** A needle: "" matches all, "!x" negates, "/re/" is a regex, else a substring. */
const needle = raw => {
  raw = String(raw || '');
  const not = raw.startsWith('!');
  const re = pattern(not ? raw.slice(1) : raw);
  return s => (re ? matches(re, s) : true) !== not;
};
const fnText = f => { try { return typeof f === 'function' ? Function.prototype.toString.call(f) : String(f); } catch (e) { return ''; } };
/** uBO's delay ranges: "1000", "1000-", "-1000", "500-2000", "!…"; "" matches any. */
const range = raw => {
  raw = String(raw || '');
  const not = raw.startsWith('!');
  const s = not ? raw.slice(1) : raw;
  if (s === '') return () => true;
  const pos = s.indexOf('-');
  const min = pos !== 0 ? parseInt(s, 10) || 0 : undefined;
  const max = pos === -1 ? min : (parseInt(s.slice(pos + 1), 10) || Number.MAX_SAFE_INTEGER);
  return v => { const n = Number(v) || 0; return ((min === undefined || n >= min) && (max === undefined || n <= max)) !== not; };
};

/** Traps a property chain on window: `hooks.get/set` run on the leaf (uBO's trapPropertyFn). */
const trapChain = (chain, hooks) => {
  if (!/^[\w$]+(\.[\w$]+)*$/.test(chain)) return;
  const trap = (owner, path) => {
    const dot = path.indexOf('.');
    if (dot === -1) {
      const d = getDesc(owner, path);
      if (d && !d.configurable) return;
      let cur = d ? (d.get ? d.get.call(owner) : d.value) : owner[path];  // an inherited method too
      defineProperty(owner, path, {
        configurable: true,
        get() { if (hooks.get) hooks.get(); return cur; },
        set(v) { if (hooks.set) hooks.set(v); cur = v; },
      });
      return;
    }
    const prop = path.slice(0, dot), rest = path.slice(dot + 1);
    const v = owner[prop];
    if (v instanceof Object) return trap(v, rest);
    const d = getDesc(owner, prop);
    if (d && !d.configurable) return;
    let cur = v;
    defineProperty(owner, prop, {
      configurable: true,
      get() { return cur; },
      set(nv) { cur = nv; if (nv instanceof Object) { try { trap(nv, rest); } catch (e) {} } },
    });
  };
  trap(W, chain);
};
const abort = () => { removed++; throw new ReferenceError(Math.random().toString(36).slice(2)); };
const abortOnRead = chain => trapChain(chain, { get: abort });
const abortOnWrite = chain => trapChain(chain, { set: abort });
const abortCurrentScript = (chain, needleRaw, contextRaw) => {
  const text = needle(needleRaw), ctx = needle(contextRaw);
  const textOf = W.Node && getDesc(Node.prototype, 'textContent').get;
  const check = () => {
    const e = document.currentScript;
    if (!(e instanceof HTMLScriptElement)) return;
    if (contextRaw && !ctx(e.src)) return;
    let t = '';
    try { t = textOf.call(e); } catch (err) {}
    if (!t.trim() && e.src.startsWith('data:')) { try { const m = /^data:([^,]*),(.+)$/.exec(e.src.trim()); t = m[1].endsWith(';base64') ? atob(m[2]) : decodeURIComponent(m[2]); } catch (err) {} }
    if (text(t)) abort();
  };
  trapChain(chain, { get: check, set: check });
};
const preventTimer = (name, needleRaw, delayRaw) => {
  const text = needle(needleRaw), delay = range(delayRaw);
  if (!needleRaw && !delayRaw) return;
  W[name] = new Proxy(W[name], {
    apply(t, self, args) {
      try { if (text(fnText(args[0])) && delay(args[1])) { args[0] = function () {}; removed++; } } catch (e) {}
      return ReflectApply(t, self, args);
    },
  });
};
const preventListener = (typeRaw, needleRaw) => {
  if (!typeRaw && !needleRaw) return;
  const typeRe = typeRaw ? (pattern(typeRaw) && /^\/.+\/[a-z]*$/s.test(typeRaw) ? pattern(typeRaw) : { test: s => s === typeRaw }) : null;
  const text = needle(needleRaw);
  EventTarget.prototype.addEventListener = new Proxy(EventTarget.prototype.addEventListener, {
    apply(t, self, args) {
      try {
        const h = args[1];
        const src = typeof h === 'function' ? fnText(h) : (h && typeof h.handleEvent === 'function' ? fnText(h.handleEvent) : String(h));
        if ((!typeRe || matches(typeRe, String(args[0]))) && text(src)) { args[1] = function () {}; removed++; }
      } catch (e) {}
      return ReflectApply(t, self, args);
    },
  });
};
const noWindowOpen = (needleRaw, delayRaw, decoy) => {
  const text = needle(needleRaw);
  W.open = new Proxy(W.open, {
    apply(t, self, args) {
      if (!text(String(args[0] || ''))) return ReflectApply(t, self, args);
      removed++;
      if (decoy) {
        // A stand-in window object the page can poke at without opening anything.
        return new Proxy({}, { get: (o, k) => (k === 'closed' ? false : typeof k === 'string' && k in W ? (typeof W[k] === 'function' ? function () {} : undefined) : undefined), set: () => true });
      }
      return null;
    },
  });
};
const noFetch = propsRaw => {
  const props = String(propsRaw || '').trim();
  if (!props) return;
  const tests = props.split(/\s+/).map(p => { const i = p.indexOf(':'); return i > 0 && /^[a-z]+$/i.test(p.slice(0, i)) ? [p.slice(0, i), needle(p.slice(i + 1))] : ['url', needle(p)]; });
  W.fetch = new Proxy(W.fetch, {
    apply(t, self, args) {
      try {
        const a = args[0], o = args[1] || {};
        const details = { url: urlOf(a), method: String((o.method || (a && a.method) || 'GET')).toUpperCase() };
        if (tests.every(([k, f]) => k in details && f(details[k]))) { removed++; return Promise.resolve(new NativeResponse('', { status: 200, statusText: 'OK' })); }
      } catch (e) {}
      return ReflectApply(t, self, args);
    },
  });
};
const noXHR = propsRaw => {
  const props = String(propsRaw || '').trim();
  if (!props) return;
  const tests = props.split(/\s+/).map(p => { const i = p.indexOf(':'); return i > 0 && /^[a-z]+$/i.test(p.slice(0, i)) ? [p.slice(0, i), needle(p.slice(i + 1))] : ['url', needle(p)]; });
  const blocked = new WeakSet();
  const proto = W.XMLHttpRequest.prototype;
  proto.open = new Proxy(proto.open, {
    apply(t, self, args) {
      try { const details = { method: String(args[0]).toUpperCase(), url: urlOf(args[1]) }; if (tests.every(([k, f]) => k in details && f(details[k]))) blocked.add(self); else blocked.delete(self); } catch (e) {}
      return ReflectApply(t, self, args);
    },
  });
  proto.send = new Proxy(proto.send, {
    apply(t, self, args) {
      if (!blocked.has(self)) return ReflectApply(t, self, args);
      removed++;
      // Answer with an empty 200, as if the server sent nothing.
      try {
        for (const [k, v] of [['readyState', 4], ['status', 200], ['statusText', 'OK'], ['responseText', ''], ['response', '']]) defineProperty(self, k, { value: v, configurable: true });
        setTimeout(() => { for (const e of ['readystatechange', 'load', 'loadend']) self.dispatchEvent(new Event(e)); }, 1);
      } catch (e) {}
    },
  });
};
const noWebRTC = () => {
  const Real = W.RTCPeerConnection;
  if (typeof Real !== 'function') return;
  const Fake = function () { removed++; };
  Fake.prototype = { close() {}, createDataChannel() { return {}; }, createOffer() { return Promise.resolve({}); }, setLocalDescription() { return Promise.resolve(); }, addEventListener() {} };
  W.RTCPeerConnection = Fake;
  if (W.webkitRTCPeerConnection) W.webkitRTCPeerConnection = Fake;
};
/** Stubs for FuckAdBlock / BlockAdBlock: present, and never detecting anything. */
const noAdblockDetector = () => {
  const Stub = function () {};
  Stub.prototype = { check() { return true; }, clearEvent() {}, emitEvent() { return this; }, on(d, f) { if (!d && typeof f === 'function') setTimeout(f, 1); return this; },
    onDetected() { return this; }, onNotDetected(f) { if (typeof f === 'function') setTimeout(f, 1); return this; }, setOption() { return this; } };
  for (const n of ['FuckAdBlock', 'BlockAdBlock', 'SniffAdBlock']) { try { defineProperty(W, n, { value: Stub }); } catch (e) {} }
  for (const n of ['fuckAdBlock', 'blockAdBlock', 'sniffAdBlock']) { try { defineProperty(W, n, { value: new Stub() }); } catch (e) {} }
};
const noEval = needleRaw => {
  const text = needle(needleRaw);
  W.eval = new Proxy(W.eval, { apply(t, self, args) { if (text(String(args[0]))) { removed++; return undefined; } return ReflectApply(t, self, args); } });
};
/** remove-attr / remove-class on matching elements, now and as the page adds them. */
const removeFrom = (kind, namesRaw, selectorRaw) => {
  const names = String(namesRaw || '').split('|').map(s => s.trim()).filter(Boolean);
  if (!names.length) return;
  const selector = String(selectorRaw || '') || (kind === 'attr' ? names.map(n => '[' + CSS.escape(n) + ']').join(',') : names.map(n => '.' + CSS.escape(n)).join(','));
  const run = () => {
    let els = [];
    try { els = document.querySelectorAll(selector); } catch (e) { return; }
    for (const el of els) for (const n of names) {
      if (kind === 'attr' && el.hasAttribute(n)) { el.removeAttribute(n); removed++; }
      if (kind === 'class' && el.classList.contains(n)) { el.classList.remove(n); removed++; }
    }
  };
  let pending = false;
  const later = () => { if (pending) return; pending = true; requestAnimationFrame(() => { pending = false; run(); }); };
  const start = () => { run(); new MutationObserver(later).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: kind === 'class' ? ['class'] : names }); };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once: true }); else start();
};

const hidden = [];
const hide = () => {
  if (!hidden.length) return;
  try {
    const sheet = new CSSStyleSheet();
    // One rule per selector list: a selector WebKit doesn't know drops only its own rule.
    for (const sel of hidden) { try { sheet.insertRule(sel + ' { display: none !important; }', sheet.cssRules.length); } catch (e) {} }
    const adopt = () => {
      const list = document.adoptedStyleSheets;
      if (!list.includes(sheet)) document.adoptedStyleSheets = [...list, sheet];
    };
    adopt();
    document.addEventListener('DOMContentLoaded', adopt, { once: true });
  } catch (e) {}
};

for (const rule of rules) {
  if (!Array.isArray(rule)) continue;
  const [name, a = '', b = '', c = ''] = rule.map(x => (x == null ? '' : typeof x === 'object' ? '' : String(x)));
  const spec = rule[1];
  try {
    switch (name) {
      case 'edit-outbound-json': addOutboundEdit(spec); break;
      case 'neutralize-callback': neutralizeCallback(a, b); break;
      case 'youtube-recover': youtubeRecover(spec); break;
      case 'set': setConstant(a, b); break;
      case 'json-prune': parsePruners.push({ paths: splitPaths(a), needles: splitPaths(b) }); hookJSON(); break;
      case 'json-prune-fetch-response': fetchRules.push({ kind: 'prune', paths: splitPaths(a), url: pattern(b) }); hookFetch(); break;
      case 'json-prune-xhr-response': xhrRules.push({ kind: 'prune', paths: splitPaths(a), url: pattern(b) }); hookXHR(); break;
      case 'replace-fetch-response': if (pattern(a)) { fetchRules.push({ kind: 'replace', re: pattern(a), with: b, url: pattern(c) }); hookFetch(); } break;
      case 'replace-xhr-response': if (pattern(a)) { xhrRules.push({ kind: 'replace', re: pattern(a), with: b, url: pattern(c) }); hookXHR(); } break;
      case 'prevent-dom-bypass': preventDomBypass(a); break;
      case 'remove-node-text': removeNodeText(a, b, rule.slice(3)); break;
      case 'adjust-setTimeout': adjustSetTimeout(a, b, c); break;
      case 'hide': if (a.trim() && !/[{}]/.test(a)) hidden.push(a); break;
      case 'abort-on-property-read': case 'aopr': abortOnRead(a); break;
      case 'abort-on-property-write': case 'aopw': abortOnWrite(a); break;
      case 'abort-current-script': case 'acs': case 'acis': abortCurrentScript(a, b, c); break;
      case 'no-setTimeout-if': case 'nostif': case 'prevent-setTimeout': preventTimer('setTimeout', a, b); break;
      case 'no-setInterval-if': case 'nosiif': case 'prevent-setInterval': preventTimer('setInterval', a, b); break;
      case 'addEventListener-defuser': case 'aeld': case 'prevent-addEventListener': preventListener(a, b); break;
      case 'no-window-open-if': case 'nowoif': case 'prevent-window-open': noWindowOpen(a, b, c); break;
      case 'no-fetch-if': case 'prevent-fetch': noFetch(a); break;
      case 'no-xhr-if': case 'prevent-xhr': noXHR(a); break;
      case 'nowebrtc': noWebRTC(); break;
      case 'nofab': case 'nobab': case 'fuckadblock.js-3.2.0': noAdblockDetector(); break;
      case 'noeval': noEval(''); break;
      case 'noeval-if': noEval(a); break;
      case 'remove-attr': case 'ra': removeFrom('attr', a, b); break;
      case 'remove-class': case 'rc': removeFrom('class', a, b); break;
      case 'adjust-setInterval': case 'nano-sib': adjustTimer('setInterval', a, b, c); break;
      case 'nano-stb': adjustTimer('setTimeout', a, b, c); break;
      default: break;
    }
  } catch (e) {}
}
hide();

// The count den reads (main frame): what was removed, plus elements the hide rules match now.
if (token) {
  const hiddenNow = () => { if (!hidden.length) return 0; let n = 0; for (const s of hidden) { try { n += document.querySelectorAll(s).length; } catch (e) {} } return n; };
  // Another page script (the other data set) may have counted already: report the sum.
  const before = typeof W[token] === 'function' ? W[token] : () => 0;
  try { defineProperty(W, token, { value: () => before() + removed + hiddenNow(), enumerable: false, configurable: true }); } catch (e) {}
}
