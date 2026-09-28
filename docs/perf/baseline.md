# den performance baseline (vs Dia and Arc)

Measured 2026-09-27, 19:11–22:30 local. Every number below comes from runs executed that evening. The
raw logs stayed in a scratch directory and are not committed.

> **These numbers are tainted.** Other agents' Swift builds were running on this machine for the whole
> session. The 1-minute load average stayed above 4 for the entire time: 4.4 at best, 840 at worst.
> The measurement gate (1-min load < 4 and no `swift-build`/`swift-frontend`/`cordis-build` process)
> waited 30 minutes twice and never passed. Launch rounds were interleaved (den, Dia, Arc, den, …), so
> all three apps saw the same load. That keeps the comparison fair, but it inflates absolute launch
> times. The load average is recorded next to every run. Re-run `scripts/perf/compare.sh` and
> `scripts/perf.sh` on a quiet machine before treating any launch time here as a real baseline.
> Memory footprint depends much less on load than launch time does.

## Environment

| | |
|---|---|
| Machine | Mac15,12 (MacBook Air, M3), 8 cores, 16 GB (`sysctl hw.model hw.ncpu hw.memsize`) |
| macOS | 26.5 (25F71) |
| Power | AC power, battery 100% charged (`pmset -g batt`) |
| den | `/Applications/den.app` build from 19:42:37, frozen as a copy (`den` binary sha256 `af593a4c…77846d80`) so later reinstalls could not change it mid-run |
| Dia | 1.50.1, a local copy outside /Applications. Its profile was at the **sign-in screen** ("What's your email?") |
| Arc | 1.166.0, a local copy. Its profile opened to an empty "Space 1" (no tabs) |
| Load | per run in the tables (1-min load average) |

Neither Dia nor Arc was running beforehand (`pgrep -x Dia` / `pgrep -x Arc` was checked before every
launch), so neither was skipped. Only instances started by the tool were quit (by PID).

## Method (identical for all three apps)

Tool: `scripts/perf/perfprobe.swift` (build it with `swiftc -O scripts/perf/perfprobe.swift -o perfprobe`).

- **Launch to first window.**
  1. `NSWorkspace.openApplication` starts a **new instance** of the bundle (`createsNewApplicationInstance`, not activated).
  2. `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` is polled **every 1 ms** until an on-screen window appears that is owned by a *new* process running that bundle's executable (layer 0, at least 100×100 pt, alpha > 0).
  3. Two times are recorded:
     - `reqMs`: from the LaunchServices request to the window. This is what a Dock click costs.
     - `startMs`: from the kernel's process start time (`kinfo_proc.p_starttime`) to the window.
  4. After 1 s the instance is quit (NSRunningApplication `terminate`, force after 10 s), and the probe waits for its helper processes to exit.
  - Launches are warm: one discarded warm-up round, then 12 rounds, interleaved round-robin across the apps.
- **Memory.** `phys_footprint` from `proc_pid_rusage` (the number `footprint` and Activity Monitor report). It was cross-checked against `footprint -p`, which gave 90 MB for a WebContent process the probe measured at 90.2 MB.
  - The probe sums the app process plus every process whose parent chain **or** `responsibility_get_pid_responsible_for_pid` leads to it. That covers Chromium's `Browser Helper*` processes and WebKit's `com.apple.WebKit.{WebContent,Networking,GPU}` XPC services, which launchd spawns on den's behalf.
  - **host** = the app process alone.
  - The sample is taken 10 s after the first window appears.
- **Idle CPU and wakeups.** Starting right after the memory sample, the probe takes the delta of `ri_user_time + ri_system_time` and `ri_pkg_idle_wkups + ri_interrupt_wkups` over 30 s, summed over the same process tree.
  - Cross-check: `top -l 2 -s 30 -stats pid,command,cpu,idlew,power -pid <den>` reported 0.0% CPU and 0 IDLEW for the tab-less den. The probe reported 0.05% and 0.1 wakeups/s for the same process.
- **1-page state.** `NSWorkspace.open([https://example.com], withApplicationAt:)` launches a new instance that is handed the URL. Every on-screen window of the process is logged after settling, which shows where the page went:
  - Arc showed "Example Domain" in a Little Arc window.
  - This den build opened it in its peek panel (a layer-3 window).
  - Dia stayed on its sign-in screen, so **Dia has no valid 1-page number**.
- **State control for den.** Every den run uses a throwaway `--storage` copy of a template store. The user's store and `~/.den` are never touched. `scripts/perf/denstore.swift` derives two more templates from den's first-run store:
  - `empty-tabs`: zero tabs.
  - `tabs 200`: 200 never-loaded tabs with nothing selected, which is how a discarded tab restores.
  - Its encoder writes Cordis' Value codec, and the output was checked by decoding it back.

### Exact commands

```sh
# all three, interleaved (writes raw logs + summary.txt to <outdir>)
RESET_den="rm -rf $S/denrun && cp -R $S/dentemplate $S/denrun" ROUNDS=12 MEMREPS=3 \
  scripts/perf/compare.sh <outdir> den=<frozen den.app>@--storage,$S/denrun dia=<Dia.app> arc=<Arc.app>
# den-only states
perfprobe mem <den.app> --settle 10 --cpu 30 -- --storage <copy of empty store>
perfprobe mem <den.app> --settle 10 --cpu 30 -- --storage <copy of 200-tab store>
perfprobe mem <den.app> --settle 10 --cpu 30 --url https://example.com -- --storage <copy of empty store>
# regression check against docs/perf/budgets.json
scripts/perf.sh [den.app]
```

## Results

### Launch to first on-screen window (warm), ms

The least-loaded rounds are the last 6 of the first interleaved run (load 4.7–7.9). "All 12" includes rounds at load up to 363.

| app | rounds | reqMs median | p90 | min | max | startMs median |
|---|---|---|---|---|---|---|
| **den** | least-loaded 6 | **209.3** | 238.1 | 185.2 | 238.1 | 199.5 |
| Dia | least-loaded 6 | 652.8 | 923.0 | 562.7 | 923.0 | 644.1 |
| Arc | least-loaded 6 | 2146.8 | 2189.7 | 2058.1 | 2189.7 | 2099.3 |
| den | all 12 (run 1) | 235.6 | 372.3 | 185.2 | 386.3 | 224.8 |
| Dia | all 12 (run 1) | 936.2 | 1814.9 | 562.7 | 2065.8 | 926.0 |
| Arc | all 12 (run 1) | 2320.2 | 3377.6 | 2058.1 | 4282.1 | 2265.6 |
| den | all 12 (run 2, load 199–431) | 472.4 | 598.4 | 432.5 | 668.3 | |
| Dia | all 12 (run 2) | 2178.4 | 2629.4 | 1977.0 | 2918.7 | |
| Arc | all 12 (run 2) | 4646.5 | 5381.6 | 4059.2 | 5609.2 | |

Raw run 1 values, as reqMs/startMs@1-min load, in launch order:
- den: 372.3/335.9@110 386.3/340.2@363 361.2/315.2@143 317.4/295.6@62 243.7/233.2@29 227.4/217.6@12.6 202.5/194.2@7.5 204.9/195.5@5.4 213.7/203.5@5.9 185.2/176.9@5.1 238.1/227.3@6.9 233.0/222.3@5.1
- Dia: 2065.8/2045.6@96 1814.9/1799.6@332 1307.0/1290.6@135 949.5/938.2@51 1004.0/993.8@24 1032.1/1020.8@11.0 923.0/913.7@6.4 643.9/635.4@5.0 661.8/652.8@5.8 562.7/553.0@4.7 671.1/661.0@7.2 611.8/601.1@4.8
- Arc: 4282.1/4168.5@225 3371.4/3289.5@311 3377.6/3288.5@133 2807.8/2752.3@47 2582.2/2526.9@22 2450.7/2390.7@11.3 2189.7/2137.7@6.2 2186.6/2140.5@4.8 2115.9/2068.8@5.8 2177.6/2129.8@7.9 2097.0/2050.0@7.3 2058.1/2007.2@5.6

The warm-up round (discarded) ran at 19:41 on the previous install. The reinstall landed at 19:42:37, before round 1 (the gate log shows 19:42:44), so all 12 den rounds used the frozen build.

### Memory (phys_footprint, MB) and idle CPU

| app / state | n | total median | p90 | min | max | host (app process) | idle CPU % median (max) | wakeups/s median (max) | load during |
|---|---|---|---|---|---|---|---|---|---|
| **den, no tabs** | 5 | **20.0** | 21.5 | 19.6 | 21.5 | 20.0 (no WebKit process exists) | 0.2 (0.3) | 0.1 (0.4) | 175–580 |
| den, 200 discarded tabs | 3 | 35.7 | 36.9 | 35.6 | 36.9 | 35.7 | 0.3 (0.5) | | 221–757 |
| **den, 1 page** (example.com) | 3 | **79.8** | 81.1 | 79.1 | 81.1 | 28.3 | 0.6 (0.9) | | 207–842 |
| den, first-run seeded store (apple.com/macos live) | 3 | 283.9 | 321.6 | 278.7 | 321.6 | | 0.4 (1.5) | | 169–392 |
| Dia, sign-in screen, idle | 6 | 614.7 | 721.3 | 456.5 | 721.3 | | 4.1 (14.3) | 23.1 (24.1) | 4.4–285 |
| Dia, "1 page" (still sign-in; invalid) | 6 | 697.5 | 791.0 | 593.3 | 791.0 | | | | 5–565 |
| Arc, empty Space, idle | 6 | 189.0 | 190.7 | 185.3 | 190.7 | | 1.3 (2.3) | 15.7 (21.1) | 4.4–270 |
| Arc, 1 page (example.com in Little Arc) | 6 | 366.8 | 386.1 | 321.4 | 386.1 | | | | 6–389 |

Raw memory totals (MB@load):
- den, no tabs: 19.7, 20.0, 19.6@234, 21.5@514, 20.4@474. The two runs without a recorded load were at 161–516.
- den, 200 tabs: 35.7@318, 35.6@652, 36.9@268.
- den, 1 page: 79.8@619, 81.1@842, 79.1@207.
- den, seeded: 321.6@169, 283.9@379, 278.7@392.
- Dia idle: 614.5@4.6, 614.9@22, 721.3@8.5, 711.4@88, 461.8@265, 456.5@286.
- Dia "page": 684.0, 791.0, 621.3, 716.6, 593.3, 711.1.
- Arc idle: 185.3@4.4, 188.6@12, 189.9@8.7, 189.4@130, 188.2@269, 190.7@224.
- Arc page: 366.7, 385.3, 386.1, 363.3, 321.4, 366.9.

Derived from these runs:
- **Per discarded tab** (host with 200 never-loaded tabs − host with none) / 200 = (35.7 − 20.0) / 200 = **80 KB**. `scripts/perf.sh` measured 84.5 KB.
- **den vs reference, idle:**
  - Dia's sign-in screen uses 614.7 MB, **31× den with no tabs**.
  - Arc's empty Space uses 189.0 MB, **9.5×** den with no tabs.
- **den vs reference, 1 page:** Arc uses 366.8 MB, **4.6×** den (79.8 MB).
- **den vs reference, launch:**
  - Dia takes **3.1×** den's time (652.8 vs 209.3 ms, least-loaded rounds).
  - Arc takes **10.3×** den's time (2146.8 vs 209.3 ms).

### Not measured, and why

- **Launch times on a quiet machine:** the load never dropped below 4 (see the note at the top).
- **Cold launch:** clearing the file cache needs `sudo purge` (`purge` without root returned "Operation not permitted"). A fresh copy of an app bundle is still in the page cache, so it is not meaningfully cold either.
- **powermetrics / energy:** `powermetrics must be invoked as the superuser`. Kernel CPU time and wakeup counters, plus `top`, were used instead.
- **Dia with a page loaded, and Dia's real browsing window:** the copy is not signed in and stops at the "What's your email?" screen. Typing into it is off limits. Every Dia number describes that screen only.
- **Arc 1-page vs idle** compares an empty Space with a Little Arc window. Arc was never signed out, so this was its natural state.
- **den run 1 memory rows are excluded.** They reused one store, and each URL opened in one run was restored by the next. From run 2 on, every den run starts from a clean copy of a template store.

### Known limitations of the harness

- Test instances launch without activation, like `open -g`. den (this build) calls `NSApp.activate()` itself, though. While `scripts/perf.sh` ran, den was the frontmost app in 5 of 60 two-second samples. A test flag that keeps den in the background would need a den code change, which this measurement work did not make. Later builds have one, `--background` (`Sources/Den/main.swift`, used by `scripts/measure-memory.sh`); `scripts/perf.sh` doesn't pass it yet.
- This den build shows a quit dialog in response to the quit AppleEvent, so the probe force-quits it after 10 s. Later builds quit cleanly on SIGTERM.

## 2026-09-28: lazy plugins, Scenarios trait (launch before/after)

Same machine. `scripts/perf.sh` (10 warm launches after 1 warm-up, seeded store), run back to back:
**before** = a bundle of `a493736` (frozen copy), **after** = `a4eec49` (first-frame plugins only,
setup in `willFinishLaunching`, SF Symbols prewarm, no Scenarios/Network.framework). The gate wanted
load < 4; "before" started at 5.2, so its row is marked TAINTED (a slightly slower machine than "after").

| build | load (1-min) at start | reqMs median | p90 | min | max | startMs median |
|---|---|---|---|---|---|---|
| before `a493736` (TAINTED) | 5.22 | 219.8 | 228.5 | 201.4 | 228.5 | 210.9 |
| after `a4eec49` | 2.75 | **195.6** | **206.9** | 188.2 | 206.9 | 185.7 |

Earlier the same session, at load 25–60, the in-process trace (`DEN_TRACE=1`, not load-proof)
showed where the time went before the change: `DenRuntime.init` ~70 ms (mostly the first `NSWindow`
and its theme frame), plugin loading 45–70 ms (15 dlopen + apply, 13 of them not needed for the
first frame), then an idle gap until LaunchServices' open event. An interleaved A/B at load ~30
(12 pairs, `trace display`) measured the SF Symbols prewarm at 249.8 vs 268.6 ms median.

Binary (`ls -l`, `otool -L`, `nm`): `den` 4,938,624 → 5,049,360 B (+110 KB: this build also has
the commits that landed on main in between: media, mini player, page tools). Network.framework and
the 143 `MockServices` symbols are gone from the release binary. The bundle is 12.3 → 13.1 MB (`du`).

**No-tabs memory (resolved, see "Energy lane" below).** On the CI runner the lazy-plugin launch
costs nothing at idle, and neither suspect does; what made den's idle memory jump was a launch that
compiles content rule lists. The same perf.sh run measured noTabs host 19.1 MB (before) and
23.5 MB (after), which fails the 21.5 MB budget. An interleaved recheck (`perfprobe mem`, seeded store,
10 s settle, n=3 each, load 3–27) gave before 31.0/30.3/30.2 MB and after 36.0/32.9/32.6 MB. So
"after" costs about +2.5–5 MB at idle. Suspects, not yet bisected: the symbol prewarm (catalog
mapped on a second thread), all 13 deferred plugins loading at first frame together with the webviews,
and main's new features between the two builds. discardedTab.KB (84.5 → 87.6) and onePage.totalMB
(84.5 → 89.0) fail in both builds.

## Tab close (⌘W) and white flash, 2026-09-28

Measured by `CloseLatencyTests` and `FlashTests` (`scripts/test.sh --filter …`), debug build, load average 15–30 (a busy machine; compare only runs taken together).

| Check | Before (origin/main `13f2863`) | After |
|---|---|---|
| ⌘W, key to next tab in the content area (60 Today tabs, 400 archived; median / p90 of 25) | 27.6 / 29.0 ms | 28.9–29.7 / 31.8–33.1 ms (three runs) |
| White pixels in the content card while a dark page loads (6 window snapshots, dark appearance) | 0.000 then 1.000 ×5 (white until WebKit's first paint) | 0.000 ×6 |

Close time is dominated by creating the next tab's `WKWebView`; what the change removed is one extra sidebar render (≈3 ms measured per `renderPage` with this sidebar) and the second snapshot of the closed page (asynchronous, so it doesn't show in the key-to-screen time). Launch and memory weren't re-measured with `scripts/perf.sh`: the load average stayed above 6 throughout.

## Energy lane, 2026-09-28

All numbers from the **perf lab** on GitHub's `macos-26` runner (Apple M1 (Virtual), 3 cores,
7 GB, macOS 26.6; [docs/dev.md](../dev.md#perf-lab-memory-ab-and-bisection)): `scripts/perf/lab.sh`,
5 launches per scenario from a fresh copy of the store, medians, den's own process
(`phys_footprint`, "host"). The runner is a different machine from the M3 above, so compare
before/after within a row only. The template store is made by a first launch that runs 20 s,
so its Shields rule lists are compiled, like any launch after the first.

| den process, MB (n=5 medians) | before (`main` 3308f1e) | after | runs |
|---|---:|---:|---|
| no tabs | 20.2 | **18.2** | [before/after](https://github.com/abhishakenp/den/actions/runs/36381480029), [final](https://github.com/abhishakenp/den/actions/runs/36392006343) |
| 200 discarded (never-loaded) tabs | 37.2 | **21.7** | same |
| **per discarded tab** ((200 tabs − none) / 200) | **85 KB** | **17.5 KB** | same |
| a launch that compiles the Shields lists (first launch, or after a list update), 40 s after | 74.3 | **18.6** | [36385726026](https://github.com/abhishakenp/den/actions/runs/36385726026), [final](https://github.com/abhishakenp/den/actions/runs/36392006343) |
| one page (example.com), 45 s after | 25.7 | **23.3** | same |
| one page + uBlock Origin Lite, 45 s (before) / 90 s (after) | 99.1 | **36.1** | same |

`scripts/perf.sh` in the CI job agrees: `discardedTab.KB` 84.5 on `main` before
([36371902598](https://github.com/abhishakenp/den/actions/runs/36371902598)) and 15.9 after
([36392020597](https://github.com/abhishakenp/den/actions/runs/36392020597)).

**The no-tabs regression.** On the runner, neither suspect moves idle memory: no tabs 18.8 MB
without the SF Symbols prewarm ([36373724566](https://github.com/abhishakenp/den/actions/runs/36373724566)),
19.0 MB with every plugin loaded before the first frame (`lab/eager`) and 18.8 MB with the prewarm
([36378297538](https://github.com/abhishakenp/den/actions/runs/36378297538)). What does move it is a
launch that compiles content rule lists: WebKit's compiler peaked at 282–351 MB in den's process and
malloc then kept 32–38 MB of freed large blocks (`MALLOC_LARGE (empty)` in `vmmap`) dirty for the
whole session. The lab caught it whenever the store had no compiled lists (46–57 MB "empty" runs).
`malloc_zone_pressure_relief` did not release those blocks (72.1 vs 74.2 MB); turning malloc's
large cache off did: `emptycompile` 71.1 MB, `@MallocLargeCache=0` 18.5 MB,
`@MallocDeferredReclaim=0` 71.8, `@MallocAggressiveMadvise=1` 72.6
([36388177155](https://github.com/abhishakenp/den/actions/runs/36388177155)). den now ships
`MallocLargeCache=0` in Info.plist's `LSEnvironment`.

**uBlock Origin Lite** (+73 MB in den's process). It isn't the controller or a live context: `heap`
counted 10.3 MB allocated in the default zone. WebKit converts uBOL's declarativeNetRequest rules
to content rule lists in den's process (peak 550–622 MB), and the same large-block cache kept
39 MB plus fragmented small blocks. `ubo` 100.8 MB, `@MallocLargeCache=0` 35.8 MB
(36388177155), and 36.1 MB with the Info.plist setting: uBOL now costs +12.8 MB over the same page.
Whether a persistent controller (the real profile) recompiles at every launch was not measured.

**Per discarded tab** (85 → 17.5 KB). `heap` of 200 tabs against none showed every tab owning a
full row of views (≈8 NSViews with layers, labels, tracking areas) and a context menu carried in its
row's node. Now the sidebar virtualizes `tabRow`/`splitRow` (views only within 200 pt of the visible
area; 39 of 200 rows made in `ServiceTests.longListsAreVirtualized`) and tab menus are built on
right-click (`ui.menu`). What's left per tab: the tabs plugin's record, the storage cache's copy,
the host's `WebRecord` (256 B) and the row's node value, 2.26 MB of live heap for 200 tabs
(11 KB each), plus malloc fragmentation.

**Dark mode** (`darkbench`, a generated 300-image page, 1200×800 window, the page's WebContent
process, n=5, [36381480029](https://github.com/abhishakenp/den/actions/runs/36381480029)):

| sheet | 2.5 s after load | peak while scrolling | 3 s after |
|---|---:|---:|---:|
| none | 31.3 | 89.1 | 75.9 |
| den's (root filter + media re-inverted) | 35.2 | 106.3 | 60.2 |
| root filter only (photos inverted) | 31.0 | 86.3 | 60.7 |
| media re-inverted only near the viewport (script) | 34.6 | 102.5 | 60.7 |

The root filter costs nothing measurable; re-inverting media costs +3.9 MB after load and +17 MB
at the scroll peak, and nothing once settled. Compositing layers for the media (`will-change`)
measured worse (peak 151–158 MB, n=3). The runner draws at 1x; the +136 MB in
`docs/research/dark-mode.md` was a 2x Mac under load, which the runner can't reproduce. The sheet
is unchanged.

**Power assertions.** `pmset -g assertions` taken while den idled with example.com, with uBOL, and
with the first-run store listed none from den or its WebKit processes.

**Not measured:** launch time with `MallocLargeCache=0` in isolation (the CI job's launch numbers
moved with the runner's load: 214–507 ms), energy (`powermetrics` needs root), a real 2x display.
