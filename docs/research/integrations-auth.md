# Integrations auth research (Dia-style "Connect X")

> Research snapshot, 2026-09-27. Decisions made later are in [ROADMAP.md](../../ROADMAP.md) / [FEATURES.md](../FEATURES.md).

> **Decision (2026-09-27, by the user, after reading the risks below):** den ships session reuse ("Option B") for Slack and GitHub: no OAuth apps, nothing to register. You sign in to the site inside den and den reads that session from its own WebKit data store. This goes against this document's recommendation for Slack (§1 "Session reuse", §10): `xoxc` web-client tokens are unsupported and arguably fall under the API ToS circumvention clause. Mitigations in the build: requests only go to the service itself, volume stays near a normal web client (~~8–10~~ → at most about 20 *(corrected 2026-09-28: Plugins/slack/SlackCore.swift:11–15)* Slack requests per workspace and 4 GitHub requests per refresh, only when a connection exists), tokens stay in memory, and no message data is persisted beyond the todo titles you keep. See docs/plugin-services.md (`connections`, `slack`, `github`).

> **Update (2026-09-28):** Gmail, Google Calendar and Notion ship the same way (session reuse, each its own plugin). Their feasibility and terms risks are in [§11](#11-session-reuse-for-gmail-google-calendar-and-notion-2026-09-28). Short version: Calendar low risk, Gmail medium, Notion high (its terms ban automated access in so many words).

Researched 2026-09-27 from official docs, fetched this session. Anything not confirmed on an official page is marked **UNVERIFIED**.

Goal: a local-first macOS browser where tokens live in the Keychain, API calls go directly from the Mac, there is ideally no den-operated server, and any shipped secret is public. We don't reuse other apps' client credentials. The data feeds on-device Foundation Models, which build the briefing, todos and feed.

## TL;DR

| Provider | Secret-free native flow? | Server needed? |
|---|---|---|
| Slack | ✅ PKCE (public client) | ❌ |
| GitHub | ✅ device flow only (PKCE still needs the secret) | ❌ |
| Linear | ✅ PKCE | ❌ |
| Google | ⚠️ Desktop client has a secret that Google itself says is "not treated as a secret" | ❌ (ship the public secret, as Thunderbird does) |
| Microsoft Graph | ✅ public client + PKCE, or device code | ❌ |
| Notion | ❌ secret required for exchange and refresh | ✅ (or internal-token paste) |
| Atlassian | ❌ secret required for exchange and refresh | ✅ (or user-scoped API token) |

Polling is realistic for every provider. Webhooks, Events API and change notifications all need a public HTTPS endpoint. Slack Socket Mode needs an app-level `xapp` token and is meant for internal apps.

---

## 1. Slack

**Public client.** Supported via PKCE.
- "PKCE allows the OAuth flow to be used securely on public clients, like desktop and mobile applications." The token exchange must "not include `client_secret`"; send `code` + `code_verifier` instead.
- Enabling PKCE is "a one-way operation. It cannot be disabled without contacting Slack support."
- "Desktop redirects cannot request bot scopes." That means user tokens only, which fits den.
- https://docs.slack.dev/authentication/using-pkce/

**Redirect URIs**
- Custom scheme (e.g. `den://slack`) is "always treated as desktop redirects", with PKCE mandatory.
- `http://localhost:<port>` counts as desktop under PKCE. Whether literal `127.0.0.1` is accepted: **UNVERIFIED**.
- Without PKCE, HTTPS is required: https://docs.slack.dev/authentication/installing-with-oauth/

**Scopes (user token)**
- `search:read`, for `search.messages` (mentions). It is Tier 2, "20+ per minute". Slack now labels it legacy and points to the Real-time Search API (`assistant.search.context`). https://docs.slack.dev/reference/methods/search.messages/
- `im:history`, `mpim:history`, `channels:history`, `groups:history`, for `conversations.history`. https://docs.slack.dev/reference/methods/conversations.history/
- `users:read` and `im:read` (for name resolution and DM listing): standard, but the scope pages weren't fetched. **UNVERIFIED**.

**Review and distribution**
- "Activate Public Distribution" gives an unlisted app with no Slack review. The checklist requires SSL redirect/request URLs and no hardcoded credentials.
- Slack says "apps intended for commercial distribution should be submitted and approved for listing in the Slack Marketplace."
- Workspaces can restrict installs to admins.
- https://docs.slack.dev/app-management/distribution/

**Tokens**
- With PKCE, a custom-scheme redirect "will always issue a rotating token". Access tokens expire every 12h (`expires_in: 43200`) and "all refresh tokens… expire in 30 days". Refresh omits `client_secret`.
- Consequence: a user who doesn't open den for 30 days must re-auth.
- https://docs.slack.dev/authentication/using-pkce/ , https://docs.slack.dev/authentication/using-token-rotation/

**Rate limits (2025 rule, still current per the pages fetched)**
- From **May 29, 2025**, new apps that are "commercially distributed and have not been approved for the Slack Marketplace" get **1 request/minute** on `conversations.history` and `conversations.replies`, with max/default `limit` of **15 objects**.
- "Internal customer-built apps" keep Tier 3 (50+/min) and 1,000 objects. Existing installs of older apps were not affected.
- https://docs.slack.dev/changelog/2025/05/29/rate-limit-changes-for-non-marketplace-apps/ , https://docs.slack.dev/changelog/2025/06/03/rate-limits-clarity/ , https://docs.slack.dev/apis/web-api/rate-limits/
- The API ToS defines "Commercially Distribute" to cover apps users pay for, or "a free App that connects to a paid product or service". https://slack.com/terms-of-service/api (effective Oct 10, 2025)
- Whether a free open-source den is classified as commercially distributed: **UNVERIFIED**. Assume the 1/min limit.
- Any 2026 extension of the rule: **UNVERIFIED**.

**Push**
- Socket Mode is "intended for internal apps… not intended for widely distributed apps". It needs an `xapp` app-level token, which would be public if shipped. https://docs.slack.dev/apis/events-api/using-socket-mode/
- The Events API needs a public HTTPS URL.
- So: poll. Use `search.messages` for mentions, plus a budgeted `conversations.history` pass for DMs.
- Escape hatch: a "bring your own Slack app" mode, where the user creates an internal app in their workspace. That keeps full limits and is still secret-free with PKCE.

**Session reuse (`xoxc`/`xoxd`)**
- No official Slack page names `xoxc`.
- The API ToS prohibits access that "compromises, breaks or circumvents any of our technical processes or security measures", and says of undocumented APIs "you should not rely on their behaviors".
- It also bans reverse engineering, and "background data collection or scraping for data unrelated to user queries".
- It says "you may not create persistent copies, archives, indexes, or long-term data stores of other organizations' API Data". This clause matters for den's local cache even with official OAuth.
- It bans LLM training on API Data.
- Source: https://slack.com/terms-of-service/api
- Verdict: undocumented, unsupported, and arguably covered by the circumvention clause. An explicit ban is **NOT PROVEN**. Don't ship it.
- OSS precedent: wee-slack and the mautrix Slack bridge do use `xoxc` + `d` cookie login (https://github.com/wee-slack/wee-slack/pull/857, https://docs.mau.fi/bridges/go/slack/authentication.html).

## 2. GitHub

**Secret-free flow**
- Device flow: "The `client_secret` is not needed for the device flow." https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps
- GitHub Apps must enable device flow in settings. https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app
- PKCE (S256) was added 2025-07-14, but "GitHub does not distinguish between public and confidential clients", so the web-flow exchange still needs `client_secret`. https://github.blog/changelog/2025-07-14-pkce-support-for-oauth-and-github-app-authentication/

**Redirects**
- Loopback `http://127.0.0.1/path` is registered once, and "The `redirect_uri` does not need to match the port" (OAuth-app doc above).
- Custom schemes: **UNVERIFIED**.

**Scopes**
- Notifications need the `notifications` scope. The notifications endpoints "only support authentication using a personal access token (classic)", which in practice excludes GitHub App user tokens. https://docs.github.com/en/rest/activity/notifications
- OAuth-app tokens working for notifications: `gh` does this in practice, but the doc wording doesn't confirm it. **UNVERIFIED**.
- PRs in private repos: OAuth apps have no read-only private-repo scope. `repo` is full read/write. https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/scopes-for-oauth-apps
- A GitHub App can take read-only Pull requests permission, but it must be installed on the org or repo, and it gets no notifications.
- No review is needed for either app type.

**Tokens**
- OAuth-app tokens don't expire: **UNVERIFIED** (page not fetched).
- GitHub App user tokens last 8h, with 6-month refresh tokens. The refresh secret is "Required unless the user access token was generated using the device flow". https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens

**Limits**
- 5,000 req/h per user. Secondary limits: 100 concurrent requests, 900 points/min. https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api
- A 304 on a conditional request does not count against the limit. https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api
- Notifications return an `X-Poll-Interval` header; obey it.
- Webhooks need a public endpoint, so poll.

**Precedent**
- The `gh` CLI embeds its OAuth secret with the comment "This value is safe to be embedded in version control" (maintainers' comment, not a GitHub policy). https://github.com/cli/cli/blob/trunk/internal/authflow/flow.go
- VS Code `github-authentication` has four flows: loopback `127.0.0.1` with the secret injected at publish, `vscode://` UrlHandler via an optional proxy, device code (`supportsNoClientSecret: true`), and PAT. https://github.com/microsoft/vscode/blob/main/extensions/github-authentication/src/flows.ts

## 3. Google (Gmail + Calendar)

**Client type**
- Use a Desktop client. Installed apps get "a client secret, which you embed in the source code… (In this context, the client secret is obviously not treated as a secret.)" https://developers.google.com/identity/protocols/oauth2
- PKCE is supported (43–128 char verifier).
- In refresh requests, `client_secret` is marked "Optional". https://developers.google.com/identity/protocols/oauth2/native-app

**Redirects**
- Loopback `http://127.0.0.1:<port>` or `[::1]` is the recommended desktop path.
- Custom URI schemes are "no longer supported due to the risk of app impersonation" (the statement applies to Android and Chrome app clients). Whether an iOS-type client's custom scheme works in a macOS app: **UNVERIFIED**.
- OOB is no longer supported.
- https://developers.google.com/identity/protocols/oauth2/native-app

**Scopes and verification**
- `gmail.readonly` and `gmail.metadata` are **Restricted**. https://developers.google.com/gmail/api/auth/scopes
- Security assessment (CASA) applies to apps that access restricted data "from or through a third-party server". https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification
- So a strictly on-device den plausibly avoids CASA but **still needs restricted-scope verification** for a public app. This is from the docs, not confirmed with Google.
- Exceptions: personal use ("only a few users, all of whom are known personally to you"), Testing status, and Internal Workspace apps. https://support.google.com/cloud/answer/13464323
- Testing status comes with a 100-user cap and the unverified-app screen.
- In Testing with External users, refresh tokens expire in 7 days. There is also a limit of 100 refresh tokens per account per client. https://developers.google.com/identity/protocols/oauth2
- `calendar.readonly` sensitivity class: **UNVERIFIED** (not stated on https://developers.google.com/workspace/calendar/api/auth).

**Tokens**
- Access token 1h: **UNVERIFIED** (docs only give `expires_in`).
- Refresh is secret-optional.

**Limits**
- Gmail: 6,000 units/min per user and 1,200,000/min per project. Costs: `messages.list` 5, `messages.get` 20, `history.list` 2. https://developers.google.com/gmail/api/reference/quota
- An 80M units/day charge threshold "effective later in 2026": **UNVERIFIED**, re-check.
- Calendar: 600 req/min per user and 10,000/min per project. https://developers.google.com/workspace/calendar/api/guides/quota
- Incremental sync: `history.list` with `startHistoryId`. If the ID is too old you get a 404 and must do a full sync. History is kept "at least one week". https://developers.google.com/gmail/api/guides/sync
- Push needs a Cloud Pub/Sub topic plus `watch` renewal every 7 days. https://developers.google.com/workspace/gmail/api/guides/push
- Not practical for a desktop app, so poll.

**Precedent**
- Thunderbird ships its Google clientId and secret in source with PKCE. https://searchfox.org/comm-central/source/mailnews/base/src/OAuth2Providers.sys.mjs
- Its verification status: **UNVERIFIED**.

## 4. Microsoft Graph (Outlook, Teams)

**Public client**
- Desktop apps "can't have client secrets". https://learn.microsoft.com/en-us/entra/identity-platform/msal-client-applications
- Auth code + PKCE works without "Allow public client flows". That toggle is only needed for device code, ROPC and similar.

**Redirects**
- `http` is allowed only for localhost, and the port is ignored. Prefer `127.0.0.1`, which is added via the manifest. `[::1]` isn't supported. https://learn.microsoft.com/en-us/entra/identity-platform/reply-url
- MSAL for macOS defaults to `msauth.<bundle_id>://auth`. https://learn.microsoft.com/en-us/entra/msal/objc/redirect-uris-ios
- Register the redirect as "Mobile and desktop" type, not SPA. SPA refresh tokens are capped at 24h.

**Scopes** (https://learn.microsoft.com/en-us/graph/permissions-reference)
- `User.Read`, `Mail.Read` (or `Mail.ReadBasic`), `Calendars.Read`, `Chat.Read`, `offline_access`.
- `ChannelMessage.Read.All` requires admin consent.
- Chat and channel APIs don't support personal Microsoft accounts. https://learn.microsoft.com/en-us/graph/api/chat-list-messages?view=graph-rest-1.0

**Review**
- Publisher verification: from Nov 2020, with risk-based step-up consent, "users can't consent to most newly registered multitenant apps that aren't publisher verified". Verification is free but needs a Microsoft partner (CPP) account. https://learn.microsoft.com/en-us/entra/identity-platform/publisher-verification-overview
- MC1163922 (late Oct 2025): the Microsoft-managed default consent policy requires admin consent for Mail.Read, Calendars.Read and Chat.Read, among others. **Partially UNVERIFIED**: the source is a Microsoft Q&A thread (https://learn.microsoft.com/en-us/answers/questions/5572742/clarification-on-mc1163922), and the policy isn't in the reference docs.
- Expect work tenants to need admin approval.

**Tokens**
- Access tokens last 60–90 minutes. https://learn.microsoft.com/en-us/entra/identity-platform/configurable-token-lifetimes
- Refresh tokens last 90 days (24h for SPA), rotate on every use, and a public client refreshes without a secret. https://learn.microsoft.com/en-us/entra/identity-platform/refresh-tokens

**Limits**
- Outlook: 10,000 req per 10 min per app+mailbox, and 4 concurrent requests. From a search summary of https://learn.microsoft.com/en-us/graph/throttling-limits; re-check.
- Teams limits: **UNVERIFIED**.
- Delta queries cover message, event and chatMessage. On `410 Gone` or `syncStateNotFound`, do a full resync. https://learn.microsoft.com/en-us/graph/delta-query-overview
- Change notifications need a public HTTPS endpoint, so poll. https://learn.microsoft.com/en-us/graph/change-notifications-delivery-webhooks

## 5. Notion

**Secret required**
- The token request uses "HTTP Basic Authentication… `CLIENT_ID` and `CLIENT_SECRET`". No PKCE or device flow is documented.
- Refresh also uses the secret.
- https://developers.notion.com/docs/authorization , https://developers.notion.com/reference/create-a-token

**Redirects:** registered in the portal. HTTPS requirement, loopback and custom schemes are all **UNVERIFIED**.

**Scopes and review**
- Scopes are capabilities: "Read content", plus optionally comments and user info without email. https://developers.notion.com/reference/capabilities
- "The Authorization URL field populates after a public connection is submitted for review", so review is mandatory before any public OAuth use.
- Alternative: an **internal connection** token that the user pastes. It is single-workspace, and pages must be shared with it manually.

**Tokens:** a refresh token exists. Access-token lifetime: **UNVERIFIED**.

**Limits:** 3 req/s (10 req/s on Business/Enterprise). Honor `Retry-After`. https://developers.notion.com/reference/request-limits

## 6. Linear

**Public client**
- PKCE: in the code exchange, `client_secret` is "(optional)". In a refresh, the secret is optional "if … refreshing a token generated using PKCE".
- https://linear.app/developers/oauth-2-0-authentication

**Redirects:** the doc example is `http://localhost:3000/oauth/callback`, and the URI must match between the authorize and token steps. Dynamic ports and custom schemes: **UNVERIFIED**.

**Scopes and review:** `read` (the default) is enough. No review is documented.

**Tokens**
- Access tokens last 24h.
- "All OAuth2 applications were migrated to the new refresh token system on April 1, 2026".
- Refresh has a 30-minute grace period.
- Refresh-token lifetime: **UNVERIFIED**.

**Limits:** 5,000 req/h and 2,000,000 complexity points/h per user; a single query is capped at 10,000 points. https://linear.app/developers/rate-limiting

**Push:** webhooks need a public URL, so poll.

## 7. Atlassian (Jira + Confluence Cloud)

**Secret required**
- 3LO supports the authorization-code grant only. Both the exchange and the refresh need `client_secret`. https://developer.atlassian.com/cloud/jira/platform/oauth-2-3lo-apps/ , https://developer.atlassian.com/cloud/oauth/getting-started/implementing-oauth-3lo/
- An Atlassian moderator (2024) confirmed only the auth-code flow is supported, with no PKCE. https://community.developer.atlassian.com/t/oauth-2-0-with-proof-key-for-code-exchange-pkce/80173
- Public-client PKCE is reportedly tracked as ECO-283: **UNVERIFIED**.

**Redirects**
- One callback URL per app (ECO-716 is the feature request for multiple: https://jira.atlassian.com/browse/ECO-716).
- HTTPS rules, localhost and custom schemes: **UNVERIFIED**.

**Scopes**
- Jira: `read:jira-work`, `read:jira-user`.
- Confluence: `read:confluence-content.summary` (or `.all`), `search:confluence`, `read:confluence-user`.
- Add `offline_access` for a refresh token.
- https://developer.atlassian.com/cloud/jira/platform/scopes-for-oauth-2-3LO-and-forge-apps/ , https://developer.atlassian.com/cloud/confluence/scopes-for-oauth-2-3LO-and-forge-apps/

**Review:** sharing must be enabled per app. There is no mandatory review, but users installing an unreviewed app see a warning.

**Tokens**
- Access-token lifetime: `expires_in` only; "1h" is **UNVERIFIED**.
- Refresh tokens rotate, expire after 90 days of inactivity, and have a 10-minute reuse interval.
- https://developer.atlassian.com/cloud/oauth/getting-started/refresh-tokens/

**Limits**
- Points-based limits have been enforced since 2026-03-02 for OAuth 3LO apps. "API token-based traffic is not affected." https://developer.atlassian.com/cloud/jira/platform/rate-limiting/
- The specific point numbers came from a page summary: re-check before relying on them.
- Webhooks need a public HTTPS endpoint with a trusted-CA certificate, and expire after 30 days. https://developer.atlassian.com/cloud/jira/platform/webhooks/

**Secretless alternative: scoped API tokens**
- The user creates the token. Auth is Basic with email and token, against `api.atlassian.com/ex/jira/{cloudId}`.
- Since Dec 2024, tokens expire after at most 1 year. https://support.atlassian.com/atlassian-account/docs/manage-api-tokens-for-your-atlassian-account/
- Whether third-party apps may collect these tokens isn't addressed in the docs: **UNVERIFIED**.

---

## 8. If a secret is unavoidable (Notion, Atlassian; optionally Google and GitHub web flow)

Minimal token-exchange proxy, e.g. one Cloudflare Worker:
- **Endpoints.** Exactly two: `POST /exchange` (code + redirect_uri, plus code_verifier where supported) and `POST /refresh`. The proxy injects `client_secret`, forwards to the provider's token endpoint, and returns the response untouched. The desktop app then calls provider APIs directly.
- **Statelessness.** No logging of bodies, no token storage. The proxy only ever sees tokens in transit.
- **Redirect handling.** Redirect to a den-owned HTTPS page that bounces to `den://` or loopback. Bind `state` to the local session to prevent code injection.
- **Abuse.** Anyone can call the proxy to exchange codes minted for den's client_id. This is equivalent in power to a leaked secret, but revocable and rate-limitable. Add per-IP rate limits and allowlist redirect URIs.
- **Trust.** Users must trust den's operator not to log tokens. Mitigate by publishing the Worker source with reproducible deploys, and by offering a self-host or "bring your own client" option.
- **Precedents.**
  - VS Code has an optional token-exchange proxy for its `vscode://` flow (flows.ts, above).
  - Raycast reportedly runs a PKCE proxy for its extensions (oauth.raycast.com): **UNVERIFIED**, not researched.
  - Thunderbird and `gh` ship "public" secrets instead of running a proxy.

## 9. Apple Foundation Models (for briefing, todos, feed)

**Context**
- "context window of 4096 tokens per language model session". **Confirmed** by TN3193: https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window
- Latin-script text runs about 3–4 characters per token.
- Overflow throws `exceededContextWindowSize`. The fix is a new session with a condensed transcript.
- `SystemLanguageModel.contextSize` is back-deployed to 26.0; read it at runtime. https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/contextsize
- Larger context on the 27.0 model version: **UNVERIFIED** (see docs/research/apple-platform.md, where WWDC26 session 241 shows 8192).
- Implication: summarize each source separately (map), then merge short summaries (reduce).

**Guided generation**
- `@Generable` works on structs and enums, and `@Guide` adds constraints.
- Arrays and nested types are supported, and properties are generated in declaration order.
- Call `session.respond(to:generating:)`. "Constrained sampling prevents the model from producing malformed output."
- `[Todo]` works as a property of a wrapper struct.
- https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation

**Background**
- Allowed, but rate-limited. `rateLimited` "will only happen if your app is running in the background and exceeds the system defined rate limit". https://developer.apple.com/documentation/foundationmodels/languagemodelsession/generationerror/ratelimited(_:)
- An Apple forum reply says the limit applies on battery while in the background, and recommends `respond` over streaming. https://developer.apple.com/forums/thread/789788
- The budget size is **UNVERIFIED**.
- `NSBackgroundActivityScheduler` combined with FM isn't documented: **UNVERIFIED**. Plan to schedule fetches in the background and generate opportunistically, preferring AC power or foreground.
- `GenerationError` is deprecated in 27.0 in favor of `LanguageModelError` and related types.

**Availability**
- Check `SystemLanguageModel.availability`: `deviceNotEligible`, `appleIntelligenceNotEnabled`, `modelNotReady`.
- Requires M1 or later, Apple Intelligence enabled, a supported language, and 7 GB free storage. https://support.apple.com/en-asia/121115

## 10. Recommendation

| Provider | Recommended auth flow | Server needed? | Review burden | Risk |
|---|---|---|---|---|
| Slack | OAuth v2 + PKCE, `den://` redirect, user scopes (`search:read`, `im:history`, `mpim:history`), plus an optional "bring your own app" mode | No | Low (unlisted public distribution); Marketplace only to lift limits | **High**: 1 req/min, 15 msgs on history for non-Marketplace apps; 30-day refresh expiry; ToS ban on persistent indexes of other orgs' data |
| GitHub | Device flow (OAuth app: `notifications` + `repo`), or GitHub App device flow for least privilege | No | None | Low; `repo` is over-broad (read/write) |
| Google | Desktop client, loopback `127.0.0.1` + PKCE, public secret shipped (Thunderbird model) | No | **High**: restricted-scope verification for Gmail; CASA plausibly avoided if strictly on-device (UNVERIFIED with Google); 100-user / 7-day-token limits until verified | Medium-high |
| Microsoft | MSAL public client, `msauth.<bundle>://auth` + PKCE | No | Medium: publisher verification (free, needs CPP); tenant admin consent likely (MC1163922) | Medium; Teams unavailable for personal accounts |
| Linear | PKCE + localhost callback | No | None documented | Low |
| Notion | Token-exchange proxy, or paste of an internal-connection token | **Yes** (or paste) | Medium: public connection review required | Medium |
| Atlassian | User-created scoped API token (secretless, avoids 3LO points limits), or 3LO via proxy | No (API token) / **Yes** (3LO) | Low; unreviewed-app warning for 3LO | Medium; tokens expire ≤1 yr; third-party collection of API tokens not addressed (UNVERIFIED) |

**Session reuse** (cookies or `xoxc` against internal web APIs): don't. For Slack it is unsupported and arguably breaches the API ToS circumvention clause. For the other providers it wasn't researched: **UNVERIFIED**, treat it as the same risk class.

## 11. Session reuse for Gmail, Google Calendar and Notion (2026-09-28)

What den builds (by the user's decision, as for Slack and GitHub): each service reads through the session you signed in to inside den. Nothing is registered with Google or Notion, requests go only to the service, and nothing is kept beyond memory (except what you type into Settings). Sources were fetched on 2026-09-28; anything not confirmed is marked **UNVERIFIED**. None of this has been exercised against a signed-in real account: every flow is tested against local fakes (`MockServices`).

### Gmail: medium risk

- **Route.** Gmail's Atom feed, `GET https://mail.google.com/mail/u/<n>/feed/atom`, with the profile's Google cookies. One request per account per refresh (15 min while connected), plus up to 4 when connecting (one per signed-in account, found by walking `u/0`, `u/1`, …).
- **It's documented.** Google documents the feed at https://developers.google.com/workspace/gmail/gmail_inbox_feed ("Last updated 2026-09-03"): `GET https://mail.google.com/mail/feed/atom`, and "OAuth 2.0 is the preferred authentication method. Use the scope `https://mail.google.com/mail/feed/atom`". It says nothing about cookies. No deprecation notice on that page; elsewhere **UNVERIFIED**.
- **Caveat that matters.** The same page says: "This feed is only available for Gmail accounts on Google Workspace domains." Whether personal @gmail.com accounts still get it is **UNVERIFIED** (den's Gmail hover card has used the same feed since before this lane). If they don't, a personal account simply won't connect ("Sign in to Gmail…" stays).
- **The `/u/<n>/` form** for several signed-in accounts isn't on that page (**UNVERIFIED**); it is what Gmail's own URLs use.
- **What the feed can't say.** It lists unread inbox threads only: sender, subject, snippet, time. "Awaiting your reply" is therefore a heuristic: unread mail from a person, not from an automated sender. Whether the feed covers only the Primary tab when inbox categories are on is **UNVERIFIED**.
- **Terms.** Google's Terms (https://policies.google.com/terms, effective July 30, 2026) ban "using automated means to access content from any of our services in violation of the machine-readable instructions on our web pages (for example, robots.txt files that disallow crawling, training, or other activities)", and "bypassing our systems or protective measures". den fetches one documented feed for the signed-in user, at a person's pace, bypassing nothing; the cookie route rather than the documented OAuth scope is the gap. Verdict: **medium**.
- **Session signal.** The `SID` cookie (Google's cookie policy names `SID`/`HSID` as sign-in cookies, see dia-shortlist §1). Google rotates other cookies on most page loads, so while connected den only re-reads the cookie on a change, and a session whose feed failed once isn't probed again until `SID` changes.

### Google Calendar: low risk

- **Route, without any Calendar request.** den reads today's events from the calendar.google.com page you already have open (a favorite or pinned Calendar tab is the usual case): when it finishes loading, and on each briefing refresh while it's live, a script in an isolated world reads the event chips Google rendered (`[data-eventid]`, their aria-label: time range, title, date, a Meet/Zoom/Teams link). The page's own time zone and locale apply; events stay in memory for the day, so the tab may unload afterwards. Google's markup can change at any time: that is the fragility, not the terms.
- **Why not a request.** Checked 2026-09-28: `calendar/embed` renders events client-side (the HTML has no event data), and `calendar/htmlembed` now redirects to the marketing page. Google's internal calendar JSON endpoints are **UNVERIFIED** (no source found). The Calendar API needs OAuth.
- **Documented fallback: the secret iCal address.** Settings ▸ Connections ▸ Google Calendar takes the calendar's "Secret address in iCal format" (https://support.google.com/calendar/answer/37648): "Only you should know the Secret Address for your calendar. Do not share this address with other people", and "If you accidentally shared your calendar's Secret Address, click Reset". den stores it in its local settings (storage ns `calendar`) and sends it only to that address. For work accounts, "your admin might've changed the sharing settings for your calendar. If you can't find the Secret Address, ask your admin". Whether admins can switch it off entirely is **UNVERIFIED**. A public holiday calendar's `/public/basic.ics` was fetched to confirm the format (RFC 5545 from "Google Calendar 70.9054").
- **Limits of the fallback.** `TZID=` times are read in the Mac's zone (plugins have no time zone database); recurring rules cover what calendars write in practice (see `Plugins/calendar/ICS.swift`).
- **Verdict: low.** Reading a page the user has open adds no traffic; the address is an official feature.

### Notion: high risk

- **Route.** Notion's internal web API, the one its own app calls: `POST https://www.notion.so/api/v3/getSpaces {}` (workspaces and the account), then `POST /api/v3/getNotificationLogV2 {spaceId, size: 20, type: "unread_and_read", variant: "no_grouping"}` per enabled workspace and refresh, with the `token_v2` cookie and `x-notion-active-user-header`. Shapes come from open-source clients (notification-aggregator, opentabs, notion-py, acapela, NotionKeeper), not from Notion.
- **Checked against a live response (unauthenticated, public page).** `POST /api/v3/loadPageChunk` for Notion's public "Terms and Privacy" page (2026-09-28) returned records nested as `{spaceId, value: {value, role}}`: the newer nesting, which den unwraps (as well as the older `{value, role}`). The notification endpoint itself was not called (it needs an account).
- **No official alternative.** Notion's public API (https://developers.notion.com/reference/intro) has no notifications or mentions endpoint, and its OAuth needs a client secret and a reviewed public integration (§5).
- **Terms.** Notion's Personal Use Terms of Service (the "Terms and Privacy" page on notion.so, read 2026-09-28; notion.com/terms now redirects to a JavaScript-only app.notion.com page) list, among things you may not do: "use any robot, spider, crawlers or other automatic device, process, software or queries that intercepts, “mines,” scrapes or otherwise accesses the Service to monitor, extract, copy or collect information or data from or through the Service", and "duplicate, decompile, reverse engineer, disassemble or decode the Service". den's background read of your notifications is automated access to monitor and extract data, through an API learned by reverse engineering. Business workspaces fall under the Master Subscription Agreement instead (its full restriction list wasn't read: **UNVERIFIED**).
- **Verdict: high.** Unlike Slack (where a ban is arguable) this is a plain conflict with the text. Mitigations in the build: requests only to Notion, at most 1 + (workspaces) requests per 15 min, unread notifications only, nothing stored. **Decide before a release** whether Notion stays, stays opt-in only (no auto-connect), or waits for an official notifications API.

### Summary

| Service | Route | Requests (while connected) | Documented? | Terms risk |
|---|---|---|---|---|
| Gmail | Atom feed with the session | 1 per account per 15 min | Feed yes (OAuth preferred; "Workspace domains" only) | Medium |
| Google Calendar | The open Calendar page's DOM; secret iCal address as fallback | 0 (page) / 1 per 15 min (address) | Address yes; DOM no | Low |
| Notion | Internal `/api/v3` with `token_v2` | 1 + 1 per workspace per 15 min | No | **High** |
