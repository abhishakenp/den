import WebKit

/// The page-side half of den's media and discard bookkeeping. One user script, injected at
/// document start into every frame, in den's own isolated content world (`den`): the page can't
/// see or tamper with it, but it shares the DOM, so it hears the media and input events.
///
/// It posts `denMedia` messages only when something changes (never on a timer):
///   {k: "s", a, p, d, pip, v, n}  state: a = audible media playing, p = any media playing,
///                              d = unsaved form input, pip = system PiP active,
///                              v = the frame's main playing video (or the mini player's video),
///                              n = now playing: the last media element that played audibly, with
///                              the page's Media Session info {title, artist, album, art, paused,
///                              dur, video, acts} (acts = the page's Media Session action handlers)
///   {k: "t", t, dur, paused, muted, vol, rate, cc}  playback, only while the mini player shows this
///                              frame's video: on timeupdate (≤ 4/s) and on play/pause/seek/volume
/// and exposes `window.__denMedia` (in the `den` world only) for the host: `isolate(on)`,
/// `cmd(action, value)`, `act(action, value)` (the now-playing element), `pip()`, `exitPip()`, `live(on)`.
///
/// `sessionHook` is the only page-world part: it remembers the page's Media Session action
/// handlers (WebKit has no way to call them from outside) and tells the den world when they or
/// the metadata change, through DOM events that carry strings only.
@MainActor
enum PageScripts {
  static let world = WKContentWorld.world(name: "den")
  static let handler = "denMedia"

  static let media = #"""
(() => {
  if (window.__denMedia) return;
  const H = webkit.messageHandlers.denMedia;
  const post = m => { try { H.postMessage(m) } catch (e) {} };
  const edited = new Set();
  let last = '', live = false, lastTick = 0, timer = 0, target = null;
  // Now playing: the last element that played audibly (`cur`), unless den stopped it.
  let cur = null, stopped = null, acts = [];
  const fin = d => isFinite(d) ? d : (d === Infinity ? -1 : 0);
  const isMedia = m => !!m && (m.tagName === 'VIDEO' || m.tagName === 'AUDIO');
  const tracks = v => { const out = []; try { for (const t of v.textTracks) if (t.kind === 'subtitles' || t.kind === 'captions') out.push(t); } catch (e) {} return out; };
  const cc = v => { const ts = tracks(v); return ts.length ? (ts.some(t => t.mode === 'showing') ? 2 : 1) : 0; };
  const artwork = md => {
    let src = '', bw = -1;
    try { for (const a of md.artwork || []) { const w = parseInt(String(a.sizes || '').split(/[x ]/i)[0], 10) || 0; if (w > bw) { bw = w; src = a.src; } } } catch (e) {}
    try { src = src ? new URL(src, location.href).href : ''; } catch (e) { src = ''; }
    return /^https?:/.test(src) || (/^data:image\//.test(src) && src.length < 200000) ? src : '';
  };
  const nowInfo = () => {
    const m = cur;
    if (!m || !m.isConnected || m === stopped || !(m.currentSrc || m.src || m.srcObject)) return null;
    let md = null;
    try { md = navigator.mediaSession && navigator.mediaSession.metadata; } catch (e) {}
    const str = (x, n) => String(x || '').slice(0, n);
    return { title: str(md && md.title || document.title, 200), artist: str(md && md.artist, 200), album: str(md && md.album, 200),
             art: md ? artwork(md) : '', paused: m.paused || m.ended, dur: fin(m.duration), video: m.tagName === 'VIDEO', acts };
  };
  const best = () => {
    let b = null, ba = 0;
    for (const v of document.querySelectorAll('video')) {
      if (v.paused || v.ended) continue;
      const r = v.getBoundingClientRect(), a = r.width * r.height;
      if (a >= ba) { ba = a; b = v; }
    }
    return b;
  };
  const info = v => {
    const r = v.getBoundingClientRect();
    return { t: v.currentTime, dur: fin(v.duration), paused: v.paused, muted: v.muted, vol: v.volume, rate: v.playbackRate,
             vw: v.videoWidth, vh: v.videoHeight, cw: Math.round(r.width), ch: Math.round(r.height),
             src: String(v.currentSrc || v.src || '').slice(0, 300), noPip: !!v.disablePictureInPicture, cc: cc(v) };
  };
  // Unsaved input: an edited field whose value differs from what the page loaded with.
  const dirty = () => {
    for (const el of edited) {
      if (!el.isConnected) { edited.delete(el); continue; }
      if (el.isContentEditable) { if (el.textContent.trim()) return true; continue; }
      const ty = String(el.type || '').toLowerCase();
      if (ty === 'checkbox' || ty === 'radio') { if (el.checked !== el.defaultChecked) return true; continue; }
      if (el.tagName === 'SELECT') { for (const o of el.options) if (o.selected !== o.defaultSelected) return true; continue; }
      if (ty === 'password' || ty === 'hidden' || ty === 'button' || ty === 'submit') continue;
      if ('value' in el && el.value !== el.defaultValue && String(el.value).trim()) return true;
    }
    return false;
  };
  const state = () => {
    timer = 0;
    let a = false, p = false;
    for (const m of document.querySelectorAll('video,audio')) {
      if (m.paused || m.ended) continue;
      p = true;
      if (!m.muted && m.volume > 0) a = true;
    }
    const v = target && target.isConnected ? target : best();
    const s = { k: 's', a, p, d: dirty(), pip: !!document.pictureInPictureElement, v: v && (!v.paused || v === target) ? info(v) : null, n: nowInfo() };
    const key = JSON.stringify(s, (k, x) => k === 't' ? undefined : x);
    if (key !== last) { last = key; post(s); }
  };
  const soon = () => { if (!timer) timer = setTimeout(state, 50); };
  const tick = force => {
    const v = target, now = Date.now();
    if (!v || (!force && now - lastTick < 250)) return;
    lastTick = now;
    post({ k: 't', t: v.currentTime, dur: fin(v.duration), paused: v.paused, muted: v.muted, vol: v.volume, rate: v.playbackRate, cc: cc(v) });
  };
  // An element that plays (or is unmuted while playing) with sound becomes the now-playing one.
  const follow = ev => {
    const m = ev.target;
    if (!isMedia(m) || m.paused || m.muted || !(m.volume > 0)) return;
    if (ev.type === 'play' || ev.type === 'playing') stopped = null;
    cur = m;
  };
  for (const e of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied', 'ratechange', 'durationchange', 'loadedmetadata',
                   'seeked', 'enterpictureinpicture', 'leavepictureinpicture']) {
    document.addEventListener(e, ev => { follow(ev); if (live && ev.target === target) tick(true); soon(); }, true);
  }
  // Media Session handlers or metadata changed in the page (sessionHook, page world).
  document.addEventListener('__denms', ev => { try { const a = JSON.parse(String(ev.detail || '[]')); if (Array.isArray(a)) acts = a.map(String).slice(0, 16); } catch (e) {} soon(); }, true);
  const fire = a => { try { document.dispatchEvent(new CustomEvent('__denmsdo', { detail: a })); } catch (e) {} return true; };
  document.addEventListener('timeupdate', ev => { if (live && ev.target === target) tick(false); }, true);
  document.addEventListener('input', ev => { if (ev.target && ev.target.nodeType === 1) { edited.add(ev.target); soon(); } }, true);
  document.addEventListener('submit', () => { edited.clear(); soon(); }, true);
  document.addEventListener('reset', () => { edited.clear(); soon(); }, true);
  // Fresh numbers at the moment the tab leaves the screen (the discard check reads them later).
  document.addEventListener('visibilitychange', state, true);
  window.addEventListener('pagehide', () => { edited.clear(); last = ''; post({ k: 's', a: false, p: false, d: false, pip: false, v: null }); }, true);

  // thin-host: feature-specific, migrate to plugin (isolation CSS belongs to the mini player plugin)
  // Mini player isolation: the video (or, from a parent frame, the iframe holding it) fills the
  // viewport on black, everything else is invisible. Layout is untouched, so undoing it is exact.
  const CSS = 'html.den-mini,html.den-mini body{overflow:hidden!important;background:#000!important}' +
    'html.den-mini body *{visibility:hidden!important;pointer-events:none!important}' +
    'html.den-mini [data-den-mini-anc]{transform:none!important;filter:none!important;perspective:none!important;contain:none!important;' +
    'will-change:auto!important;backdrop-filter:none!important;clip-path:none!important;mask:none!important;content-visibility:visible!important}' +
    'html.den-mini [data-den-mini]{position:fixed!important;inset:0!important;left:0!important;top:0!important;width:100vw!important;height:100vh!important;' +
    'max-width:none!important;max-height:none!important;min-width:0!important;min-height:0!important;margin:0!important;padding:0!important;border:0!important;' +
    'transform:none!important;object-fit:contain!important;background:#000!important;z-index:2147483647!important;visibility:visible!important;opacity:1!important}';
  const mark = (el, on) => {
    const root = document.documentElement;
    let st = document.getElementById('den-mini-style');
    document.querySelectorAll('[data-den-mini],[data-den-mini-anc]').forEach(n => { n.removeAttribute('data-den-mini'); n.removeAttribute('data-den-mini-anc'); });
    if (!on || !el) { root.classList.remove('den-mini'); if (st) st.remove(); return; }
    if (!st) { st = document.createElement('style'); st.id = 'den-mini-style'; st.textContent = CSS; (document.head || root).appendChild(st); }
    el.setAttribute('data-den-mini', '');
    for (let n = el.parentElement; n && n !== root; n = n.parentElement) n.setAttribute('data-den-mini-anc', '');
    root.classList.add('den-mini');
  };
  const up = on => { try { if (window.parent !== window) window.parent.postMessage({ __denMini: on ? 1 : 0 }, '*'); } catch (e) {} };
  window.addEventListener('message', e => {
    const m = e.data;
    if (!m || typeof m !== 'object' || !('__denMini' in m)) return;
    const f = Array.from(document.querySelectorAll('iframe,frame')).find(x => x.contentWindow === e.source);
    if (!f) return;
    mark(m.__denMini ? f : null, !!m.__denMini);
    up(!!m.__denMini);
  });
  window.__denMedia = {
    isolate(on) {
      if (on) { target = target && target.isConnected ? target : best(); if (!target) return false; }
      mark(target, on);
      up(on);
      if (!on) { live = false; target = null; }
      state();
      return true;
    },
    live(on) { live = on; if (on) { target = target && target.isConnected ? target : best(); tick(true); } return !!target; },
    cmd(a, x) {
      const v = target && target.isConnected ? target : (best() || document.querySelector('video'));
      if (!v) return false;
      const d = isFinite(v.duration) ? v.duration : Infinity;
      switch (a) {
        case 'play': v.play().catch(() => {}); break;
        case 'pause': v.pause(); break;
        case 'toggle': if (v.paused) v.play().catch(() => {}); else v.pause(); break;
        case 'seek': v.currentTime = Math.max(0, Math.min(x, d)); break;
        case 'skip': v.currentTime = Math.max(0, Math.min(v.currentTime + x, d)); break;
        case 'volume': v.volume = Math.max(0, Math.min(1, x)); v.muted = x <= 0; break;
        case 'mute': v.muted = !!x; break;
        case 'rate': v.playbackRate = x; break;
        // Firefox's PiP keys: ⌘←/⌘→ seek by a tenth of the video, Home/End go to its start/end.
        case 'seekpct': if (isFinite(d)) v.currentTime = Math.max(0, Math.min(v.currentTime + x * d, d)); break;
        case 'start': v.currentTime = 0; break;
        case 'end': if (isFinite(d)) v.currentTime = Math.max(0, d - 0.1); break;
        case 'cc': {
          const ts = tracks(v);
          if (!ts.length) return false;
          if (ts.some(t => t.mode === 'showing')) ts.forEach(t => { t.mode = 'disabled'; });
          else { const lang = String(navigator.language || '').slice(0, 2); (ts.find(t => String(t.language || '').slice(0, 2) === lang) || ts[0]).mode = 'showing'; }
          soon();
          break;
        }
        default: return false;
      }
      tick(true);
      return true;
    },
    // The now-playing element (the sidebar's dock, Control Center, the tab row's hover controls).
    act(a, x) {
      const m = cur && cur.isConnected ? cur : null;
      if (!m) return false;
      const has = h => acts.includes(h);
      switch (a) {
        case 'play': stopped = null; m.play().catch(() => {}); break;
        case 'pause': m.pause(); break;
        case 'toggle': if (m.paused || m.ended) { stopped = null; m.play().catch(() => {}); } else m.pause(); break;
        case 'next': if (!has('nexttrack')) return false; fire('nexttrack'); break;
        case 'previous': if (has('previoustrack')) fire('previoustrack'); else m.currentTime = 0; break;
        case 'seek': if (isFinite(m.duration)) m.currentTime = Math.max(0, Math.min(x, m.duration)); break;
        case 'skip': if (isFinite(m.duration)) m.currentTime = Math.max(0, Math.min(m.currentTime + x, m.duration)); break;
        case 'stop': if (has('stop')) fire('stop'); m.pause(); stopped = m; break;
        default: return false;
      }
      soon();
      return true;
    },
    async pip() {
      const v = target && target.isConnected ? target : best();
      if (!v) return false;
      try { await v.requestPictureInPicture(); return true; } catch (e) {}
      try { v.webkitSetPresentationMode('picture-in-picture'); return true; } catch (e) { return false; }
    },
    async exitPip() { try { if (document.pictureInPictureElement) await document.exitPictureInPicture(); } catch (e) {} return true; },
    probe() { const v = target && target.isConnected ? target : (best() || document.querySelector('video')); return v ? info(v) : null; },
  };
})();
"""#

  /// Page world, document start, every frame: keeps the page's Media Session action handlers
  /// (`setActionHandler`) so den's world can run them (`__denmsdo` with the action's name), and
  /// posts `__denms` (the handled actions, as JSON text) when they or the metadata change. Only
  /// strings cross between the worlds. Nothing else of the page is touched.
  static let sessionHook = #"""
(() => {
  const ms = navigator.mediaSession;
  if (!ms || window.__denMsHook) return;
  Object.defineProperty(window, '__denMsHook', { value: true });
  const h = new Map();
  let queued = false;
  const note = () => {
    if (queued) return;
    queued = true;
    Promise.resolve().then(() => { queued = false; document.dispatchEvent(new CustomEvent('__denms', { detail: JSON.stringify([...h.keys()]) })); });
  };
  const P = Object.getPrototypeOf(ms);
  const set = P.setActionHandler;
  if (typeof set === 'function') {
    Object.defineProperty(P, 'setActionHandler', { configurable: true, writable: true, value: function (a, f) {
      const r = set.apply(this, arguments);
      if (typeof f === 'function') h.set(String(a), f); else h.delete(String(a));
      note();
      return r;
    } });
  }
  const md = Object.getOwnPropertyDescriptor(P, 'metadata');
  if (md && md.set) Object.defineProperty(P, 'metadata', { configurable: true, get: md.get, set: function (v) { md.set.call(this, v); note(); } });
  if (window.MediaMetadata) {
    for (const k of ['title', 'artist', 'album', 'artwork']) {
      const d = Object.getOwnPropertyDescriptor(MediaMetadata.prototype, k);
      if (d && d.set) Object.defineProperty(MediaMetadata.prototype, k, { configurable: true, get: d.get, set: function (v) { d.set.call(this, v); note(); } });
    }
  }
  document.addEventListener('__denmsdo', e => {
    const f = h.get(String(e.detail));
    if (f) try { f({ action: String(e.detail) }); } catch (x) {}
  });
})();
"""#

  /// Page icon for the sidebar: the declared icon, else /favicon.ico. Empty for pages without an
  /// http(s) origin (data:, about:, file:), where "null/favicon.ico" would be garbage.
  static let favicon = """
    (function(){if(!/^https?:$/.test(location.protocol))return '';var l=document.querySelector('link[rel~="apple-touch-icon"]')||document.querySelector('link[rel~="icon"]')||document.querySelector('link[rel="shortcut icon"]');return l&&l.href?l.href:(location.origin+'/favicon.ico')})()
    """
}
