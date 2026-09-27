import WebKit

/// The page-side half of den's media and discard bookkeeping. One user script, injected at
/// document start into every frame, in den's own isolated content world (`den`): the page can't
/// see or tamper with it, but it shares the DOM, so it hears the media and input events.
///
/// It posts `denMedia` messages only when something changes (never on a timer):
///   {k: "s", a, p, d, pip, v}  state: a = audible media playing, p = any media playing,
///                              d = unsaved form input, pip = system PiP active,
///                              v = the frame's main playing video (or the mini player's video)
///   {k: "t", t, dur, paused, muted, vol, rate}  playback, only while the mini player shows this
///                              frame's video: on timeupdate (≤ 4/s) and on play/pause/seek/volume
/// and exposes `window.__denMedia` (in the `den` world only) for the host: `isolate(on)`,
/// `cmd(action, value)`, `pip()`, `exitPip()`, `live(on)`.
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
  const fin = d => isFinite(d) ? d : (d === Infinity ? -1 : 0);
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
             src: String(v.currentSrc || v.src || '').slice(0, 300), noPip: !!v.disablePictureInPicture };
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
    const s = { k: 's', a, p, d: dirty(), pip: !!document.pictureInPictureElement, v: v && (!v.paused || v === target) ? info(v) : null };
    const key = JSON.stringify(s, (k, x) => k === 't' ? undefined : x);
    if (key !== last) { last = key; post(s); }
  };
  const soon = () => { if (!timer) timer = setTimeout(state, 50); };
  const tick = force => {
    const v = target, now = Date.now();
    if (!v || (!force && now - lastTick < 250)) return;
    lastTick = now;
    post({ k: 't', t: v.currentTime, dur: fin(v.duration), paused: v.paused, muted: v.muted, vol: v.volume, rate: v.playbackRate });
  };
  for (const e of ['play', 'playing', 'pause', 'ended', 'volumechange', 'emptied', 'ratechange', 'durationchange', 'loadedmetadata',
                   'seeked', 'enterpictureinpicture', 'leavepictureinpicture']) {
    document.addEventListener(e, ev => { if (live && ev.target === target) tick(true); soon(); }, true);
  }
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
        default: return false;
      }
      tick(true);
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

  /// Page icon for the sidebar: the declared icon, else /favicon.ico. Empty for pages without an
  /// http(s) origin (data:, about:, file:), where "null/favicon.ico" would be garbage.
  static let favicon = """
    (function(){if(!/^https?:$/.test(location.protocol))return '';var l=document.querySelector('link[rel~="apple-touch-icon"]')||document.querySelector('link[rel~="icon"]')||document.querySelector('link[rel="shortcut icon"]');return l&&l.href?l.href:(location.origin+'/favicon.ico')})()
    """
}
