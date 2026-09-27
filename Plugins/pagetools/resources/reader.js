// den reader view (MIT). Runs in den's isolated content world after vendor/Readability.js.
// Draws the article in a closed shadow root over the page; the page itself is left untouched.
// Host API: window.__denReader.{open, close, style, sentences, mark, state}.
(function () {
  if (window.__denReader) return;
  var host = null, root = null, article = null, bar = null, ranges = [], saved = null, opts = {};
  var post = function (action, value) {
    try { webkit.messageHandlers.den.postMessage({ tool: 'reader', action: action, value: value === undefined ? null : value }); } catch (e) {}
  };
  var esc = function (s) { var d = document.createElement('div'); d.textContent = s || ''; return d.innerHTML; };

  var STYLE = `
:host { all: initial; }
.den { position: fixed; inset: 0; z-index: 2147483647; overflow: auto; background: var(--bg); color: var(--text);
  -webkit-font-smoothing: antialiased; font-family: -apple-system, system-ui, sans-serif; }
.bar { position: sticky; top: 12px; z-index: 2; margin: 12px auto 0; width: max-content; display: flex; align-items: center; gap: 2px;
  padding: 4px; border-radius: 12px; background: var(--bar); border: 0.5px solid var(--border);
  box-shadow: 0 6px 24px var(--shadow); backdrop-filter: blur(20px); -webkit-backdrop-filter: blur(20px); }
.bar button { all: unset; height: 28px; min-width: 28px; padding: 0 8px; box-sizing: border-box; border-radius: 8px; display: inline-flex;
  align-items: center; justify-content: center; gap: 6px; font: 500 13px -apple-system, system-ui; color: var(--text); cursor: default; }
.bar button:hover { background: var(--hover); }
.bar button.on { color: var(--accent); }
.bar .sep { width: 0.5px; height: 18px; background: var(--border); margin: 0 4px; }
.bar svg { width: 15px; height: 15px; fill: none; stroke: currentColor; stroke-width: 1.7; stroke-linecap: round; stroke-linejoin: round; }
.bar .small { font-size: 11px; }
article { max-width: var(--measure); margin: 40px auto 96px; padding: 0 32px; font-family: var(--font); font-size: var(--size);
  line-height: 1.6; color: var(--text); }
article .site { font: 600 12px -apple-system, system-ui; letter-spacing: .02em; text-transform: uppercase; color: var(--accent); margin-bottom: 10px; }
article h1.title { font-family: -apple-system, system-ui, sans-serif; font-size: 1.9em; line-height: 1.18; font-weight: 700; margin: 0 0 10px; letter-spacing: -0.01em; }
article .byline { color: var(--secondary); font: 14px -apple-system, system-ui; margin-bottom: 28px; }
article img, article video, article figure { max-width: 100%; height: auto; border-radius: 8px; }
article figure { margin: 1.4em 0; } article figcaption { color: var(--secondary); font-size: .8em; margin-top: 6px; }
article a { color: var(--accent); text-decoration: none; } article a:hover { text-decoration: underline; }
article h2, article h3, article h4 { font-family: -apple-system, system-ui, sans-serif; line-height: 1.25; margin: 1.6em 0 .5em; }
article blockquote { margin: 1.2em 0; padding: 0 0 0 16px; border-left: 3px solid var(--accent); color: var(--secondary); }
article pre, article code { font-family: ui-monospace, Menlo, monospace; font-size: .85em; background: var(--hover); border-radius: 6px; }
article pre { padding: 12px; overflow: auto; } article code { padding: 1px 4px; } article pre code { padding: 0; background: none; }
article table { border-collapse: collapse; max-width: 100%; display: block; overflow: auto; font-size: .85em; }
article td, article th { border: 0.5px solid var(--border); padding: 4px 8px; }
article hr { border: 0; border-top: 0.5px solid var(--border); }
::highlight(den-speak) { background-color: var(--mark); color: inherit; }
`;

  var ICONS = {
    close: '<svg viewBox="0 0 16 16"><path d="M4 4l8 8M12 4l-8 8"/></svg>',
    play: '<svg viewBox="0 0 16 16"><path d="M5 3.5v9l7.5-4.5z" fill="currentColor" stroke="none"/></svg>',
    pause: '<svg viewBox="0 0 16 16"><path d="M5.5 3.5v9M10.5 3.5v9" stroke-width="2.2"/></svg>',
    pin: '<svg viewBox="0 0 16 16"><path d="M3 8.5l3 3 7-7"/></svg>',
  };

  var button = function (id, html, title) {
    var b = document.createElement('button');
    b.dataset.id = id; b.innerHTML = html; b.title = title || '';
    b.addEventListener('click', function (e) { e.stopPropagation(); post(id); });
    return b;
  };
  var sep = function () { var s = document.createElement('span'); s.className = 'sep'; return s; };

  var applyStyle = function (o) {
    if (!host) return;
    for (var k in o.vars || {}) host.style.setProperty('--' + k, o.vars[k]);
    host.style.setProperty('--font', o.font === 'sans' ? '-apple-system, system-ui, sans-serif' : '"New York", "Iowan Old Style", Georgia, serif');
    host.style.setProperty('--size', (o.size || 19) + 'px');
    host.style.setProperty('--measure', Math.round((o.size || 19) * 36) + 'px');
    var f = bar && bar.querySelector('[data-id=font]');
    if (f) f.textContent = o.font === 'sans' ? 'Sans' : 'Serif';
  };

  // Sentences of the article as DOM Ranges (for the read-aloud highlight) and their text.
  var buildRanges = function () {
    ranges = [];
    var seg = typeof Intl !== 'undefined' && Intl.Segmenter ? new Intl.Segmenter(opts.lang || undefined, { granularity: 'sentence' }) : null;
    var blocks = article.querySelectorAll('h1,h2,h3,h4,h5,h6,p,li,blockquote,figcaption,pre,td,dd,dt');
    blocks.forEach(function (b) {
      if (b.querySelector('p,li,blockquote,h2,h3,h4,pre')) return;  // only leaf blocks
      var nodes = [], text = '';
      var w = document.createTreeWalker(b, NodeFilter.SHOW_TEXT);
      for (var n = w.nextNode(); n; n = w.nextNode()) { nodes.push([n, text.length]); text += n.data; }
      if (!text.trim()) return;
      var at = function (off) {
        for (var i = nodes.length - 1; i >= 0; i--) if (nodes[i][1] <= off) return [nodes[i][0], Math.min(off - nodes[i][1], nodes[i][0].data.length)];
        return [nodes[0][0], 0];
      };
      var parts = seg ? Array.from(seg.segment(text)).map(function (s) { return [s.index, s.segment]; }) : [[0, text]];
      parts.forEach(function (p) {
        var t = p[1].trim();
        if (!t) return;
        var lead = p[1].length - p[1].replace(/^\s+/, '').length;
        var s = at(p[0] + lead), e = at(p[0] + lead + t.length);
        var r = document.createRange();
        try { r.setStart(s[0], s[1]); r.setEnd(e[0], e[1]); } catch (x) { return; }
        ranges.push({ range: r, text: t });
      });
    });
  };

  window.__denReader = {
    open: function (o) {
      opts = o || {};
      if (host) { applyStyle(opts); return { ok: true, title: document.title, count: ranges.length, already: true }; }
      if (typeof Readability === 'undefined') return { ok: false, error: 'Readability not loaded' };
      var parsed = null;
      try { parsed = new Readability(document.cloneNode(true), { charThreshold: 300 }).parse(); } catch (e) { return { ok: false, error: String(e) }; }
      if (!parsed || !parsed.content) return { ok: false, error: 'not readable' };
      host = document.createElement('den-reader');
      root = host.attachShadow({ mode: 'closed' });
      var style = document.createElement('style'); style.textContent = STYLE; root.appendChild(style);
      var den = document.createElement('div'); den.className = 'den'; root.appendChild(den);
      bar = document.createElement('div'); bar.className = 'bar';
      bar.appendChild(button('close', ICONS.close, 'Close Reader (⌃⌘R)'));
      bar.appendChild(sep());
      bar.appendChild(button('font', 'Serif', 'Font'));
      bar.appendChild(button('smaller', '<span class="small">A</span>', 'Smaller text'));
      bar.appendChild(button('larger', 'A', 'Larger text'));
      bar.appendChild(sep());
      bar.appendChild(button('speak', ICONS.play + '<span>Listen</span>', 'Read aloud'));
      bar.appendChild(button('rate', '1×', 'Speed'));
      bar.appendChild(sep());
      bar.appendChild(button('always', ICONS.pin + '<span>Always</span>', 'Always use Reader on this site'));
      den.appendChild(bar);
      article = document.createElement('article');
      var site = parsed.siteName || location.hostname.replace(/^www\./, '');
      article.innerHTML = '<div class="site">' + esc(site) + '</div><h1 class="title">' + esc(parsed.title || document.title) + '</h1>' +
        (parsed.byline ? '<div class="byline">' + esc(parsed.byline) + '</div>' : '') + parsed.content;
      den.appendChild(article);
      saved = document.documentElement.style.overflow;
      document.documentElement.style.overflow = 'hidden';
      document.documentElement.appendChild(host);
      applyStyle(opts);
      opts.lang = opts.lang || parsed.lang || document.documentElement.lang || '';
      buildRanges();
      window.__denReader.state(opts.state || {});
      den.addEventListener('keydown', function (e) { if (e.key === 'Escape') post('close'); });
      den.tabIndex = -1; den.focus();
      return { ok: true, title: parsed.title || document.title, lang: opts.lang, count: ranges.length, length: parsed.length || 0 };
    },
    close: function () {
      if (!host) return { ok: true };
      host.remove(); host = root = article = bar = null; ranges = [];
      if (CSS.highlights !== undefined) try { CSS.highlights.delete('den-speak'); } catch (e) {}
      document.documentElement.style.overflow = saved || '';
      return { ok: true };
    },
    isOpen: function () { return !!host; },
    style: function (o) { for (var k in o) opts[k] = o[k]; applyStyle(opts); return { ok: true }; },
    sentences: function () { return ranges.map(function (r) { return r.text; }); },
    mark: function (i) {
      if (typeof CSS === 'undefined' || !CSS.highlights) return false;
      if (i < 0 || i >= ranges.length) { CSS.highlights.delete('den-speak'); return true; }
      CSS.highlights.set('den-speak', new Highlight(ranges[i].range));
      var rect = ranges[i].range.getBoundingClientRect(), den = root.querySelector('.den');
      if (rect.top < 80 || rect.bottom > den.clientHeight - 60) den.scrollBy({ top: rect.top - den.clientHeight / 3, behavior: 'smooth' });
      return true;
    },
    // {playing, rate, always}: the toolbar's toggles.
    state: function (s) {
      if (!bar) return false;
      var sp = bar.querySelector('[data-id=speak]');
      if (s.playing !== undefined) sp.innerHTML = (s.playing ? ICONS.pause + '<span>Pause</span>' : ICONS.play + '<span>Listen</span>');
      if (s.playing !== undefined) sp.classList.toggle('on', !!s.playing);
      if (s.rate !== undefined) bar.querySelector('[data-id=rate]').textContent = (Math.round(s.rate * 100) / 100) + '×';
      if (s.always !== undefined) bar.querySelector('[data-id=always]').classList.toggle('on', !!s.always);
      return true;
    },
  };
})();
