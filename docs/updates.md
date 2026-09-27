# Updates

den updates in two ways:

- **Host updates** replace the app (`den.app`), and take effect after a relaunch.
- **Plugin updates** replace plugin dylibs, and hot-swap without a relaunch.

Pick a **channel** in `~/.den/config.toml`:

```toml
[updates]
channel = "stable"          # stable | prerelease | follow-main
check_hours = 6             # release channels: how often to check
relaunch_background_s = 60  # relaunch after den has been in the background this long…
relaunch_idle_min = 10      # …or when den is frontmost but there's been no input for this long
# plugins_url = "…"         # override the plugin manifest (testing)
```

When `channel` isn't set, it's `follow-main` if the developer updater is installed, otherwise `stable`.

## Who does what

The host stays generic ([architecture/thin-host.md](architecture/thin-host.md)):

- **The `updates` plugin** (`Plugins/updates`) holds all policy and UI: the channel, the schedule, which plugins to install, rollbacks, the "den updated — restart to apply" toast with its **Restart** button, when to relaunch, the **Check for Updates…** command, and the text in the About panel.
- **The host `updates` service** (`Sources/DenHost/Updates`) does only native work:
  - conditional fetches (ETag)
  - sha256 and EdDSA checks
  - atomic placement in `~/.den/updates/plugins`
  - the Sparkle bridge
  - kicking the developer updater

  Its API is in [host-api.md](host-api.md#updates).

## Relaunch rule (host updates)

den never relaunches while media is playing. Otherwise it relaunches when one of these happens first:

- den has **not been frontmost for 60 s**. It relaunches in the background (`open -g`, `--relaunched --background`), so it doesn't steal focus.
- den is frontmost, but there's been **no keyboard or mouse input for 10 min**.
- The user clicks **Restart** in the toast.

The session (spaces, tabs, selection) comes back from plugin storage. The rule is checked every 15 s, and only while an update is waiting.

## Release channels: `stable` and `prerelease`

`scripts/release.sh <semver>` publishes a release. A `-` suffix makes it a pre-release, for example `0.1.0-alpha.1`. The script:

1. Runs `swift test` and `scripts/bundle.sh`, and refuses a dirty tree.
2. Builds `den-<v>.zip` (`ditto -c -k --keepParent`) and `den-<v>.dmg`.
3. Uploads every plugin as its own asset, plus `plugins.json`: id, version, abi, hostAPI, sha256, EdDSA signature, url and permissions for each.
4. Runs `gh release create`, with release notes built from the commits since the last tag.
5. Updates `updates/appcast.xml` and `updates/plugins.json` on `main` and pushes them. den polls these stable URLs:
   - `https://raw.githubusercontent.com/abhishakenp/den/main/updates/appcast.xml` (`SUFeedURL`)
   - `https://raw.githubusercontent.com/abhishakenp/den/main/updates/plugins.json`

**Signing.** Releases are signed with EdDSA (ed25519) through Sparkle's `generate_keys --account den`, which stores the private key in the login Keychain. The key is never committed or exported. Info.plist carries the public key as `SUPublicEDKey`, and den uses the same key to verify plugin downloads.

**Host updates (Sparkle 2).** den has no Sparkle windows. A custom user driver turns each stage into an `updates.sparkle` event:

- The plugin checks on its schedule. `found` → it downloads in the background. `ready` → it shows the toast and waits for the relaunch rule.
- Sparkle's own scheduler is off (`SUEnableAutomaticChecks = false`).
- Pre-release items carry `<sparkle:channel>prerelease</sparkle:channel>` and are offered only on that channel.
- Sparkle quits den without the quit dialog, installs, and relaunches. Unlike den's own relaunch, Sparkle's may take focus.

**Plugin updates.** One conditional GET of `plugins.json` per check: `304 Not Modified` when nothing changed. For each plugin in the channel's entry that is built for the running host (`hostAPI` equal) and whose sha256 differs from the loaded file:

1. The host downloads it.
2. It checks the sha256 and the EdDSA signature against `SUPublicEDKey`. A file that fails either check is never written.
3. It writes `<id>.json` (hostAPI, permissions), then `<id>.dylib`, with a temp file + rename, keeping the previous pair as `<id>.prev.*`.
4. It hot-swaps the plugin.

If the new build doesn't become active, the plugin rolls it back. If it crashed den, cordis refuses it at the next launch (`lastCrash`) and the plugin rolls it back then. Either way that sha256 is never installed again.

`~/.den/updates/plugins` is the **managed** layer, separate from your own `~/.den/plugins`, which always win over it:

bundled < Application Support < managed < `~/.den/plugins/<id>.dylib` < source folders < `--dev-plugins`

## Host API safety

- `scripts/bundle.sh` stamps `DenHostAPI` into Info.plist: the number of commits that changed `Sources/` or `Package.*`.
- Every managed plugin's `<id>.json` names the `hostAPI` it was built for, and it loads only into a host of exactly that generation:
  - newer: **deferred** until den restarts on the new host
  - older: **superseded** by the new bundle
- After an update replaces `/Applications/den.app`, the running (older) host also ignores the new bundle's plugins, whose on-disk `DenHostAPI` differs. When nothing compatible is left, the running plugin stays.
- cordis still checks its own C ABI (`abi` in each plugin manifest) when it loads a plugin.

## Developer channel: `follow-main`

`scripts/updater.sh install` installs a user LaunchAgent, `io.github.abhishakenp.den.updater`:

- It runs `updater.sh check` every 150 s, and at login, at nice 10. Nothing runs between checks. Throttled I/O (`ProcessType=Background`, i.e. `taskpolicy -b`, or `LowPriorityIO`) is opt-in (`DEN_UPDATER_PROCESS_TYPE=Background scripts/updater.sh install`): while other processes kept the disk busy, it left a plugin build that takes 12 s with about 20 s of CPU in 11–12 minutes.
- **Check for Updates…** starts it immediately (`launchctl kickstart`).
- `scripts/updater.sh uninstall` removes it.

Each check:

1. `git ls-remote` of `origin/main`. When nothing changed, that's the whole check.
2. On a new commit, it builds **only that pushed commit** in its own clone `~/.den/src` (den's watcher ignores that folder), and diffs it against the last deployed commit:
   - **Only `Plugins/**` changed:** it builds the affected plugins with cordis-build (`Plugins/Shared` means all of them) and runs their `swift test` suites. It then places them in `~/.den/updates/plugins` with the commit's `hostAPI`, and the running den hot-swaps them (same pid).
   - **`Sources/`, `Package.*`, `Resources/` or `scripts/bundle.sh` changed:** it runs the full `swift test` and `scripts/bundle.sh`, installs with `ditto` (next to the old app, then swaps it in), and removes the follow-main plugin builds the new bundle supersedes. den shows the toast and applies the relaunch rule.
   - **Anything fails:** nothing is deployed, the last good version stays, and `~/.den/logs/updater.log` says why. That commit isn't retried until `main` moves.
     - A test run that crashed is run again once.
     - Failed tests are re-run once on their own, because WebKit and latency tests are timing-sensitive.
     - When the 1-minute load is above twice the core count, a failure isn't held against the commit, and the next check tries again.
3. Results go to `~/.den/updates/state.json`. The About panel shows the deployed commit, when it was deployed and the last check. `state.json` is written only when something changed, or when you asked for a check, so an idle check never wakes den.

## Gatekeeper without notarization

den is signed ad hoc (`codesign --sign -`). No Developer ID is set up yet, and notarization is postponed.

- **Downloading a release:** a zip or DMG downloaded with a browser gets the quarantine attribute. On first launch Gatekeeper refuses an ad-hoc-signed, un-notarized app. Open it with right-click → Open (then confirm in System Settings → Privacy & Security), or run `xattr -dr com.apple.quarantine /Applications/den.app`.
- **Sparkle updates:** den downloads them itself, and Sparkle verifies the EdDSA signature before installing. The replacement app isn't quarantined, so it launches without a prompt. Each ad-hoc build has a different designated requirement, so macOS privacy permissions (TCC) granted to den may be asked for again after a host update.
- **Plugin updates:** only EdDSA-verified dylibs are written, and they are loaded with `disable-library-validation`, which den's hardened runtime entitlements already allow.
- **With a Developer ID:**
  1. Sign with `codesign --options runtime --sign "Developer ID Application: …"`.
  2. Notarize with `xcrun notarytool submit --wait`, then `xcrun stapler staple`.
  3. Sparkle then also checks that the update's Team ID matches the running app's, TCC permissions persist across updates, and downloads open without warnings. The EdDSA keys stay as they are.
