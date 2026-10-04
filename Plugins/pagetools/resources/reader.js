// den reader view (MIT). Runs in den's isolated content world after vendor/Readability.js.
// Draws the article in a closed shadow root over the page; the page itself is left untouched.
// Host API: window.__denReader.{open, close, style, sentences, mark, state, voices}.
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
.bar .vname { max-width: 120px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.bar .chev { width: 9px; height: 9px; opacity: .6; }
.vp { position: fixed; z-index: 3; width: 340px; display: flex; flex-direction: column; border-radius: 12px; overflow: hidden;
  background: var(--panel, var(--bg)); color: var(--text); border: 0.5px solid var(--border); box-shadow: 0 10px 36px var(--shadow);
  font: 13px -apple-system, system-ui; }
.vp-search { display: flex; align-items: center; gap: 8px; padding: 10px 12px; border-bottom: 0.5px solid var(--border); }
.vp-search svg { width: 14px; height: 14px; fill: none; stroke: var(--secondary); stroke-width: 1.7; stroke-linecap: round; flex: none; }
.vp-search input { all: unset; flex: 1; font: 13px -apple-system, system-ui; color: var(--text); }
.vp-search input::placeholder { color: var(--secondary); }
.vp-list { overflow: auto; padding: 4px 6px 6px; flex: 1; min-height: 60px; }
.vp-h { font: 600 11px -apple-system, system-ui; color: var(--secondary); padding: 10px 8px 4px; }
.vp-row { display: flex; align-items: center; gap: 8px; height: 34px; padding: 0 6px 0 8px; border-radius: 8px; cursor: default; }
.vp-row.act { background: var(--hover); }
.vp-check { width: 14px; flex: none; color: var(--accent); display: inline-flex; }
.vp-check svg { width: 13px; height: 13px; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
.vp-text { flex: 1; min-width: 0; display: flex; align-items: baseline; gap: 6px; overflow: hidden; white-space: nowrap; }
.vp-name { font-weight: 500; overflow: hidden; text-overflow: ellipsis; flex: none; max-width: 60%; }
.vp-sub { color: var(--secondary); font-size: 12px; overflow: hidden; text-overflow: ellipsis; }
.vp-badge { flex: none; font: 600 10px -apple-system, system-ui; padding: 1px 6px; border-radius: 5px; border: 0.5px solid var(--border); color: var(--secondary); }
.vp-badge.premium, .vp-badge.personal { color: var(--accent); border-color: var(--accent); }
.vp-play { all: unset; flex: none; width: 24px; height: 24px; border-radius: 6px; display: inline-flex; align-items: center; justify-content: center; color: var(--secondary); }
.vp-play:hover { background: var(--hover); color: var(--text); }
.vp-play svg { width: 11px; height: 11px; }
.vp-empty { padding: 18px 10px; color: var(--secondary); text-align: center; }
.vp-foot { display: flex; align-items: center; gap: 10px; padding: 8px 12px; border-top: 0.5px solid var(--border); }
.vp-foot label { display: flex; align-items: center; gap: 6px; flex: 1; min-width: 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.vp-foot .grow { flex: 1; }
.vp-foot input { accent-color: var(--accent); margin: 0; }
.vp-link { all: unset; color: var(--accent); font-weight: 500; white-space: nowrap; }
.vp-link:hover { text-decoration: underline; }
.vp-keys { padding: 0 12px 9px; color: var(--secondary); font-size: 11px; display: flex; gap: 12px; }
.vp-keys b { font-weight: 600; }
`;

  var ICONS = {
    close: '<svg viewBox="0 0 16 16"><path d="M4 4l8 8M12 4l-8 8"/></svg>',
    play: '<svg viewBox="0 0 16 16"><path d="M5 3.5v9l7.5-4.5z" fill="currentColor" stroke="none"/></svg>',
    pause: '<svg viewBox="0 0 16 16"><path d="M5.5 3.5v9M10.5 3.5v9" stroke-width="2.2"/></svg>',
    pin: '<svg viewBox="0 0 16 16"><path d="M3 8.5l3 3 7-7"/></svg>',
    voice: '<svg viewBox="0 0 16 16"><circle cx="6" cy="5.5" r="2.5"/><path d="M1.5 14c.6-2.6 2.3-4 4.5-4s3.9 1.4 4.5 4M11.5 4.5c.8.9.8 2.1 0 3M13.5 3c1.6 1.8 1.6 4.2 0 6"/></svg>',
    chev: '<svg class="chev" viewBox="0 0 10 10"><path d="M2 3.5l3 3 3-3"/></svg>',
    search: '<svg viewBox="0 0 16 16"><circle cx="7" cy="7" r="4.5"/><path d="M10.5 10.5L14 14"/></svg>',
    check: '<svg viewBox="0 0 16 16"><path d="M3 8.5l3 3 7-7"/></svg>',
    tri: '<svg viewBox="0 0 16 16"><path d="M4.5 2.5v11l9-5.5z" fill="currentColor"/></svg>',
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

  // MARK: voice picker (the plugin sends the voices, already ranked within each language)
  var vp = null, vdata = null, vrows = [], vact = 0;
  var base = function (l) { return String(l || '').toLowerCase().split(/[-_]/)[0]; };
  var displayNames = function (type) { try { return new Intl.DisplayNames([navigator.language || 'en'], { type: type }); } catch (e) { return null; } };
  var langNames = null, regionNames = null;
  var langName = function (l) { var b = base(l); try { return (langNames && langNames.of(b)) || b; } catch (e) { return b; } };
  var regionName = function (l) {
    var p = String(l || '').split(/[-_]/), r = p.length > 1 ? p[p.length - 1] : '';
    if (!/^([A-Za-z]{2}|[0-9]{3})$/.test(r)) return '';
    try { return (regionNames && regionNames.of(r.toUpperCase())) || r; } catch (e) { return r; }
  };
  var QUALITY = { premium: 'Premium', enhanced: 'Enhanced', default: 'Default' };
  var keyOf = function (v) { return v.id + '|' + (v.provider || 'system'); };

  // Each word typed must match the voice's name, language, region, provider or quality: at the
  // start of a word scores 3, inside one 2, its letters in order within the name 1.
  var fuzzy = function (q, v) {
    var words = q.toLowerCase().split(/\s+/).filter(Boolean);
    if (!words.length) return 1;
    var hay = [v.name, v._lang, v._region, v.language, v.providerName, QUALITY[v.quality] || '', v.personal ? 'personal' : ''].join(' ').toLowerCase();
    var name = String(v.name).toLowerCase(), total = 0;
    for (var i = 0; i < words.length; i++) {
      var w = words[i], at = hay.indexOf(w);
      if (at >= 0) { total += (at === 0 || /[\s(,-]/.test(hay[at - 1])) ? 3 : 2; continue; }
      var j = 0;
      for (var k = 0; k < name.length && j < w.length; k++) if (name[k] === w[j]) j++;
      if (j < w.length) return 0;
      total += 1;
    }
    return total;
  };

  var closeVoices = function () {
    if (!vp) return;
    vp.remove(); vp = null;
    var d = root && root.querySelector('.den');
    if (d) d.focus();
  };

  var openVoices = function (o) {
    vdata = o;
    langNames = langNames || displayNames('language');
    regionNames = regionNames || displayNames('region');
    (o.voices || []).forEach(function (v) { v._lang = langName(v.language); v._region = regionName(v.language); });
    vp = document.createElement('div'); vp.className = 'vp'; vp.setAttribute('role', 'dialog');
    var lname = o.pageLang ? langName(o.pageLang) : '';
    vp.innerHTML = '<div class="vp-search">' + ICONS.search + '<input type="text" spellcheck="false" placeholder="Search voices, languages or regions"></div>' +
      '<div class="vp-list" role="listbox"></div>' +
      '<div class="vp-foot">' + (o.pageLang ? '<label><input type="checkbox"' + (o.pinned ? ' checked' : '') + '> Use for all ' + esc(lname) + ' pages</label>' : '<span class="grow"></span>') +
      (o.personal === 'notDetermined' ? '<button class="vp-link" data-act="personal">Personal Voice…</button>' : '') +
      '<button class="vp-link" data-act="more">Get more voices…</button></div>' +
      '<div class="vp-keys"><span><b>↑↓</b> Move</span><span><b>↩</b> Choose</span><span><b>⌥↩</b> Preview</span><span><b>esc</b> Close</span></div>';
    var btn = bar.querySelector('[data-id=voices]').getBoundingClientRect();
    var left = Math.max(12, Math.min(innerWidth - 352, btn.left + btn.width / 2 - 170)), top = btn.bottom + 8;
    vp.style.left = left + 'px'; vp.style.top = top + 'px';
    vp.style.maxHeight = Math.max(220, Math.min(480, innerHeight - top - 16)) + 'px';
    root.querySelector('.den').appendChild(vp);
    var input = vp.querySelector('input');
    input.addEventListener('input', function () { vact = -1; renderVoices(); });
    input.addEventListener('keydown', function (e) {
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); setActive(vact + (e.key === 'ArrowDown' ? 1 : -1)); }
      else if (e.key === 'Enter') { e.preventDefault(); var r = vrows[vact]; if (r) (e.altKey ? previewVoice : chooseVoice)(r); }
      else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); closeVoices(); }
    });
    // Typing in the search field isn't a reader shortcut.
    vp.addEventListener('keydown', function (e) { if (e.key !== 'Escape') e.stopPropagation(); });
    var cb = vp.querySelector('.vp-foot input[type=checkbox]');
    if (cb) cb.addEventListener('change', function () { post('pinVoice', { on: cb.checked, langName: lname }); });
    vp.querySelectorAll('.vp-link').forEach(function (b) {
      b.addEventListener('click', function (e) {
        e.stopPropagation();
        if (b.dataset.act === 'more') { post('moreVoices'); closeVoices(); } else { post('personalVoice'); }
      });
    });
    vact = -1;
    renderVoices();
    input.focus();
  };

  // Groups: the page's language, then the user's, then each provider's own section (a plugin's
  // voices, e.g. "Pocket TTS"), then the other languages by name.
  var renderVoices = function () {
    var o = vdata, list = vp.querySelector('.vp-list'), q = vp.querySelector('input').value.trim();
    var cur = o.current ? o.current.id + '|' + (o.current.provider || 'system') : '';
    var groups = {}, order = [];
    (o.voices || []).forEach(function (v, i) {
      var s = fuzzy(q, v);
      if (!s) return;
      var p = v.provider || 'system', g = p === 'system' ? base(v.language) : 'p:' + p;
      if (!groups[g]) { groups[g] = { title: p === 'system' ? v._lang : (v.providerName || p), items: [], provider: p !== 'system' }; order.push(g); }
      groups[g].items.push({ v: v, s: s, i: i });
    });
    var first = [base(o.pageLang), base(o.userLang)].filter(Boolean);
    var rank = function (g) { var r = first.indexOf(g); return r >= 0 ? r : groups[g].provider ? 2 : 3; };
    order.sort(function (a, b) { return rank(a) - rank(b) || String(groups[a].title).localeCompare(String(groups[b].title)); });
    var keep = vact >= 0 && vrows[vact] ? vrows[vact].key : '';
    list.textContent = ''; vrows = [];
    var row = function (key, name, sub, badge, checked, v) {
      var r = document.createElement('div'); r.className = 'vp-row'; r.setAttribute('role', 'option'); r.dataset.key = key;
      r.innerHTML = '<span class="vp-check">' + (checked ? ICONS.check : '') + '</span><span class="vp-text"><span class="vp-name">' + esc(name) + '</span>' +
        (sub ? '<span class="vp-sub">' + esc(sub) + '</span>' : '') + '</span>' + badge + (v ? '<button class="vp-play" aria-label="Preview">' + ICONS.tri + '</button>' : '');
      var entry = { key: key, v: v, el: r }, n = vrows.length;
      r.addEventListener('mousemove', function () { if (vact !== n) setActive(n, true); });
      r.addEventListener('click', function (e) { e.stopPropagation(); chooseVoice(entry); });
      var play = r.querySelector('.vp-play');
      if (play) play.addEventListener('click', function (e) { e.stopPropagation(); previewVoice(entry); });
      vrows.push(entry); list.appendChild(r);
    };
    if (!q) row('system', 'System Voice', o.system && o.system.name ? o.system.name : '', '', !cur, null);
    order.forEach(function (g) {
      var G = groups[g];
      if (q) G.items.sort(function (a, b) { return b.s - a.s || a.i - b.i; });
      var h = document.createElement('div'); h.className = 'vp-h'; h.textContent = G.title; list.appendChild(h);
      G.items.forEach(function (it) {
        var v = it.v, cls = v.personal ? 'personal' : v.quality, label = v.personal ? 'Personal' : QUALITY[v.quality] || 'Default';
        var sub = G.provider ? v._lang + (v._region ? ' (' + v._region + ')' : '') : v._region;
        row(keyOf(v), v.name, sub, '<span class="vp-badge ' + esc(cls) + '">' + esc(label) + '</span>', keyOf(v) === cur, v);
      });
    });
    if (!vrows.length) { var e = document.createElement('div'); e.className = 'vp-empty'; e.textContent = 'No voices match “' + q + '”'; list.appendChild(e); }
    var at = -1;
    vrows.forEach(function (r, i) { if (at < 0 && keep && r.key === keep) at = i; });
    if (at < 0 && !q) vrows.forEach(function (r, i) { if (at < 0 && r.el.querySelector('.vp-check svg')) at = i; });
    setActive(Math.max(0, at));
  };

  var setActive = function (i, mouse) {
    if (!vrows.length) { vact = -1; return; }
    vact = Math.max(0, Math.min(vrows.length - 1, i));
    vrows.forEach(function (r, j) { r.el.classList.toggle('act', j === vact); });
    if (!mouse) vrows[vact].el.scrollIntoView({ block: 'nearest' });
  };
  var chooseVoice = function (r) {
    if (r.key === 'system') post('systemVoice');
    else post('pickVoice', { id: r.v.id, provider: r.v.provider || 'system', name: r.v.name, lang: r.v.language, langName: r.v._lang });
    closeVoices();
  };
  var previewVoice = function (r) {
    if (r.v) post('previewVoice', { id: r.v.id, provider: r.v.provider || 'system', name: r.v.name, lang: r.v.language });
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
      bar.appendChild(button('voices', ICONS.voice + '<span class="vname">Voice</span>' + ICONS.chev, 'Choose a voice (V)'));
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
      den.addEventListener('keydown', function (e) {
        if (e.key === 'Escape') { if (vp) closeVoices(); else post('close'); }
        else if ((e.key === 'v' || e.key === 'V') && !e.metaKey && !e.ctrlKey && !e.altKey && !vp) { e.preventDefault(); post('voices'); }
      });
      // A click outside the picker closes it (the voice button toggles it itself).
      den.addEventListener('mousedown', function (e) {
        if (!vp) return;
        var path = e.composedPath();
        if (path.indexOf(vp) >= 0 || path.some(function (n) { return n.dataset && n.dataset.id === 'voices'; })) return;
        closeVoices();
      });
      den.tabIndex = -1; den.focus();
      return { ok: true, title: parsed.title || document.title, lang: opts.lang, count: ranges.length, length: parsed.length || 0 };
    },
    close: function () {
      if (!host) return { ok: true };
      closeVoices();
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
      if (s.voice !== undefined) bar.querySelector('[data-id=voices] .vname').textContent = s.voice || 'Voice';
      return true;
    },
    // The voice picker: {voices, current, system, pageLang, userLang, pinned, personal}. Again closes it.
    voices: function (o) {
      if (!bar) return false;
      if (vp) { closeVoices(); return true; }
      openVoices(o || {});
      return true;
    },
    // For tests: what the picker shows, "# Group" headers and rows as "[> ][✓ ]id|provider"
    // ("system" for System Voice), ">" marking the keyboard's row.
    voicesShown: function () {
      if (!vp) return null;
      return Array.from(vp.querySelectorAll('.vp-h, .vp-row')).map(function (n) {
        return n.classList.contains('vp-h') ? '# ' + n.textContent : (n.classList.contains('act') ? '> ' : '') + (n.querySelector('.vp-check svg') ? '✓ ' : '') + n.dataset.key;
      });
    },
    voicesType: function (q) { if (!vp) return false; var i = vp.querySelector('input'); i.value = q; i.dispatchEvent(new Event('input')); return true; },
    voicesKey: function (key, alt) {
      if (!vp) return false;
      vp.querySelector('input').dispatchEvent(new KeyboardEvent('keydown', { key: key, altKey: !!alt, bubbles: true, cancelable: true }));
      return true;
    },
  };
})();
