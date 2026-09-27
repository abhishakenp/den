// thin-host: feature-specific, migrate to plugin (whole file)
/// The "Add to den" button on Chrome Web Store and Firefox Add-ons item pages.
///
/// Runs only on those two hosts, in the isolated `den-store` content world (the store's own
/// scripts can't see or call it). It hides the store's own install button, which can't work in
/// den, and puts an Arc-style pill in its place. A click posts `{source, id}` to the host, which
/// re-derives both from the page URL before downloading anything. A MutationObserver keeps the
/// button in place while the store's single-page app re-renders.
///
/// `callAsyncJavaScript` arguments: `installed` (store ids already in den), `pending` (id being added).
enum StoreButton {
  static let script = #"""
    const host = location.hostname;
    const isCWS = host === 'chromewebstore.google.com' || host === 'chrome.google.com';
    const isAMO = host === 'addons.mozilla.org';
    if (!isCWS && !isAMO) return 'skip';
    const S = window.__denStore || (window.__denStore = {installed: [], pending: '', observer: null});
    S.installed = installed; S.pending = pending;

    function ref() {
      const p = location.pathname.split('/').filter(Boolean);
      if (isCWS) {
        const d = p.indexOf('detail');
        if (d < 0) return null;
        const id = p.slice(d + 1).reverse().find(s => /^[a-p]{32}$/.test(s));
        return id ? {source: 'chrome', id} : null;
      }
      const a = p.indexOf('addon');
      return a >= 0 && p[a + 1] ? {source: 'firefox', id: decodeURIComponent(p[a + 1])} : null;
    }

    // The store's own install control, which den replaces.
    function nativeButton() {
      if (isAMO) return document.querySelector('.AMInstallButton, .InstallButtonWrapper, .GetFirefoxButton, .Addon-install-button');
      const re = /^(add to chrome|remove from chrome|get|switch to chrome|download chrome)/i;
      const main = document.querySelector('main') || document.body;
      return [...main.querySelectorAll('button, a[role=button], a')].find(b => re.test((b.textContent || '').trim()) && b.offsetParent !== null) || null;
    }

    function style(b, state) {
      const added = state === 'added', busy = state === 'busy';
      const text = added ? '✓  Added to den' : busy ? 'Adding…' : '＋  Add to den';
      if (b.textContent !== text) b.textContent = text;  // childList mutations re-run place()
      b.disabled = added || busy;
      b.title = added ? 'This extension is installed in den' : 'Install this extension in den';
      Object.assign(b.style, {
        font: '600 14px -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif', letterSpacing: '-0.01em',
        height: '36px', padding: '0 18px', borderRadius: '10px', border: '0', cursor: b.disabled ? 'default' : 'pointer',
        color: added ? '#3139fb' : '#fff', background: added ? 'rgba(49,57,251,0.10)' : '#3139fb',
        boxShadow: added ? 'none' : '0 1px 2px rgba(0,0,0,0.12), inset 0 0 0 0.5px rgba(255,255,255,0.18)',
        transition: 'background 120ms ease, transform 80ms ease', whiteSpace: 'nowrap', display: 'inline-flex',
        alignItems: 'center', gap: '6px', flex: 'none', margin: '0 8px 0 0', verticalAlign: 'middle', zIndex: '2'
      });
    }

    function place() {
      const r = ref();
      let b = document.getElementById('den-add');
      if (!r) { if (b) b.remove(); return; }
      const state = S.installed.includes(r.id) ? 'added' : (S.pending === r.id ? 'busy' : 'idle');
      const native = nativeButton();
      if (!b) {
        b = document.createElement('button');
        b.id = 'den-add';
        b.type = 'button';
        b.addEventListener('mouseenter', () => { if (!b.disabled) b.style.background = '#2a31e0'; });
        b.addEventListener('mouseleave', () => { if (!b.disabled) b.style.background = '#3139fb'; });
        b.addEventListener('mousedown', () => { if (!b.disabled) b.style.transform = 'scale(0.97)'; });
        b.addEventListener('mouseup', () => { b.style.transform = ''; });
        b.addEventListener('click', (e) => {
          e.preventDefault(); e.stopPropagation();
          const cur = ref();
          if (!cur || b.disabled) return;
          S.pending = cur.id; style(b, 'busy');
          window.webkit.messageHandlers.denStore.postMessage(cur);
        });
      }
      b.dataset.denId = r.id;
      style(b, state);
      if (native && native.id !== 'den-add') {
        if (b.nextSibling !== native) native.parentNode.insertBefore(b, native);
        native.style.display = 'none';
        native.dataset.denHidden = '1';
      } else if (!b.isConnected) {
        const h1 = document.querySelector('main h1, h1');
        if (!h1) return;
        h1.insertAdjacentElement('afterend', b);
        b.style.margin = '12px 0';
      }
    }

    window.__denStoreRemove = () => {
      document.getElementById('den-add')?.remove();
      document.querySelectorAll('[data-den-hidden]').forEach(n => { n.style.display = ''; delete n.dataset.denHidden; });
      S.observer?.disconnect(); S.observer = null;
    };

    place();
    if (!S.observer) {
      let queued = false;
      S.observer = new MutationObserver(() => {
        if (queued) return;
        queued = true;
        requestAnimationFrame(() => { queued = false; place(); });
      });
      S.observer.observe(document.body, {childList: true, subtree: true});
    }
    const b = document.getElementById('den-add');
    return b ? b.textContent : 'none';
    """#
}
