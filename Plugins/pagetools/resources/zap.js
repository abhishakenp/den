// den Zap (MIT): click elements to hide them; den remembers them per site as CSS selectors.
// Runs in den's isolated content world. Host API: window.__denZap.{start(opts), stop, unstick,
// selectorFor, hide}. Posts {tool: 'zap', action: 'change' | 'done', value: {selectors, restored}}.
(function () {
  if (window.__denZap) return;
  var host = null, root = null, box = null, list = null, hovered = null, selectors = [], restored = false, listeners = [];
  var sheet = null;
  var post = function (action) {
    try { webkit.messageHandlers.den.postMessage({ tool: 'zap', action: action, value: { selectors: selectors.slice(), restored: restored } }); } catch (e) {}
  };
  var listen = function (t, type, fn) { t.addEventListener(type, fn, true); listeners.push([t, type, fn]); };
  var cssEscape = function (s) { return window.CSS && CSS.escape ? CSS.escape(s) : s.replace(/[^\w-]/g, '\\$&'); };
  // Ids and classes that look generated (hashes, long numbers) change between visits.
  var stable = function (s) { return s && s.length < 40 && !/\d{3,}|[a-f0-9]{6,}|^[a-z]{1,2}-[A-Za-z0-9]{5,}$|__|--[a-z0-9]{5,}/i.test(s) && !/^(den-|is-|has-|hover|active|open|show|visible|js-)/.test(s); };
  var unique = function (sel) { try { return document.querySelectorAll(sel).length === 1; } catch (e) { return false; } };
  var selectorFor = function (el) {
    var parts = [];
    for (var e = el; e && e.nodeType === 1 && e !== document.documentElement; e = e.parentElement) {
      if (e.id && stable(e.id)) {
        parts.unshift('#' + cssEscape(e.id));
        if (unique(parts.join(' > '))) return parts.join(' > ');
      }
      var part = e.tagName.toLowerCase();
      var cls = Array.from(e.classList).filter(stable).slice(0, 2);
      if (cls.length) part += '.' + cls.map(cssEscape).join('.');
      var candidate = [part].concat(parts).join(' > ');
      if (e.parentElement && !unique(candidate)) {
        var same = Array.from(e.parentElement.children).filter(function (c) { return c.tagName === e.tagName; });
        if (same.length > 1) part += ':nth-of-type(' + (same.indexOf(e) + 1) + ')';
      }
      parts.unshift(part);
      if (unique(parts.join(' > '))) return parts.join(' > ');
    }
    return parts.join(' > ');
  };
  var apply = function () {
    if (!sheet) { sheet = document.createElement('style'); sheet.id = 'den-zap'; (document.head || document.documentElement).appendChild(sheet); }
    sheet.textContent = selectors.map(function (s) { return s + ' { display: none !important; }'; }).join('\n');
  };
  var add = function (sel) { if (sel && selectors.indexOf(sel) < 0) { selectors.push(sel); apply(); render(); post('change'); } };
  var label = function (sel) {
    var el = null; try { el = document.querySelector(sel); } catch (e) {}
    var t = el ? (el.getAttribute('aria-label') || el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 40) : '';
    return t || sel.split(' > ').pop();
  };
  var render = function () {
    if (!list) return;
    root.querySelector('.count').textContent = selectors.length ? selectors.length + ' hidden on this site' : 'Click elements to hide them';
    list.innerHTML = '';
    selectors.slice().reverse().forEach(function (sel) {
      var row = document.createElement('div'); row.className = 'row';
      var t = document.createElement('span'); t.textContent = label(sel); t.title = sel;
      var b = document.createElement('button'); b.textContent = 'Undo'; b.title = 'Show this element again';
      b.addEventListener('click', function (e) {
        e.stopPropagation();
        selectors = selectors.filter(function (s) { return s !== sel; });
        restored = true; apply(); render(); post('change');
      });
      row.appendChild(t); row.appendChild(b); list.appendChild(row);
    });
  };
  // Visible fixed or sticky boxes (headers, banners, overlays), outermost only. Skips the page's
  // main content (a fixed app shell that holds the article).
  var stickies = function () {
    var out = [];
    document.querySelectorAll('body *').forEach(function (el) {
      if (el === host || out.some(function (o) { return o.contains(el); })) return;
      var cs = getComputedStyle(el);
      if ((cs.position !== 'fixed' && cs.position !== 'sticky') || cs.display === 'none' || cs.visibility === 'hidden') return;
      var r = el.getBoundingClientRect();
      if (r.width < 40 || r.height < 16) return;
      // A fixed app shell (most of the screen, lots of text) is the page, not a banner.
      var shell = r.height > innerHeight * 0.6 && r.width > innerWidth * 0.6 && (el.innerText || '').length > 3000;
      if (el.querySelector('main, article') || shell) return;
      out.push(el);
    });
    return out;
  };
  var STYLE = `
:host { all: initial; }
.box { position: fixed; z-index: 2147483646; pointer-events: none; display: none; border-radius: 4px;
  box-shadow: 0 0 0 2px #F53714; background: rgba(245,55,20,.12); }
.panel { position: fixed; z-index: 2147483647; right: 16px; bottom: 16px; width: 280px; padding: 12px; border-radius: 14px;
  background: var(--bar); color: var(--text); border: 0.5px solid var(--border); box-shadow: 0 10px 32px var(--shadow);
  backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px); font: 13px -apple-system, system-ui; }
.title { font-weight: 600; display: flex; align-items: center; gap: 6px; }
.count { color: var(--secondary); margin: 2px 0 8px; font-size: 12px; }
.list { max-height: 180px; overflow: auto; }
.row { display: flex; align-items: center; gap: 8px; padding: 4px 0; border-top: 0.5px solid var(--border); }
.row span { flex: 1; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
button { all: unset; cursor: default; border-radius: 7px; padding: 3px 8px; font: 500 12px -apple-system, system-ui; }
.row button { color: var(--accent); } .row button:hover, .actions button:hover { background: var(--hover); }
.actions { display: flex; gap: 6px; margin-top: 10px; }
.actions button { flex: 1; text-align: center; padding: 6px 8px; background: var(--hover); }
.actions button.primary { background: var(--accent); color: var(--onAccent, white); }
`;
  window.__denZap = {
    start: function (o) {
      o = o || {};
      selectors = (o.selectors || []).slice(); restored = false;
      if (host) { render(); return true; }
      host = document.createElement('den-zap');
      root = host.attachShadow({ mode: 'closed' });
      for (var k in o.vars || {}) host.style.setProperty('--' + k, o.vars[k]);
      root.innerHTML = '<style>' + STYLE + '</style><div class="box"></div><div class="panel"><div class="title">⚡︎ Zap</div>' +
        '<div class="count"></div><div class="list"></div><div class="actions"><button class="sticky">Remove Sticky Headers</button>' +
        '<button class="primary done">Done</button></div></div>';
      box = root.querySelector('.box'); list = root.querySelector('.list');
      root.querySelector('.done').addEventListener('click', function (e) { e.stopPropagation(); window.__denZap.stop(); post('done'); });
      root.querySelector('.sticky').addEventListener('click', function (e) { e.stopPropagation(); window.__denZap.unstick(); });
      document.documentElement.appendChild(host);
      apply(); render();
      listen(window, 'mousemove', function (e) {
        if (e.composedPath().indexOf(host) >= 0) { box.style.display = 'none'; hovered = null; return; }
        var el = document.elementFromPoint(e.clientX, e.clientY);
        if (!el || el === host || el === document.documentElement || el === document.body) { box.style.display = 'none'; hovered = null; return; }
        hovered = el;
        var r = el.getBoundingClientRect();
        box.style.display = 'block'; box.style.left = r.left + 'px'; box.style.top = r.top + 'px'; box.style.width = r.width + 'px'; box.style.height = r.height + 'px';
      });
      listen(window, 'click', function (e) {
        if (e.composedPath().indexOf(host) >= 0) return;
        e.preventDefault(); e.stopPropagation();
        if (hovered) { add(selectorFor(hovered)); box.style.display = 'none'; hovered = null; }
      });
      ['mousedown', 'mouseup', 'pointerdown', 'pointerup'].forEach(function (t) {
        listen(window, t, function (e) { if (e.composedPath().indexOf(host) < 0) { e.preventDefault(); e.stopPropagation(); } });
      });
      listen(window, 'keydown', function (e) { if (e.key === 'Escape') { e.preventDefault(); window.__denZap.stop(); post('done'); } });
      return true;
    },
    stop: function () {
      listeners.forEach(function (l) { l[0].removeEventListener(l[1], l[2], true); });
      listeners = [];
      if (host) host.remove();
      host = root = box = list = null; hovered = null;
      return true;
    },
    // "Remove Sticky Headers": hides every visible fixed/sticky box. Returns their selectors.
    unstick: function (o) {
      if (o && o.selectors) selectors = o.selectors.slice();
      var found = stickies().map(selectorFor).filter(function (s) { return s && selectors.indexOf(s) < 0; });
      selectors = selectors.concat(found); apply(); render();
      post('change');
      return { selectors: selectors.slice(), added: found.length };
    },
    selectorFor: function (q) { var el = document.querySelector(q); return el ? selectorFor(el) : null; },
    // Test hook: zap the element matching `q` as if it had been clicked.
    hide: function (q) { var el = document.querySelector(q); if (!el) return null; var s = selectorFor(el); add(s); return s; },
  };
})();
