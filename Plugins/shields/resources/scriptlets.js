// den Shields scriptlets: a small engine for the uBlock Origin-style scriptlets that content rules
// can't express (docs/plugin-services.md#shields-plugin-shields). The host runs it at document
// start in the page's own world, in every frame, only on sites `scriptlets.json` lists, as
// `(function (denData) { <this file> })(<scriptlets.json>)`.
//
// The data is rules, never code: each rule is [name, ...string arguments], and only the names
// below exist. A newer scriptlets.json (delivered with a plugin update or over the air) can
// change what is pruned, replaced or hidden, but can't run anything this file doesn't define.
// Every rule is wrapped in try/catch: a rule that no longer fits the site never breaks the page.
//
// Patterns: "/re/flags" is a regular expression, anything else a plain substring.
//   ["set", "a.b.c", "undefined"|"null"|"true"|"false"|"0"|"''"|"[]"|"{}"]   (uBO set-constant)
//   ["json-prune", "paths", "needles?"]                       JSON.parse results
//   ["json-prune-fetch-response", "paths", "urlPattern"]      fetch() JSON bodies
//   ["json-prune-xhr-response", "paths", "urlPattern"]        XMLHttpRequest JSON bodies
//   ["replace-fetch-response", "pattern", "replacement", "urlPattern"]
//   ["replace-xhr-response", "pattern", "replacement", "urlPattern"]
//   ["prevent-dom-bypass", "fetch"]   an appended about:blank iframe gets this window's patched method
//   ["remove-node-text", "script", "pattern"]   empties matching inline scripts before they run
//   ["adjust-setTimeout", "pattern", "delay", "factor"]
//   ["hide", "css selector list"]
// Paths follow uBO's json-prune: "a.b" deletes b of a, "[]" / "{}" / "*" walk every element,
// "[-]" removes array elements that contain the rest of the path.

'use strict';
const host = location.hostname;
const W = window;
if (W.__denScriptlets) return;
try { Object.defineProperty(W, '__denScriptlets', { value: true }); } catch (e) { return; }

const rules = [];
for (const set of (denData && denData.sets) || []) {
  const hosts = set.hosts || [];
  if (hosts.some(h => host === h || host.endsWith('.' + h))) rules.push(...(set.rules || []));
}
if (!rules.length) return;

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
      return all.length > 0;
    }
    if (!hasOwn.call(node, key)) return false;
    delete node[key];
    return true;
  }
  let hit = false;
  if (key === '[-]' && Array.isArray(node)) {
    // Drop the elements that contain the rest of the path.
    for (let j = node.length - 1; j >= 0; j--) if (walk(node[j], keys, i + 1, false)) { node.splice(j, 1); hit = true; }
    return hit;
  }
  if (key === '{-}') {
    for (const k of Object.keys(node)) if (walk(node[k], keys, i + 1, false)) { delete node[k]; hit = true; }
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
        if (next !== out) { out = next; changed = true; obj = undefined; }
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
const constant = v => ({ undefined: undefined, null: null, true: true, false: false, '0': 0, '1': 1, "''": '', '""': '', '[]': [], '{}': {} })[v];
const setConstant = (chain, raw) => {
  if (!/^[\w$]+(\.[\w$]+)*$/.test(chain) || !(raw in { undefined: 1, null: 1, true: 1, false: 1, '0': 1, '1': 1, "''": 1, '""': 1, '[]': 1, '{}': 1 })) return;
  const value = () => constant(raw);
  const trap = (owner, path) => {
    const dot = path.indexOf('.');
    if (dot === -1) {
      const d = getDesc(owner, path);
      if (d && !d.configurable) return;
      defineProperty(owner, path, { configurable: true, enumerable: false, get: value, set() {} });
      return;
    }
    const prop = path.slice(0, dot), rest = path.slice(dot + 1);
    const d = getDesc(owner, prop);
    if (d && !d.configurable) { if (owner[prop] instanceof Object) trap(owner[prop], rest); return; }
    const traps = [rest];
    if (d && d.get && d.get.__denTraps) { d.get.__denTraps.push(rest); return void (owner[prop] instanceof Object && trap(owner[prop], rest)); }
    let cur = d ? (d.get ? d.get.call(owner) : d.value) : undefined;
    const get = function () { return cur; };
    defineProperty(get, '__denTraps', { value: traps });
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

const removeNodeText = (nodeName, pat) => {
  const re = pattern(pat);
  if (!re) return;
  const name = String(nodeName || 'script').toUpperCase();
  const handle = n => {
    if (n.nodeName !== name || n === document.currentScript) return;
    try { if (matches(re, n.textContent)) n.textContent = ''; } catch (e) {}
  };
  const observer = new MutationObserver(ms => { for (const m of ms) for (const n of m.addedNodes) handle(n); });
  observer.observe(document, { childList: true, subtree: true });
  if (document.documentElement) document.querySelectorAll(name).forEach(handle);
  const stop = () => { for (const m of observer.takeRecords()) for (const n of m.addedNodes) handle(n); observer.disconnect(); };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', stop, { once: true }); else stop();
};

const adjustSetTimeout = (pat, delayArg, factorArg) => {
  const re = pattern(pat);
  const delay = delayArg === '*' ? -1 : parseInt(delayArg, 10) || 1000;
  let f = parseFloat(factorArg);
  f = isFinite(f) ? Math.min(Math.max(f, 0.001), 50) : 0.05;
  W.setTimeout = new Proxy(W.setTimeout, {
    apply(t, self, args) {
      try { if ((delay === -1 || args[1] === delay) && matches(re, String(args[0]))) args[1] = args[1] * f; } catch (e) {}
      return ReflectApply(t, self, args);
    },
  });
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
  const [name, a = '', b = '', c = ''] = rule.map(x => (x == null ? '' : String(x)));
  try {
    switch (name) {
      case 'set': setConstant(a, b); break;
      case 'json-prune': parsePruners.push({ paths: splitPaths(a), needles: splitPaths(b) }); hookJSON(); break;
      case 'json-prune-fetch-response': fetchRules.push({ kind: 'prune', paths: splitPaths(a), url: pattern(b) }); hookFetch(); break;
      case 'json-prune-xhr-response': xhrRules.push({ kind: 'prune', paths: splitPaths(a), url: pattern(b) }); hookXHR(); break;
      case 'replace-fetch-response': if (pattern(a)) { fetchRules.push({ kind: 'replace', re: pattern(a), with: b, url: pattern(c) }); hookFetch(); } break;
      case 'replace-xhr-response': if (pattern(a)) { xhrRules.push({ kind: 'replace', re: pattern(a), with: b, url: pattern(c) }); hookXHR(); } break;
      case 'prevent-dom-bypass': preventDomBypass(a); break;
      case 'remove-node-text': removeNodeText(a, b); break;
      case 'adjust-setTimeout': adjustSetTimeout(a, b, c); break;
      case 'hide': if (a.trim() && !/[{}]/.test(a)) hidden.push(a); break;
      default: break;
    }
  } catch (e) {}
}
hide();
