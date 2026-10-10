# Updates

den updates in two pieces:

- **Plugins** (tabs, the command bar, peek, …) hot-swap while den runs. Your tabs stay put.
- **The app itself** needs a relaunch, and den picks a moment when you won't notice.

> [!NOTE]
> The only release so far is the pre-release **0.1.0-alpha.1**. The `stable` channel has nothing to find yet, so if you installed the alpha, set `channel = "prerelease"` to get the next one.

## Channels

Set one in `~/.den/config.toml`:

```toml
[updates]
channel = "stable"          # stable | prerelease (also the Updates settings panel)
check_hours = 6             # release channels: how often to check
relaunch_background_s = 60  # relaunch once den has been in the background this long…
relaunch_idle_min = 10      # …or when den is frontmost but you haven't touched it this long
```

With no `channel`, den uses `stable`. The first check runs a minute after launch. Changing the channel in the Updates settings panel writes it back to config.toml.

| Channel | What you get |
|---|---|
| `stable` | Signed releases. The app through Sparkle, plugins as signed downloads |
| `prerelease` | The same, plus releases tagged like `0.1.0-alpha.1` |

## Checking by hand

Type **Check for Updates…** in the command bar (⌘T). den shows "Checking for updates…", then "den is up to date" or what it's installing. The About panel (den ▸ About den) shows the version, the channel and the last check.

## When den restarts

When a new app version is ready you get a toast: **den updated — restart to apply**, with a **Restart** button. If you don't click it, den restarts on its own when the first of these happens:

- den hasn't been the frontmost app for 60 s. It relaunches in the background and doesn't steal focus.
- den is frontmost, but there's been no keyboard or mouse input for 10 minutes.

It never restarts while media is playing. Your spaces, tabs and selection come back.

## Plugin updates are checked

Every downloaded plugin is checked against its sha256 and an EdDSA signature before it's written to disk. A plugin that fails to start is rolled back, and one that crashed den is refused at the next launch and rolled back too. That build is never installed again.

## Opening a downloaded build

den is signed ad hoc and not notarized yet, so Gatekeeper blocks a copy downloaded with a browser the first time. Right-click den.app ▸ **Open**, then confirm in System Settings ▸ Privacy & Security. Or:

```sh
xattr -dr com.apple.quarantine /Applications/den.app
```

Because each ad-hoc build is signed differently, macOS may ask again for permissions you granted den (camera, microphone, …) after an app update.

---

The full design, including the host API checks and `scripts/release.sh`, is in [docs/updates.md](../updates.md).
