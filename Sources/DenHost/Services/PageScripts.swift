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

  /// Cookie consent auto-handler (inspired by DuckDuckGo autoconsent): detects cookie consent
  /// banners and automatically rejects analytics/tracking while accepting only essential cookies.
  ///
  /// Strategy: scan the DOM for common banner patterns, look for reject/decline buttons first,
  /// fall back to "Customize" → reject-tracking-categories, handle dynamically loaded banners
  /// with retries. Runs silently in the page world — the page never sees interference.
  ///
  /// IMPORTANT: only targets cookie-specific banners. Never treats generic dialogs
  /// (role="dialog" without cookie context) as cookie banners — that breaks sites like Google
  /// where dozens of non-cookie dialogs would be matched and their buttons clicked.
  static let cookieConsent = #"""
(() => {
  if (window.__denCookieConsent) return;
  window.__denCookieConsent = true;

  // Only cookie-specific selectors — no generic [role="dialog"] or <dialog>.
  // Generic dialogs are not cookie banners and clicking buttons in them breaks the page.
  const bannerSelectors = [
    '[class*="cookie-banner"]', '[class*="cookie-dialog"]', '[class*="cookie-consent"]',
    '[class*="cookie-policy"]', '[class*="cookie-notice"]', '[class*="cookie-banner__"]',
    '[class*="cookies-banner"]', '[class*="cookies-dialog"]', '[class*="cookie-law"]',
    '[data-cookie-blocker]', '[data-complience]', '[class*="cm-"]', // ConsentManagement
    '[class*="cc-"]', // CookieNotice / Osano
    '[class*="onetrust-"]', '[class*="ot-pc"]', // OneTrust
    '[class*="consent-"]', '[class*="gdpr"]', '[class*="banner"][class*="cookie"]',
    'div[aria-label*="cookie"]', 'div[aria-label*="Cookie"]',
    'div[role="dialog"][aria-label*="cookie"]', 'div[role="dialog"][aria-label*="Cookie"]',
    '[id*="cookie"]', '[id*="consent"]', '[id*="gdpr"]',
    '[role="dialog"]', // generic but heavily filtered in isBanner() (depth + reject button check)
  ];

  // Keywords that indicate a reject/decline button (case-insensitive).
  const rejectKeywords = [
    'reject all', 'decline all', 'do not sell', 'do not share',
    'neither reject', 'only necessary', 'essential only',
    'necesarias', 'solo esenciales', 'reject selection', 'customize',
    'manage', 'preferences', 'settings', 'options', 'cookie settings',
  ];

  // Keywords for acceptance — we want to AVOID these.
  const acceptKeywords = ['accept all', 'agree all', 'allow all', 'consent all', 'aceptar'];

  // Check if text content looks like a reject/decline button.
  function isRejectButton(el) {
    const text = (el.textContent || '').trim().toLowerCase();
    // Must have a reject keyword and NOT primarily an accept keyword.
    const hasReject = rejectKeywords.some(k => text.includes(k));
    const hasAccept = acceptKeywords.some(k => text.includes(k));
    // If it's mostly accept-ish, skip it.
    if (hasAccept && !hasReject) return false;
    return hasReject && text.length < 80;
  }

  // Check if an element looks like a cookie consent banner.
  // CRITICAL: must have cookie-related context (text, aria-label, class, or id).
  // Generic dialogs (role="dialog" with no cookie context) are NOT cookie banners.
  // For generic dialogs: require shallow DOM depth (≤5 levels) AND a reject button.
  function getDepth(el) {
    let d = 0, p = el.parentElement;
    while (p && p !== document.body) { d++; p = p.parentElement; }
    return d;
  }
  function hasRejectButton(el) {
    // Check all buttons (direct children and descendants) for reject keywords.
    const btns = el.querySelectorAll('button, [role="button"]');
    for (let i = 0; i < btns.length; i++) {
      if (isRejectButton(btns[i])) return true;
    }
    return false;
  }
  function isBanner(el) {
    if (!el || !el.isConnected) return false;
    // Skip if already scanned.
    if (el.hasAttribute('data-den-scanned')) return false;
    // Skip very large elements (pages themselves).
    if (el.children.length > 500) return false;
    // Check class names for cookie-related patterns.
    const cls = (el.className || '').toLowerCase();
    if (typeof cls === 'string' && /cookie|consent|complian|onetrust|ot-pc|cc-banner|usercentrics|banner/.test(cls)) return true;
    // Check aria-label for cookie-related keywords.
    const aria = (el.getAttribute('aria-label') || '').toLowerCase();
    if (aria.includes('cookie') || aria.includes('consent')) return true;
    // Check data attributes.
    if (el.hasAttribute('data-cookie-blocker')) return true;
    // Check id for cookie-related patterns.
    const id = (el.id || '').toLowerCase();
    if (id.includes('cookie') || id.includes('consent') || id.includes('gdpr') || id.includes('onetrust')) return true;
    // For generic [role="dialog"] or [role="alertdialog"] without cookie-specific attributes:
    // ONLY match if the element's own visible text directly mentions cookies/consent.
    // This avoids matching Google/Arc dialogs that happen to have a reject button somewhere inside.
    const role = (el.getAttribute('role') || '').toLowerCase();
    if (role === 'dialog' || role === 'alertdialog') {
      const selfText = (el.textContent || '').toLowerCase().slice(0, 300);
      if (!/cookie|consent|gdpr|ccpa|compliant|onetrust|usercentrics/i.test(selfText)) return false;
      if (getDepth(el) > 4) return false;
    }
    // Check the visible text for cookie consent keywords — if the banner text
    // mentions cookies/privacy it's likely a consent banner; otherwise skip.
    const text = (el.textContent || '').toLowerCase().slice(0, 500);
    if (/cookie|consent|gdpr|privacy|ccpa|onetrust|preferences/.test(text)) return true;
    return false;
  }

  // Mark a banner element to avoid rescanning.
  function markScanned(el) {
    try { el.setAttribute('data-den-scanned', 'true'); } catch(e) {}
  }

  // Look for reject buttons within a container.
  // CRITICAL: only click actual buttons (not <a href> links) to avoid unintended navigation.
  function findRejectButton(container) {
    if (!container) return null;
    // Only real buttons — never click <a href> because that navigates away from the page.
    const buttons = container.querySelectorAll('button, [role="button"], input[type="button"], input[type="submit"]');
    let best = null;
    let bestScore = -1;
    for (const btn of buttons) {
      const text = (btn.textContent || '').trim().toLowerCase();
      if (!text || text.length > 80) continue;
      // Score: reject keywords score high, accept keywords score negative.
      let score = 0;
      for (const k of rejectKeywords) {
        if (text.includes(k)) {
          if (acceptKeywords.some(ak => text.includes(ak))) { score -= 10; break; }
          score += 10 - k.length / 10;
          if (k.includes('reject') || k.includes('decline') || k.includes('neither') || k.includes('essential')) score += 5;
        }
      }
      // Short text = more likely to be a button label.
      score += Math.max(0, 5 - text.length / 5);
      if (score > bestScore) { bestScore = score; best = btn; }
    }
    return bestScore > 2 ? best : null;
  }

  // Try to click a button.
  function tryClick(el) {
    if (!el || !el.isConnected) return false;
    try {
      el.click();
      return true;
    } catch(e) { return false; }
  }

  // Main attempt: scan the page for banners and handle them.
  function attempt() {
    // Only query cookie-specific selectors — never [role="dialog"].
    for (const sel of bannerSelectors) {
      try {
        const els = document.querySelectorAll(sel);
        for (const el of els) {
          if (!el.hasAttribute('data-den-scanned')) {
            markScanned(el);
            handleBanner(el);
          }
        }
      } catch(e) {}
    }
  }

  function handleBanner(banner) {
    // 1) Direct reject button in the banner.
    let btn = findRejectButton(banner);
    if (btn) { tryClick(btn); return; }
    // 2) Reject button in the banner's parent (sometimes outside the dialog).
    btn = findRejectButton(banner.parentElement);
    if (btn) { tryClick(btn); return; }
    // 3) Look in body for banners with reject buttons nearby.
    const bodyBanners = document.querySelectorAll(bannerSelectors.slice(0, 5).join(','));
    for (const b of bodyBanners) {
      if (b.hasAttribute('data-den-scanned')) continue;
      markScanned(b);
      if (isBanner(b)) {
        const closeBtn = findRejectButton(b);
        if (closeBtn) { tryClick(closeBtn); return; }
        const closeSelectors = ['button[aria-label*="close"]', 'button[aria-label*="Close"]',
                                'button[data-dismiss]', 'a[aria-label*="close"]'];
        for (const cs of closeSelectors) {
          try {
            const c = b.querySelector(cs);
            if (c) { tryClick(c); return; }
          } catch(e) {}
        }
      }
    }
    // 4) Check if any banner is now hidden (auto-dismissed).
    const visible = document.querySelectorAll(bannerSelectors.join(','));
    if (visible.length === 0) return;
    // 5) Click "Accept" as a last resort to dismiss — then try to set cookie preferences
    //    via localStorage/sessionStorage as a fallback.
    acceptAsLastResort(banner);
  }

  // Accept only essential cookies as a last resort.
  function acceptAsLastResort(banner) {
    const acceptBtns = banner.querySelectorAll('button, [role="button"], a[href]');
    for (const btn of acceptBtns) {
      const text = (btn.textContent || '').trim().toLowerCase();
      if (text && text.length < 40 && !rejectKeywords.some(k => text.includes(k))) {
        if (text.includes('accept') || text.includes('agree') || text.includes('allow') || text.includes('close') ||
            text.includes('done') || text.includes('ok') || text.includes('continue')) {
          tryClick(btn);
          setPrivacyPrefs();
          return;
        }
      }
    }
  }

  // Try to set privacy preferences through common storage mechanisms.
  function setPrivacyPrefs() {
    try {
      const prefs = {
        'ads': false, 'analytics': false, 'personalization': false,
        'targeting': false, 'tracking': false, 'functional': false,
      };
      for (const [key, val] of Object.entries(prefs)) {
        try { sessionStorage.setItem('den_' + key, String(val)); } catch(e) {}
        try { localStorage.setItem('den_' + key, String(val)); } catch(e) {}
      }
      try { localStorage.setItem('aw', '1'); } catch(e) {}
      try { sessionStorage.setItem('aw', '1'); } catch(e) {}
    } catch(e) {}
  }

  // Run immediately, then retry a few times for dynamically loaded banners.
  // Only re-query cookie-specific selectors (never generic dialogs).
  attempt();
  const retries = [500, 1500, 3000, 6000];
  for (const delay of retries) {
    setTimeout(attempt, delay);
  }
})();
"""#

/// Page icon for the sidebar: the declared icon, else /favicon.ico. Empty for pages without an
/// http(s) origin (data:, about:, file:), where "null/favicon.ico" would be garbage.
  static let favicon = """
    (function(){if(!/^https?:$/.test(location.protocol))return '';var l=document.querySelector('link[rel~="apple-touch-icon"]')||document.querySelector('link[rel~="icon"]')||document.querySelector('link[rel="shortcut icon"]');return l&&l.href?l.href:(location.origin+'/favicon.ico')})()
    """

  /// Content world for screen share detection scripts (distinct from the page world so pages can't
  /// see or tamper with it).
  static let screenShareWorld = WKContentWorld.world(name: "den.screenShare")

  /// Screen share detection: polls for active screen share video tracks via the MediaDevices API
  /// and posts state changes ({k: "sc", active: true|false}) back to the host. This covers
  /// `navigator.mediaDevices.getDisplayMedia()` which WebKit does not expose through WKWebView.
  /// The badge shows a red screen icon when active.
  static let screenShare: String = #"""
    (() => {
      if (window.__denScreenShare) return;
      window.__denScreenShare = true;
      const post = m => { try { webkit.messageHandlers.denScreenShare.postMessage(m) } catch (e) {} };
      let active = false;
      function check() {
        let s = false;
        try {
          const t = document.pictureInPictureElement;
          if (t) s = true;
          if (!s) {
            try {
              const v = document.querySelector('video:-webkit-cast, video[chromecast], video[airplay]');
              if (v && v.readyState > 0) s = true;
            } catch(e) {}
          }
          if (!s) {
            try {
              const els = document.querySelectorAll('iframe[src*="chrome://"], iframe[src*="meet.google"], iframe[src*="hangouts"]');
              for (const el of els) {
                try {
                  const c = el.closest('[class*="cast"], [class*="cast-container"], [class*="cast-dialog"]');
                  if (c) s = true;
                } catch(e) {}
              }
            } catch(e) {}
          }
        } catch(e) {}
        if (s !== active) { active = s; post({ k: "sc", a: s }); }
      }
      const loop = () => { check(); requestAnimationFrame(loop); };
      requestAnimationFrame(loop);
    })();
  """#
}