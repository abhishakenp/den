# Extensions

den runs Chrome and Firefox extensions on WebKit, through Apple's `WKWebExtension`. Manifest v2 and v3, `chrome.*` and `browser.*`. We've verified uBlock Origin Lite (it blocks ads), ColorPick Eyedropper and Dark Reader.

## Installing

**From the store.** Open an extension's page on the [Chrome Web Store](https://chromewebstore.google.com) or [Firefox Add-ons](https://addons.mozilla.org). The URL pill at the top of the sidebar shows **Add to den**. Click it. It works whatever the store's page says: the Chrome Web Store tells Safari-engine browsers to "Switch to Chrome" and greys out its own button, but den reads the extension from the page address and never needs the store's button.

<p align="center"><img src="../screenshots/extensions-add-to-den-pill.png" alt="Add to den in the URL pill on a Chrome Web Store page" width="560"></p>

den also swaps the store's own install button for **＋ Add to den** on the page itself, when the page shows one.

<p align="center">
  <img src="../screenshots/extensions-add-to-den.png" alt="Add to den on the Chrome Web Store" width="400">
  <img src="../screenshots/extensions-add-to-den-amo.png" alt="Add to den on Firefox Add-ons" width="400">
</p>

den shows what the extension can do, and what WebKit can't give it, before you confirm with **Add Extension**:

<p align="center"><img src="../screenshots/extensions-permission-prompt.png" alt="Add extension prompt listing permissions" width="520"></p>

If an installed extension later asks for more access, den asks again ("wants more access" ▸ **Allow**).

**When something goes wrong.** den never fails quietly. If an install can't finish, or an extension installs but part of it won't start, a notice says so in plain words ("Vimium couldn't be installed: …"). **Details** shows the technical reason. den also writes it to `~/.den/logs/extensions.log`. An extension's page in **Extensions** lists its errors, and notes any features den can't give it ("Some features unavailable in den: bookmarks, history").

**From a file.** **Install Extension from File…** in the command bar takes an unpacked folder, or a `.crx`, `.xpi` or `.zip`.

**For development.** Put an unpacked extension folder (with its `manifest.json`) in `~/.den/extensions`. It loads with the permissions it asks for, no prompt. den reads that folder at launch. To reload after editing, turn the extension off and on.

## Using them

Hover the URL pill at the top of the sidebar: pinned extensions show there, with their badges, next to a puzzle-piece button for the rest. Click an icon for its popup; click outside or press Esc to close it.

<p align="center">
  <img src="../screenshots/extensions-menu-dark.png" alt="The extensions menu in the URL pill" width="400">
  <img src="../screenshots/extensions-popup.png" alt="An extension popup" width="400">
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
| uBlock Origin Lite | Works | Blocks ad and tracker scripts on a test page |
| Dark Reader | Works | Firefox build darkens a page; Chrome build installs and starts |
| JSON Formatter | Works | Formats a JSON page |
| Vimium (Chrome Web Store) | Partial | Works: link hints (`f`, `F`, `Esc`), scrolling (`j`, `d`, `G`, `gg`), the Vomnibar (`o`), find (`/`), next tab (`K`). Not in den: bookmarks (the Vomnibar finds none), history before you installed it |
| Vimium (Firefox Add-ons) | Partial | Same as above; its toolbar icon shows an error, because that build lacks the icons Vimium asks for outside Firefox. Prefer the Chrome Web Store build |
| ColorPick Eyedropper | Partial | The popup opens; its background doesn't start, so picking colors doesn't work |
| Bitwarden | Not yet | Installs, but its background doesn't start (it needs `offscreen`, `sidePanel`, `idle` and more). den tells you so when you add it |

den fills some gaps itself, in its own copy of each extension, so an extension that touches a missing API keeps running instead of stopping silently: events WebKit leaves out (such as `webNavigation.onHistoryStateUpdated`, which stopped Vimium), an empty `bookmarks`, a `history` of pages visited since the extension was added, `sessions` for tabs closed since then, and `search`. Folders in `~/.den/extensions` are left exactly as they are.

WebKit's extension support is good but not Chrome's. These don't exist on WebKit:

- **blocking `webRequest`**: so full **uBlock Origin can't work**. Use **uBlock Origin Lite**, which does.
- `identity`, `downloads`, side panels, offscreen documents; den's real `history` and `bookmarks`.

And these aren't wired into den yet:

- an extension's own keyboard shortcuts (`commands`)
- an extension's items in right-click menus

Extensions that talk to a desktop app through native messaging (for example a password manager's desktop integration) need a bridge den doesn't have yet. See [Coming soon](coming-soon.md).
