// den "Copy Link to Highlight" (MIT). Runs after vendor/fragment-generation.js in den's isolated
// content world: turns the selection into a `#:~:text=` URL (WICG scroll-to-text-fragment).
(function () {
  if (window.__denHighlight) return;
  // Text directive escaping: the spec reserves '-', ',' and '&' besides percent-encoding.
  var enc = function (s) { return encodeURIComponent(s).replace(/-/g, '%2D').replace(/,/g, '%2C').replace(/&/g, '%26'); };
  window.__denHighlight = {
    link: function () {
      var sel = window.getSelection();
      if (!sel || sel.isCollapsed || !sel.toString().trim()) return { ok: false, error: 'no selection' };
      var r = window.__denFragments.generateFragment(sel);
      if (r.status !== 0 || !r.fragment) return { ok: false, error: ['ok', 'invalid selection', 'ambiguous', 'timeout', 'failed'][r.status] || 'failed' };
      var f = r.fragment, d = '';
      if (f.prefix) d += enc(f.prefix) + '-,';
      d += enc(f.textStart);
      if (f.textEnd) d += ',' + enc(f.textEnd);
      if (f.suffix) d += ',-' + enc(f.suffix);
      return { ok: true, url: location.href.split('#')[0] + '#:~:text=' + d, text: sel.toString().replace(/\s+/g, ' ').trim().slice(0, 200) };
    },
    // Test hook: selects the first occurrence of `text` in the page.
    select: function (text) {
      var w = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
      for (var n = w.nextNode(); n; n = w.nextNode()) {
        var i = n.data.indexOf(text);
        if (i < 0) continue;
        var r = document.createRange(); r.setStart(n, i); r.setEnd(n, i + text.length);
        var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
        return true;
      }
      return false;
    },
  };
})();
