# Extensions

den runs Chrome and Firefox extensions on WebKit, through Apple's `WKWebExtension`. Manifest v2 and v3, `chrome.*` and `browser.*`. [What works on WebKit](#what-works-on-webkit-and-what-doesnt) lists the extensions we test.

## Installing

**From the store.** Open an extension's page on the [Chrome Web Store](https://chromewebstore.google.com) or [Firefox Add-ons](https://addons.mozilla.org). The URL pill at the top of the sidebar shows **Add to den**. Click it. It works whatever the store's page says: the Chrome Web Store tells Safari-engine browsers to "Switch to Chrome" and greys out its own button, but den reads the extension from the page address and never needs the store's button.

<p align="center"><img src="../screenshots/extensions-add-to-den-pill.png" alt="Add to den in the URL pill on a Chrome Web Store page" width="560"></p>

den also swaps the store's own install button for **＋ Add to den** on the page itself, when the page shows one.

<p align="center">
  <img src="../screenshots/extensions-add-to-den-dark.png" alt="Add to den on the Chrome Web Store" width="400">
  <img src="../screenshots/extensions-add-to-den-amo-dark.png" alt="Add to den on Firefox Add-ons" width="400">
</p>

den shows what the extension can do, and what WebKit can't give it, before you confirm with **Add Extension**:

<p align="center"><img src="../screenshots/extensions-permission-prompt-dark.png" alt="Add extension prompt listing permissions" width="520"></p>

If an installed extension later asks for more access, den asks again ("wants more access" ▸ **Allow**).

**When something goes wrong.** den never fails quietly. If an install can't finish, or an extension installs but part of it won't start, a notice says so in plain words ("Vimium couldn't be installed: …"). **Details** shows the technical reason. den also writes it to `~/.den/logs/extensions.log`. An extension's page in **Extensions** lists its errors, and notes any features den can't give it ("Some features unavailable in den: bookmarks, history").

**From a file.** **Install Extension from File…** in the command bar takes an unpacked folder, or a `.crx`, `.xpi` or `.zip`.

**For development.** Put an unpacked extension folder (with its `manifest.json`) in `~/.den/extensions`. It loads with the permissions it asks for, no prompt. den reads that folder at launch. To reload after editing, turn the extension off and on.

## Using them

Hover the URL pill at the top of the sidebar: pinned extensions show there, with their badges, next to a puzzle-piece button for the rest. Click an icon for its popup; click outside or press Esc to close it.

<p align="center">
  <img src="../screenshots/extensions-menu-dark.png" alt="The extensions menu in the URL pill" width="400">
  <img src="../screenshots/extensions-popup-dark.png" alt="An extension popup" width="400">
</p>

## The Extensions page

Type **Extensions** in the command bar, or choose **Manage Extensions** from the puzzle menu.

<p align="center"><img src="../screenshots/extensions-page-dark.png" alt="The Extensions page" width="720"></p>

For each extension:

- **Site access**: On all sites, When you click it, or On specific sites
- its permissions
- **Pin to the URL bar**
- on/off, **Options**, **View in Store**, **Remove**

Remove never deletes a folder of yours in `~/.den/extensions`; delete the folder to uninstall it.

The page links to both stores, and its Settings section can turn off the **Add to den** button on store pages. **Get Extensions** in the command bar opens the Chrome Web Store.

## Updates

den checks store-installed extensions once a day (only if you have some). An update that asks for no new permissions installs quietly; one that wants more waits on its details page as **Update to \<version\>**. The update button at the top of the page checks now.

## What works on WebKit, and what doesn't

Tested in CI through the real store install (`Tests/PluginTests/ExtensionCompatTests.swift`, and `--scenario extensionsVerify`):

| Extension | Works? | What we checked |
|---|---|---|
| uBlock Origin Lite | Works | Blocks ad and tracker scripts on a test page; on a YouTube watch page no ad request is made (one was before). Its filters, page scripts and "optimal" filtering mode all load |
| uBlock Origin (full) | Not on WebKit | Installs from Firefox Add-ons and its popup opens, but it can't block: it needs to stop web requests, which Safari's engine doesn't allow. den says so on its store page and offers uBlock Origin Lite. The Chrome Web Store no longer offers it |
| Dark Reader | Works | Firefox build darkens a page; Chrome build starts and its popup opens |
| JSON Formatter | Works | Formats a JSON page |
| 1Password | Partial | Installs, starts, popup opens; sign in inside the extension. Unlocking with the 1Password app doesn't work yet: the app only talks to browsers signed by an Apple developer account (den isn't yet) |
| SponsorBlock | Works | Starts; popup opens ("No YouTube video found" off YouTube) |
| Return YouTube Dislike | Works | Starts; popup opens |
| Grammarly | Partial | Starts; popup opens. Signing in (`identity`) isn't available |
| LanguageTool | Works | Starts; popup opens |
| Raindrop.io | Works | Starts; popup opens |
| Vimium (Chrome Web Store) | Works | Link hints (`f` follows a link, `F` opens it in a new tab, `Esc`), scrolling (`j`, `d`, `G`, `gg`), the Vomnibar (`o`), find (`/`), next tab (`K`). Not in den: bookmarks (the Vomnibar finds none), history from before you installed it |
| Vimium (Firefox Add-ons) | Works | Same as above; its toolbar icon shows an error, because that build lacks the icons Vimium asks for outside Firefox. Prefer the Chrome Web Store build |
| ColorPick Eyedropper | Partial | The popup opens; its background doesn't start, so picking colors doesn't work |
| Bitwarden | Partial | Installs, starts, and its popup shows Log in. Signing in, filling and unlocking with the desktop app aren't checked yet (they need a real account) |

An extension's keyboard shortcuts work: they're listed, with their keys, in the **Extensions** menu in the menu bar. Its right-click items show at the end of a page's right-click menu.

den fills some gaps itself, in its own copy of each extension, so an extension that touches a missing API keeps running instead of stopping silently: events WebKit leaves out (such as `webNavigation.onHistoryStateUpdated`, which stopped Vimium), an empty `bookmarks`, a `history` of pages visited since the extension was added, `sessions` for tabs closed since then, and `search`. Folders in `~/.den/extensions` are left exactly as they are.

WebKit's extension support is good but not Chrome's. These don't exist on WebKit:

- **blocking `webRequest`**: so full **uBlock Origin can't work**. Use **uBlock Origin Lite**, which does.
- `identity`, `downloads`, side panels, offscreen documents; den's real `history` and `bookmarks`.

### Password managers and other desktop apps

Some extensions talk to an app on your Mac, for example a password manager's extension asking its desktop app to unlock with Touch ID (native messaging). den does this the way Chrome does: when the desktop app has set itself up for Chrome, Chromium, Brave, Edge, Vivaldi, Arc or Firefox, den finds that and connects the extension to it. Nothing to set up in den.

- **Bitwarden:** turn on browser integration in the Bitwarden desktop app (Settings ▸ Allow browser integration), then "Unlock with biometrics" in the extension. den asks once whether the extension may talk to apps on your Mac.
- **1Password:** works in the extension on its own (sign in with your account password). Unlocking with the 1Password app needs a den signed by an Apple developer account, which isn't there yet; 1Password then lets you add den under Settings ▸ Browser ▸ Add Browser.
- **Only for den:** put the app's manifest (`<name>.json`) in `~/.den/NativeMessagingHosts`.

What happened is in `~/.den/logs/extensions.log` (each connection, refusal and exit). Details: [research notes](../research/password-managers.md).
