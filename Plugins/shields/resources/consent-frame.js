// den Shields: the consent platforms whose dialog is a frame of their own (Sourcepoint's message
// and privacy manager, TrustArc's preferences). MIT, den's own code; selectors follow what
// DuckDuckGo's autoconsent (MPL-2.0) documents, no code copied.
//
// sitepolicy injects it at document start, in the page world, into frames whose URL matches the
// patterns Shields gives (`*://*/index.html*`, `*://*/privacy-manager/index.html*`,
// `*://consent-pref.trustarc.com/*`): WebKit matches them itself, so no other frame or page runs
// anything. It is wrapped as `(function (denData, denToken) { … })`; neither is used. The first
// check below returns at once in any frame that isn't a consent platform's.
// It never clicks "accept"; a "consent or pay" wall (Sourcepoint's choice type 9) is left alone.

'use strict';
if (window.top === window) return;
const u = new URL(location.href);
const p = u.pathname, q = u.searchParams;
const sourcepoint = (p === '/index.html' && (q.has('message_id') || q.has('consentUUID') || q.has('requestUUID'))) || p === '/privacy-manager/index.html';
const trustarc = u.hostname === 'consent-pref.trustarc.com';
if (!sourcepoint && !trustarc) return;

const $ = s => document.querySelector(s);
const $$ = s => Array.from(document.querySelectorAll(s));
const sleep = ms => new Promise(r => setTimeout(r, ms));
const waitFor = async (f, ms) => {
  const end = Date.now() + ms;
  for (;;) {
    let v = null;
    try { v = f(); } catch (e) {}
    if (v || Date.now() > end) return v;
    await sleep(200);
  }
};
const click = s => { const e = typeof s === 'string' ? $(s) : s; if (!e) return false; e.click(); return true; };

const sp = async () => {
  if (p === '/privacy-manager/index.html') {
    // The privacy manager: "Reject all" where the site offers it, else every consent and
    // legitimate-interest switch off, then "Save & exit".
    const ready = await waitFor(() => $('.sp_choice_type_REJECT_ALL,.sp_choice_type_SAVE_AND_EXIT'), 15000);
    if (!ready) return;
    await sleep(500);
    if (click('.sp_choice_type_REJECT_ALL')) return;
    for (const t of $$('.pm-switch[aria-checked=true],.switch-bg.on,button[role=switch][aria-checked=true]')) t.click();
    await sleep(300);
    click('.sp_choice_type_SAVE_AND_EXIT');
    return;
  }
  // The first message.
  const ready = await waitFor(() => $('.sp_choice_type_11,.sp_choice_type_12,.sp_choice_type_13,.sp_choice_type_ACCEPT_ALL,.sp_choice_type_SE'), 15000);
  if (!ready) return;
  await sleep(500);
  if ($('.sp_choice_type_9')) return;  // pay or accept: no free reject
  if (click('.sp_choice_type_13')) return;  // "Reject all"
  if (click('.sp_choice_type_SE')) return;  // "Necessary only" (save and exit)
  click('.sp_choice_type_12');  // "Manage": the privacy manager loads (in this frame or another)
};

const ta = async () => {
  // TrustArc's preferences: "Decline all" / "Reject all" / "Required only".
  const btn = await waitFor(() => $('.rejectAll,#rejectAll,.declineAllButtonLower,.required,a.required,.decline-all') ||
    $$('button,a.call,a[role=button]').find(b => /^(decline all|reject all|required only|reject optional)$/i.test(b.textContent.trim())), 15000);
  if (!btn) return;
  await sleep(500);
  btn.click();
  // Some versions confirm, then close themselves.
  const close = await waitFor(() => $('#gwt-debug-close_id,.close'), 3000);
  if (close) close.click();
};

const go = () => { (sourcepoint ? sp() : ta()).catch(() => {}); };
if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', go, { once: true }); else go();
