# Getting started

den runs on **macOS 26 Tahoe or later**, on the WebKit that ships with macOS.

## Install

### Download

The first pre-release, **0.1.0-alpha.1**, is on [GitHub Releases](https://github.com/abhishakenp/den/releases/tag/v0.1.0-alpha.1). Download `den-0.1.0-alpha.1.dmg`, drag den to Applications, then right-click den ▸ **Open** the first time (den isn't notarized yet; see [below](#if-macos-wont-open-den)).

It's an alpha. To get the next alpha as an update, put this in `~/.den/config.toml` (den creates the file on first launch):

```toml
[updates]
channel = "prerelease"
```

Without it den stays on the `stable` channel, which has no release yet. See [Updates](updates.md).

### Build from source

You need:

- Xcode 26 (Swift 6.2 or later)
- A Swift toolchain with the **Embedded Swift** stdlib, for the plugins. Xcode's toolchain doesn't include it: get one from [swift.org](https://www.swift.org/install/macos/) or with `swiftly`.

```sh
git clone https://github.com/abhishakenp/den.git
cd den
scripts/install.sh       # build, run the tests, install to /Applications/den.app, launch
```

`scripts/install.sh` only installs a build that passed its tests. To just try den without installing, `scripts/run.sh` builds `build/den.app` and launches it; `scripts/run.sh --demo` does the same with throwaway demo spaces and tabs.

To stay on the latest `main` automatically, see [Updates](updates.md#following-main-developers).

## First run

den opens straight into a browser. No sign-up, no account, no wizard.

<p align="center"><img src="../screenshots/main-dark.png" alt="den on first run" width="720"></p>

You start with:

- Three spaces, **Personal**, **Work** and **Side Project**, each with its own colors. Their icons are at the bottom of the sidebar; swipe sideways in the sidebar to move between them.
- Four favorites shared by every space: GitHub, Gmail, Calendar and YouTube.
- A few example tabs and a **Reading** folder in Personal, to try things on. ⇧⌘K clears the Today ones. For a pinned one, right-click ▸ **Unpin Tab**, then ⌘W.
- A `~/.den` folder for your own [config, themes and plugins](den-home.md).

Then:

1. **⌘T** opens the [command bar](command-bar.md). Type a site, a search, or a command.
2. **⌘D** pins a tab you want to keep. Unpinned tabs live in **Today** and archive themselves after a day. Nothing's lost: they're in the Library (⇧⌘L), and ⇧⌘T brings the last one back.
3. **⌘,** opens Settings.
4. Skim [Tips & hidden gems](tips.md). Most of what makes den fast isn't visible until you know it's there.

On your second launch a small **New to den?** card at the bottom of the sidebar offers a 1-minute tour (five steps, skip any of them). Close it and it's gone for good; **Take the den Tour** in the command bar brings it back. After that, den shows a one-time tip now and then when a shortcut would help; **Settings ▸ General ▸ Show tips** turns them off ([Tips](tips.md#den-teaches-you-as-you-go)).

## Importing

Importing from Arc, Chrome or Safari isn't built yet. When it is, den offers it as a quiet one-click card at the bottom of the sidebar, never as a step you have to get through. For now, sign in to the sites you use as you visit them; den offers to save each password to your Keychain ([Passwords](privacy-and-passwords.md#passwords-the-touch-id-vault)).

## Make den your default browser

Any of these:

- The banner at the bottom of the command bar: **Set den as default**.
- **Try for a week** in the same banner: den becomes your default, remembers your old browser, and after 7 days asks once whether to keep den or switch back.
- den ▸ **Make den Your Default Browser** in the menu bar.
- Settings ▸ General ▸ **Default browser** ▸ **Make den Default**.

macOS asks you to confirm. The banner's × hides it for good; Settings ▸ Search ▸ **Offer to make den your default browser** brings it back.

Once den is the default, links from other apps open as a normal tab in your current space. Prefer a small floating window? Turn on [Little Arc](peek-split-little-arc.md#little-arc-a-mini-window-for-links-from-other-apps).

## If macOS won't open den

den is signed ad hoc and not notarized yet. A build you made yourself opens normally. A copy downloaded with a browser needs right-click ▸ **Open** the first time, or:

```sh
xattr -dr com.apple.quarantine /Applications/den.app
```

## Uninstall

Quit den, then delete `/Applications/den.app` and `~/.den`. Its tabs, settings and installed extensions are in `~/Library/Application Support/den`. Saved passwords are Keychain items, which you can remove in Keychain Access.
