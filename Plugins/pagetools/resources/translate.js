// den page translation (MIT). Runs in den's isolated content world. The host translates on
// device (Apple's Translation framework) and writes the results back in batches.
// Host API: window.__denTranslate.{collect, apply, restore, active}.
(function () {
  if (window.__denTranslate) return;
  var SKIP = { SCRIPT: 1, STYLE: 1, NOSCRIPT: 1, CODE: 1, PRE: 1, TEXTAREA: 1, KBD: 1, SAMP: 1, SVG: 1, MATH: 1, 'DEN-READER': 1, TEMPLATE: 1 };
  var nodes = [], originals = [], applied = false;
  var skip = function (el) {
    for (var e = el; e && e !== document.body; e = e.parentElement) {
      if (SKIP[e.tagName] || SKIP[e.tagName.toUpperCase()]) return true;
      if (e.getAttribute('translate') === 'no' || e.classList.contains('notranslate') || e.isContentEditable) return true;
    }
    return false;
  };
  window.__denTranslate = {
    // Text nodes of the page (letters only), in document order. Returns their trimmed text.
    collect: function (max) {
      if (applied) window.__denTranslate.restore();
      nodes = []; originals = [];
      var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
        acceptNode: function (n) {
          return /\p{L}/u.test(n.data) && !skip(n.parentElement) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
        },
      });
      for (var n = w.nextNode(); n && nodes.length < (max || 4000); n = w.nextNode()) { nodes.push(n); originals.push(n.data); }
      // Text on screen first, so the part you're reading changes first.
      // On screen first, longest text first (the prose you're reading, not menus), then the rest
      // of the page in order.
      var main = [], first = [], rest = [], h = innerHeight;
      nodes.forEach(function (n, i) {
        var r = n.parentElement.getBoundingClientRect();
        (r.bottom > 0 && r.top < h && r.width > 0 ? main : rest).push(i);
      });
      main.sort(function (a, b) { return nodes[b].data.trim().length - nodes[a].data.trim().length; });
      return { texts: nodes.map(function (n) { return n.data.trim(); }), order: main.concat(first, rest), visible: main.length + first.length, title: document.title };
    },
    // Writes translations for nodes[at[i]] (or nodes[at + i] when `at` is a number), keeping
    // each node's leading and trailing whitespace.
    apply: function (at, texts, title) {
      applied = true;
      for (var i = 0; i < texts.length; i++) {
        var k = typeof at === 'number' ? at + i : at[i], n = nodes[k], t = texts[i];
        if (!n || t == null) continue;
        var o = originals[k], lead = o.match(/^\s*/)[0], trail = o.match(/\s*$/)[0];
        n.data = lead + t + trail;
      }
      if (title) { window.__denTranslate.title = document.title; document.title = title; }
      document.documentElement.setAttribute('data-den-translated', '1');
      return true;
    },
    restore: function () {
      for (var i = 0; i < nodes.length; i++) if (nodes[i]) nodes[i].data = originals[i];
      if (window.__denTranslate.title) { document.title = window.__denTranslate.title; window.__denTranslate.title = null; }
      document.documentElement.removeAttribute('data-den-translated');
      var had = applied; applied = false;
      return had;
    },
    active: function () { return applied; },
    showOverlay: function () {
      if (document.getElementById('den-translate-overlay')) return;
      var d = document.createElement('div');
      d.id = 'den-translate-overlay';
      d.innerHTML = '<div style="position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.35);z-index:2147483647;display:flex;align-items:center;justify-content:center"><div style="background:#fff;border-radius:16px;padding:32px 48px;box-shadow:0 12px 40px rgba(0,0,0,0.3);text-align:center;font-family:-apple-system,BlinkMacSystemFont,sans-serif"><div style="font-size:20px;font-weight:600;margin-bottom:12px;color:#1d1d1f">Translating…</div><div style="font-size:14px;color:#86868b">Please wait while we translate the page</div></div></div>';
      document.body.appendChild(d);
    },
    hideOverlay: function () {
      var d = document.getElementById('den-translate-overlay');
      if (d) d.remove();
    },
  };
})();
