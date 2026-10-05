// den Shields: answers a cookie consent dialog with its most private choice
// (docs/plugin-services.md#shields-plugin-shields). MIT, den's own code; the selectors follow
// what DuckDuckGo's autoconsent (MPL-2.0) documents for these consent platforms, no code copied.
//
// Runs in Shields' isolated content world in the main frame, and only on a page that loaded one of
// the six consent platforms' scripts (a `notify` content rule told den): nothing runs anywhere else.
// The page's scripts can't see this world; the DOM, cookies and storage are shared, so a click here
// is a click on the site's own button. `__denConsent(cmp)` answers one platform at most once per
// page and reports through `webkit.messageHandlers.den` ({consent: {cmp, result, detail}}):
//   rejected  the reject / necessary-only choice was made (detail: what the platform stored)
//   answered  the site already has an answer from an earlier visit (nothing clicked)
//   none      no dialog appeared
//   open      Sourcepoint's message stayed open: a "pay or accept" wall (no free reject, the
//             frame script leaves those alone) or a reject path den doesn't know
//   failed    a dialog was there but no reject path worked (the cookie list may still hide it)
// It never clicks "accept".

(() => {
  if (window.__denConsent) return;
  const started = {};
  // A platform's dialog may appear well after its script loaded (geo lookups, tag managers, some
  // wait for the page's load event): look until 20 s after the page finished loading, at most 90 s.
  let loadedAt = 0;
  const appears = async f => {
    const end = Date.now() + 90000;
    for (;;) {
      let v = null;
      try { v = f(); } catch (e) {}
      if (v) return v;
      if (document.readyState === 'complete' && !loadedAt) loadedAt = Date.now();
      if (Date.now() > end || (loadedAt && Date.now() - loadedAt > 20000)) return null;
      await sleep(250);
    }
  };
  const sleep = ms => new Promise(r => setTimeout(r, ms));
  const $ = s => document.querySelector(s);
  const $$ = s => Array.from(document.querySelectorAll(s));
  const cookie = n => {
    for (const c of document.cookie.split('; ')) if (c.startsWith(n + '=')) return decodeURIComponent(c.slice(n.length + 1));
    return null;
  };
  const waitFor = async (f, ms, step = 200) => {
    const end = Date.now() + ms;
    for (;;) {
      let v = null;
      try { v = f(); } catch (e) {}
      if (v) return v;
      if (Date.now() > end) return null;
      await sleep(step);
    }
  };
  const click = s => {
    const e = typeof s === 'string' ? $(s) : s;
    if (!e) return false;
    e.click();
    return true;
  };
  // Presence, not visibility, is what counts: den's cookie list may hide a banner with
  // display:none, and its buttons still work.
  const post = (cmp, result, detail) => {
    try { webkit.messageHandlers.den.postMessage({ consent: { cmp, result, detail: detail || '' } }); } catch (e) {}
    return result;
  };

  const handlers = {
    // OneTrust: "Reject All" on the banner, else in the preference centre, else every category off
    // and "Confirm My Choices". Stored: OptanonConsent groups (C0001 is strictly necessary).
    async onetrust() {
      const groups = () => (/(?:^|&)groups=([^&]*)/.exec(cookie('OptanonConsent') || '') || [])[1] || '';
      if (cookie('OptanonAlertBoxClosed')) return ['answered', groups()];
      const ui = await appears(() => $('#onetrust-banner-sdk,#onetrust-pc-sdk'));
      if (!ui) return ['none'];
      await sleep(300);
      if (!click('#onetrust-reject-all-handler') && !click('.ot-pc-refuse-all-handler')) {
        click('#onetrust-pc-btn-handler') || click('.ot-sdk-show-settings');
        const save = await waitFor(() => $('#onetrust-pc-sdk .save-preference-btn-handler'), 3000);
        if (!save) return ['failed', 'no reject button'];
        for (const i of $$('#onetrust-pc-sdk input.category-switch-handler:checked:not(:disabled)')) i.click();
        for (const i of $$('#onetrust-pc-sdk input.category-switch-handler[id*="leg-out"]:checked,#onetrust-pc-sdk .ot-obj-leg-btn-handler:not(.ot-leg-int-enabled)')) i.click();
        save.click();
      }
      const done = await waitFor(() => cookie('OptanonAlertBoxClosed'), 5000);
      return [done ? 'rejected' : 'failed', groups()];
    },

    // Didomi: "Disagree" or "Continue without agreeing"; else the preferences' "Disagree to all".
    // Stored: didomi_token (cookie or localStorage), base64 JSON with purposes.disabled.
    async didomi() {
      // The token exists before any choice (no purposes, no vendors); a choice adds them.
      const token = () => {
        const raw = cookie('didomi_token') || (() => { try { return localStorage.getItem('didomi_token'); } catch (e) { return null; } })();
        try { const t = JSON.parse(atob(raw.replace(/-/g, '+').replace(/_/g, '/'))); return t.purposes || t.vendors ? t : null; } catch (e) { return null; }
      };
      const summary = () => {
        const t = token();
        if (!t) return '';
        const n = k => { const e = ((t[k] || {}).enabled || []).length; return e + ' of ' + (e + ((t[k] || {}).disabled || []).length); };
        return 'purposes enabled ' + n('purposes') + ', vendors enabled ' + n('vendors');
      };
      if (token()) return ['answered', summary()];
      const ui = await appears(() => $('#didomi-notice,#didomi-popup,.didomi-popup-notice'));
      if (!ui) return ['none'];
      await sleep(300);
      if (!click('#didomi-notice-disagree-button') && !click('.didomi-continue-without-agreeing')) {
        if (!click('#didomi-notice-learn-more-button')) return ['failed', 'no disagree button'];
        const off = await waitFor(() => $('.didomi-consent-popup-actions [aria-label^="Disagree to all"],.didomi-consent-popup-preferences button.didomi-components-button--disagree,#btn-toggle-disagree'), 3000);
        if (!off) return ['failed', 'no disagree button in preferences'];
        off.click();
        await sleep(300);
        click('.didomi-consent-popup-actions .didomi-components-button--color,.didomi-consent-popup-footer .didomi-components-button--color') ;
      }
      const done = await waitFor(token, 5000);
      return [done ? 'rejected' : 'failed', summary()];
    },

    // Quantcast Choice (now InMobi Choice). "Disagree" leaves every legitimate interest on, so:
    // "More options" → "Legitimate interest" → "Reject all" (objects to them all; consent is
    // already off, nothing was given) → "Save & exit". ("Reject all" on the purposes screen saves
    // at once and keeps the legitimate interests.) Without those screens, "Disagree".
    // Stored: euconsent-v2 (the IAB TCF string).
    async quantcast() {
      const ui = await appears(() => $('#qc-cmp2-ui'));
      if (!ui) return [cookie('euconsent-v2') ? 'answered' : 'none'];
      await sleep(300);
      let how = 'disagree';
      if (click('#more-options-btn') && await waitFor(() => $('#legitimate-interest,#reject-all-btn'), 3000)) {
        if (click('#legitimate-interest')) {
          await sleep(1000);
          how = click('#reject-all-btn') ? 'consent off, legitimate interests objected' : 'consent off';
          await sleep(500);
          if (!click('#save-and-exit')) how = '';
        } else {
          how = click('#reject-all-btn') ? 'reject all' : '';
        }
      } else {
        const second = $$('.qc-cmp2-summary-buttons > button[mode="secondary"]')[1];
        if (!click('#disagree-btn') && !click(second)) how = '';
      }
      if (!how) return ['failed', 'no reject button'];
      const done = await waitFor(() => !$('#qc-cmp2-ui'), 5000);
      return [done ? 'rejected' : 'failed', how];
    },

    // Cookiebot: "Deny" / "Use necessary cookies only"; else every category off and "Allow
    // selection". Stored: CookieConsent ({necessary:true,preferences:false,…}).
    async cookiebot() {
      const stored = () => {
        const c = cookie('CookieConsent') || '';
        return c ? ['preferences', 'statistics', 'marketing'].map(k => k + ':' + ((new RegExp(k + ':(true|false)').exec(c) || [])[1] || '?')).join(',') : '';
      };
      if (cookie('CookieConsent')) return ['answered', stored()];
      // Custom templates keep Cookiebot's button ids without its dialog element.
      const ui = await appears(() => $('#CybotCookiebotDialog,#CybotCookiebotDialogBodyButtonDecline,#CybotCookiebotDialogBodyLevelButtonLevelOptinDeclineAll'));
      if (!ui) return ['none'];
      await sleep(300);
      if (!click('#CybotCookiebotDialogBodyButtonDecline') && !click('#CybotCookiebotDialogBodyLevelButtonLevelOptinDeclineAll')) {
        const boxes = $$('#CybotCookiebotDialog input[type=checkbox]:checked:not(:disabled)').filter(i => !/Necessary/i.test(i.id));
        const allow = $('#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowallSelection,#CybotCookiebotDialogBodyButtonAcceptSelected');
        if (!allow) return ['failed', 'no deny button'];
        for (const b of boxes) b.click();
        allow.click();
      }
      const done = await waitFor(() => cookie('CookieConsent'), 5000);
      return [done ? 'rejected' : 'failed', stored()];
    },

    // TrustArc: "Required only" / "Reject optional" on the banner. Without one, "More options"
    // opens TrustArc's preference frame, which den's frame script answers (consent-frame.js).
    // Stored: notice_preferences / notice_gdpr_prefs ("0:" = required only), cmapi_cookie_privacy.
    async trustarc() {
      const stored = () => ['notice_preferences', 'notice_gdpr_prefs', 'cmapi_cookie_privacy'].map(k => cookie(k) != null ? k + '=' + cookie(k) : '').filter(Boolean).join(' ');
      if (cookie('notice_preferences') || cookie('notice_gdpr_prefs') || cookie('cmapi_cookie_privacy')) return ['answered', stored()];
      const ui = await appears(() => $('#truste-consent-track,.truste_popframe,#truste-show-consent'));
      if (!ui) return ['none'];
      await sleep(300);
      if (!click('#truste-consent-required')) {
        if (!click('#truste-show-consent')) return ['failed', 'no reject button'];
        // The newer preference centre is a shadow root in the page (`trustarc_newcm_container`);
        // the older one a frame, which consent-frame.js answers.
        const inShadow = s => { const h = $('.trustarc_newcm_container'); return h && h.shadowRoot && h.shadowRoot.querySelector(s); };
        const decline = await waitFor(() => inShadow('#decline_all_button,.declineAllButtonLower,a.required'), 8000);
        if (decline) decline.click();
      }
      const done = await waitFor(() => cookie('notice_preferences') || cookie('notice_gdpr_prefs') || cookie('cmapi_cookie_privacy'), 20000);
      return [done ? 'rejected' : 'failed', stored()];
    },

    // Sourcepoint: its message is a frame (often on the site's own subdomain), answered by den's
    // frame script there (consent-frame.js). Here: wait for the message to close and read what
    // Sourcepoint stored. A message that stays open was left alone ("open").
    async sourcepoint() {
      // What Sourcepoint keeps in the site's localStorage once a choice was made (a uuid): its
      // consentStatus (consentedToAny, rejectedLI, …), else per-vendor grants. Vendors a site marks
      // strictly necessary keep a grant after "Reject all" (theguardian.com: 21 of 140).
      const state = () => {
        try {
          for (let i = 0; i < localStorage.length; i++) {
            const k = localStorage.key(i);
            if (!/^_sp_user_consent_/.test(k)) continue;
            const g = (JSON.parse(localStorage.getItem(k)) || {}).gdpr || {};
            if (!g.uuid) continue;
            const s = g.consentStatus;
            if (s) {
              const gs = s.granularStatus || {};
              return { rejected: s.consentedToAny === false || (!!s.rejectedAny && !s.consentedAll),
                       text: (s.consentedToAny === false ? 'consented to nothing' : s.consentedAll ? 'consented to all' : 'rejected some') +
                         (s.rejectedLI ? ', legitimate interests objected' : '') +
                         (gs.purposeConsent ? ' (purpose consent ' + gs.purposeConsent + ', legitimate interest ' + gs.purposeLegInt + ')' : '') };
            }
            const vendors = Object.values(g.grants || {});
            const granted = vendors.filter(v => v.vendorGrant).length;
            return { rejected: granted === 0, text: granted + ' of ' + vendors.length + ' vendors granted' };
          }
        } catch (e) {}
        return null;
      };
      const before = state();
      if (before) return ['answered', before.text];
      const box = () => $('div[id^="sp_message_container_"]');
      // The frame may answer before this sees the message: then the choice is already stored.
      const ui = await appears(() => box() || state());
      if (!ui) return ['none'];
      if (box() && !(await waitFor(() => !box(), 25000, 300))) return ['open', 'the message stayed open'];
      const s = await waitFor(state, 3000);
      return [s && s.rejected ? 'rejected' : 'failed', s ? s.text : ''];
    },
  };

  window.__denConsent = async cmp => {
    const h = handlers[cmp];
    if (!h) return 'unknown';
    if (started[cmp]) return 'running';
    started[cmp] = true;
    let r;
    try { r = await h(); } catch (e) { r = ['failed', String(e && e.message || e)]; }
    return post(cmp, r[0], r[1]);
  };
})();
