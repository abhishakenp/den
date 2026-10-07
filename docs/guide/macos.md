# den and your Mac

What den does with the rest of macOS: Spotlight, Handoff, Shortcuts, website permissions, password manager apps. Some of it needs den to be signed with an Apple developer account, which it isn't yet; each section says so.

## Spotlight

Press ⌘Space and type part of a tab's title or address: your open den tabs and your spaces show up. Pick one and den comes forward on that tab (or space).

- Only tabs in your sidebar, never anything from a private window. No page content goes into Spotlight, just titles and addresses.
- Turn it off in Settings ▸ General ▸ **Show tabs and spaces in Spotlight**. Everything den put there is removed at once.

## Handoff

The page you're on is offered to your iPhone and iPad (with the same Apple Account and Handoff on): it shows in their app switcher, and Safari opens it there. Pages from Safari on your iPhone come to den when den is your Mac's default browser.

- Never from a private window. Turn it off in Settings ▸ General ▸ **Hand off pages to your other devices**.
- Not tested with an iPhone yet. Apple shares Handoff between apps of the same developer account, so den → iPhone may need den to be signed with one.

## Shortcuts and Siri

den has actions for Shortcuts: Open URL in den (in a space), New Tab in den, Switch Space, Find Tabs, Open Tab, Get Current Page (its title and address, for automations) and Toggle Picture in Picture, with Siri phrases like "New tab in den".

**Not available yet:** macOS lists an app's actions only when the app is signed with an Apple developer account. They're built into den and turn up in Shortcuts as soon as den is signed that way.

## Website permissions

Sites ask before using your camera, microphone, location or notifications; see [Privacy & passwords](privacy-and-passwords.md#camera-microphone-and-sign-in-prompts). Notifications appear in Notification Center while the site is open in a tab.

## Password manager apps

Extensions such as Bitwarden can unlock through their desktop app; see [Extensions](extensions.md#password-managers-and-other-desktop-apps). 1Password's app only talks to browsers signed with an Apple developer account.

## Not yet

- **iCloud sync** of spaces, pinned tabs and settings: not built yet, and CloudKit needs den signed with a developer account to run at all. Until then den's `cloud` service reports sync as off (`reason: "signing"`) rather than pretending.
- **Passkeys:** need Apple's browser passkey approval; see [Privacy & passwords](privacy-and-passwords.md#passkeys).
