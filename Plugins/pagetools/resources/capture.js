// den capture picker (MIT): drag a region or click an element; the host takes the snapshot.
// Runs in den's isolated content world. Host API: window.__denCapture.{start(mode, opts), stop}.
// Posts {tool: 'capture', action: 'shot', value: {mode, rect}} with `rect` in CSS px of the
// document (scroll offset included), or action 'visible' / 'full' / 'cancel'.
(function () {
  if (window.__denCapture) return;
  var host = null, root = null, box = null, dim = null, bar = null, mode = 'region', start = null, hovered = null, listeners = [];
  var post = function (action, value) {
    try { webkit.messageHandlers.den.postMessage({ tool: 'capture', action: action, value: value === undefined ? null : value }); } catch (e) {}
  };
  var listen = function (t, type, fn) { t.addEventListener(type, fn, true); listeners.push([t, type, fn]); };
  var STYLE = `
:host { all: initial; }
.dim { position: fixed; inset: 0; z-index: 1; cursor: crosshair; background: rgba(0,0,0,.28); }
.dim.clear { background: transparent; pointer-events: none; }
.box { position: fixed; z-index: 2; pointer-events: none; display: none; border-radius: 4px;
  box-shadow: 0 0 0 1.5px var(--accent), 0 0 0 9999px rgba(0,0,0,.28); background: transparent; }
.box.el { box-shadow: 0 0 0 2px var(--accent); background: color-mix(in srgb, var(--accent) 14%, transparent); }
.bar { position: fixed; z-index: 3; top: 14px; left: 50%; transform: translateX(-50%); display: flex; gap: 2px; padding: 4px;
  border-radius: 12px; background: var(--bar); border: 0.5px solid var(--border); box-shadow: 0 8px 28px var(--shadow);
  backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px); font: 500 13px -apple-system, system-ui; color: var(--text); }
.bar button { all: unset; height: 28px; padding: 0 10px; border-radius: 8px; display: inline-flex; align-items: center; cursor: default; }
.bar button:hover { background: var(--hover); }
.bar button.on { background: var(--accent); color: var(--onAccent, white); }
.bar .sep { width: 0.5px; margin: 5px 4px; background: var(--border); }
.hint { position: fixed; z-index: 3; bottom: 18px; left: 50%; transform: translateX(-50%); padding: 6px 12px; border-radius: 10px;
  background: rgba(20,20,24,.78); color: white; font: 500 12px -apple-system, system-ui; }
`;
  var setMode = function (m) {
    mode = m;
    bar.querySelectorAll('button').forEach(function (b) { b.classList.toggle('on', b.dataset.id === m); });
    dim.classList.toggle('clear', m === 'element');
    box.classList.toggle('el', m === 'element');
    box.style.display = 'none';
    root.querySelector('.hint').textContent = m === 'element' ? 'Click an element to capture it · Esc to cancel' : 'Drag to capture a region · Esc to cancel';
  };
  var place = function (x, y, w, h) {
    box.style.display = 'block'; box.style.left = x + 'px'; box.style.top = y + 'px'; box.style.width = w + 'px'; box.style.height = h + 'px';
  };
  // Removes the picker, waits for it to leave the screen (two frames; a timer when frames are
  // throttled), then reports. The host's snapshot also waits for screen updates.
  var finish = function (action, value) {
    window.__denCapture.stop();
    var sent = false;
    var go = function () { if (!sent) { sent = true; post(action, value); } };
    requestAnimationFrame(function () { requestAnimationFrame(go); });
    setTimeout(go, 120);
  };
  window.__denCapture = {
    start: function (m, o) {
      if (host) { setMode(m); return true; }
      o = o || {};
      host = document.createElement('den-capture');
      root = host.attachShadow({ mode: 'closed' });
      for (var k in o.vars || {}) host.style.setProperty('--' + k, o.vars[k]);
      root.innerHTML = '<style>' + STYLE + '</style><div class="dim"></div><div class="box"></div><div class="bar"></div><div class="hint"></div>';
      dim = root.querySelector('.dim'); box = root.querySelector('.box'); bar = root.querySelector('.bar');
      [['region', 'Region'], ['element', 'Element'], ['sep'], ['visible', 'Visible Area'], ['full', 'Full Page'], ['sep'], ['cancel', '✕']].forEach(function (b) {
        if (b[0] === 'sep') { var s = document.createElement('span'); s.className = 'sep'; bar.appendChild(s); return; }
        var el = document.createElement('button'); el.dataset.id = b[0]; el.textContent = b[1];
        el.addEventListener('mousedown', function (e) { e.stopPropagation(); });
        el.addEventListener('click', function (e) {
          e.stopPropagation(); e.preventDefault();
          if (b[0] === 'region' || b[0] === 'element') setMode(b[0]); else finish(b[0]);
        });
        bar.appendChild(el);
      });
      document.documentElement.appendChild(host);
      setMode(m || 'region');
      dim.addEventListener('mousedown', function (e) { if (mode !== 'region') return; e.preventDefault(); start = [e.clientX, e.clientY]; });
      listen(window, 'mousemove', function (e) {
        if (mode === 'region' && start) {
          place(Math.min(start[0], e.clientX), Math.min(start[1], e.clientY), Math.abs(e.clientX - start[0]), Math.abs(e.clientY - start[1]));
        } else if (mode === 'element') {
          var el = document.elementFromPoint(e.clientX, e.clientY);
          if (!el || el === host || el === document.documentElement || el === document.body) { box.style.display = 'none'; hovered = null; return; }
          hovered = el;
          var r = el.getBoundingClientRect();
          place(r.left, r.top, r.width, r.height);
        }
      });
      listen(window, 'mouseup', function (e) {
        if (mode !== 'region' || !start) return;
        var x = Math.min(start[0], e.clientX), y = Math.min(start[1], e.clientY), w = Math.abs(e.clientX - start[0]), h = Math.abs(e.clientY - start[1]);
        start = null;
        if (w < 4 || h < 4) { box.style.display = 'none'; return; }
        finish('shot', { mode: 'region', rect: { x: x + scrollX, y: y + scrollY, width: w, height: h } });
      });
      listen(window, 'click', function (e) {
        if (mode !== 'element' || e.composedPath().indexOf(host) >= 0) return;
        e.preventDefault(); e.stopPropagation();
        if (!hovered) return;
        var r = hovered.getBoundingClientRect();
        finish('shot', { mode: 'element', rect: { x: r.left + scrollX, y: r.top + scrollY, width: r.width, height: r.height } });
      });
      listen(window, 'keydown', function (e) { if (e.key === 'Escape') { e.preventDefault(); finish('cancel'); } });
      return true;
    },
    // Test hook: capture the element matching `selector` as if it had been clicked.
    pick: function (selector) {
      var el = document.querySelector(selector);
      if (!el) return false;
      el.scrollIntoView({ block: 'center' });
      var r = el.getBoundingClientRect();
      finish('shot', { mode: 'element', rect: { x: r.left + scrollX, y: r.top + scrollY, width: r.width, height: r.height } });
      return true;
    },
    stop: function () {
      listeners.forEach(function (l) { l[0].removeEventListener(l[1], l[2], true); });
      listeners = [];
      if (host) host.remove();
      host = root = box = dim = bar = null; start = null; hovered = null;
      return true;
    },
    // Page geometry for visible / full-page shots.
    metrics: function () {
      var d = document.documentElement, b = document.body;
      return { scrollX: scrollX, scrollY: scrollY, innerWidth: innerWidth, innerHeight: innerHeight,
        width: Math.max(d.scrollWidth, b ? b.scrollWidth : 0, d.clientWidth), height: Math.max(d.scrollHeight, b ? b.scrollHeight : 0, d.clientHeight) };
    },
  };
})();
