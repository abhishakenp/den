import WebKit

/// The page-side half of den's media and discard bookkeeping. One user script, injected at
/// document start into every frame, in den's own isolated content world (`den`): the page can't
/// see or tamper with it, but it shares the DOM, so it hears the media and input events.
///
/// It posts `denMedia` messages only when something changes (never on a timer):
///   {k: "s", a, p, d, pip, v, n}  state: a = audible media playing, p = any media playing,
///                              d = unsaved form input, pip = a video of this frame is in picture
///                              in picture (WebKit's), v = the frame's main playing video,
///                              n = now playing: the last media element that played audibly, with
///                              the page's Media Session info {title, artist, album, art, paused,
///                              dur, video, acts, vol, rate} (acts = the page's Media Session
///                              action handlers, vol/rate = the element's volume and playback rate)
/// and exposes `window.__denMedia` (in the `den` world only) for the host: `act(action, value)`
/// (the now-playing element), `setPlayback(vol, rate)` (the tab's volume and playback speed, on
/// every media element of the frame), `pip()` / `exitPip()` (the standard picture-in-picture API,
/// which WebKit implements with the system PiP window), `probe()`, `refresh()` (a report now,
/// changed or not). A video's `resize` (its track's size known or changed) is a change too.
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
  let last = '', timer = 0;
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
             art: md ? artwork(md) : '', paused: m.paused || m.ended, dur: fin(m.duration), video: m.tagName === 'VIDEO', acts,
             vol: m.volume, rate: m.playbackRate };
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
    const v = best();
    const s = { k: 's', a, p, d: dirty(), pip: !!document.pictureInPictureElement, v: v ? info(v) : null, n: nowInfo() };
    const key = JSON.stringify(s, (k, x) => k === 't' ? undefined : x);
    if (key !== last) { last = key; post(s); }
  };
  const soon = () => { if (!timer) timer = setTimeout(state, 50); };
  // An element that plays (or is unmuted while playing) with sound becomes the now-playing one.
  const follow = ev => {
    const m = ev.target;
    if (!isMedia(m) || m.paused || m.muted || !(m.volume > 0)) return;
    if (ev.type === 'play' || ev.type === 'playing') stopped = null;
    cur = m;
  };
  for (const e of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied', 'ratechange', 'durationchange', 'loadedmetadata',
                   'seeked', 'enterpictureinpicture', 'leavepictureinpicture', 'resize', 'loadeddata']) {
    document.addEventListener(e, ev => { follow(ev); soon(); }, true);
  }
  // Media Session handlers or metadata changed in the page (sessionHook, page world).
  document.addEventListener('__denms', ev => { try { const a = JSON.parse(String(ev.detail || '[]')); if (Array.isArray(a)) acts = a.map(String).slice(0, 16); } catch (e) {} soon(); }, true);
  const fire = a => { try { document.dispatchEvent(new CustomEvent('__denmsdo', { detail: a })); } catch (e) {} return true; };

  document.addEventListener('input', ev => { if (ev.target && ev.target.nodeType === 1) { edited.add(ev.target); soon(); } }, true);
  document.addEventListener('submit', () => { edited.clear(); soon(); }, true);
  document.addEventListener('reset', () => { edited.clear(); soon(); }, true);
  // Fresh numbers at the moment the tab leaves the screen (the discard check reads them later).
  document.addEventListener('visibilitychange', state, true);
  window.addEventListener('pagehide', () => { edited.clear(); last = ''; post({ k: 's', a: false, p: false, d: false, pip: false, v: null }); }, true);

  // The video picture in picture shows: the one in it, else the biggest playing one, else the
  // biggest one that has something to show (a paused video).
  const pipVideo = () => {
    if (document.pictureInPictureElement) return document.pictureInPictureElement;
    let b = best();
    if (b) return b;
    let ba = 0;
    for (const v of document.querySelectorAll('video')) {
      if (!(v.readyState > 0) || v.disablePictureInPicture) continue;
      const r = v.getBoundingClientRect(), a = r.width * r.height;
      if (a >= ba) { ba = a; b = v; }
    }
    return b;
  };
  window.__denMedia = {
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
    // The tab's volume and playback speed, as den's dock set them (`setVolume` / `setRate`):
    // every media element of this frame that exists now. null leaves the element's own value.
    setPlayback(v, r) {
      for (const m of document.querySelectorAll('video,audio')) {
        if (v != null) m.volume = Math.max(0, Math.min(1, v));
        if (r != null) m.playbackRate = r;
      }
      soon();
      return true;
    },
    // WebKit's picture in picture (the system PiP window). Called with a user gesture
    // (callAsyncJavaScript), which `requestPictureInPicture` needs.
    async pip() {
      const v = pipVideo();
      if (!v) return false;
      if (document.pictureInPictureElement === v) return true;
      try { await v.requestPictureInPicture(); return true; } catch (e) {}
      try { if (v.webkitSupportsPresentationMode && v.webkitSupportsPresentationMode('picture-in-picture')) { v.webkitSetPresentationMode('picture-in-picture'); return true; } } catch (e) {}
      return false;
    },
    async exitPip() {
      if (!document.pictureInPictureElement) return false;
      try { await document.exitPictureInPicture(); } catch (e) { return false; }
      return true;
    },
    // A report now, sent even if nothing changed (den deciding with what it last heard).
    refresh() { last = ''; state(); return true; },
    probe() { const v = pipVideo() || document.querySelector('video'); return v ? Object.assign(info(v), { inPip: document.pictureInPictureElement === v }) : null; },

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
