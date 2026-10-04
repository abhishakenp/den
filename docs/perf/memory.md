# Memory: discarded tabs and the mini player

> The mini player measured below was removed: den now uses WebKit's native picture in picture (`--scenario pipAway` / `pipInline`). The numbers are kept as history.

Measured on 2026-09-27/28 on macOS 26.5 (Apple silicon) with `scripts/measure-memory.sh`. It
launches den through LaunchServices (`open -g`, `--background`: no focus stolen), so den is the
"responsible" process of its WebKit processes, which `scripts/lib/denprocs.swift` finds (WebKit's
XPC services are children of launchd, so ppid can't). `footprint` then sums den and all of them.
Pages are the demo tabs (live sites), so totals move with what those sites serve. Other agents
were compiling on the same Mac the whole time: the load average is next to every number, and it
reached 600, so treat single numbers as ±10%.

`base` is the build before this work (127dbf8), `new` is this branch rebased on main (c897ee5).

| Scenario | Command | base | new | loadavg (1 min) |
|---|---|---|---|---|
| den only, no web view | `measure-memory.sh blank 12` | – (no such scenario) | den **22 MB**, no WebKit process | 201 |
| 1 active tab (apple.com/macos) | `measure-memory.sh main 15` | 276 MB (den 31, WebContent 207) | 279 MB (den 32, WebContent 206) | 285 / 216 |
| 10 tabs, 1 active + 9 discarded | `SETTLE=15 measure-memory.sh load10discard` | 1091 MB: 9 WebContent processes still alive (the old discard waited for a snapshot a detached view can't take) | **304 / 315 MB** (two runs): 1 WebContent (198), den 40 / 42 | 261 / 194, 191 |
| 10 tabs, all live | `measure-memory.sh load10` | 1049 MB (10 WebContent) | – | 13 |

**Per discarded tab:** (304…315 − 279) / 9 ≈ **3–4 MB** in total, of which den's own share is
≈ 1 MB (den 40–42 MB vs 32 MB with one tab; that includes the favicons and state of 10 page
loads). What den keeps per discarded tab is its record (URL, title, favicon URL) and the
`interactionState` blob: **750 bytes** for a two-page history with a scroll position
(`--scenario discard`). The snapshot lives on disk only: 1280 px JPEG, **233 KB** for a
text-heavy page.

**Process exit:** a discarded page's WebContent process exits a few seconds after its WKWebView
is released (WebKit's timing), before and after this work alike: polling `denprocs` every second
after 9 discards went 10 → 8 → 5 → 3 → 1 over 8 s (new) and 9 → 3 → 1 at 6–7 s (base), at a load
average of ~500.

**Launch** (`--measure-launch`, 12 interleaved runs each, same flags): vs 127dbf8, median
822.9 ms base / 767.2 ms new (loadavg 384 → 428). vs main c897ee5 after the rebase, two rounds:
414.5 / 433.2 ms (loadavg 114) and 418.6 / 412.3 ms (loadavg 97 → 109). Within the noise.

## den's own memory

- The old discard kept a full-size `NSImage` of every discarded page in den's memory. Now a
  snapshot is taken once, when a page leaves the screen, rendered by WebKit at its final size
  (640 pt = 1280 px), encoded off the main thread, written to disk, and dropped.
- **HEIC leaks:** ImageIO's HEIC encoder kept ~4 MB of den's memory per encode (12 regions,
  +51 MB `MALLOC_LARGE` after 10 tab switches; den 90–95 MB). With JPEG: none (den 39 MB, same
  run). HEIC files were ~40% smaller (148 KB vs 247 KB at JPEG 0.6), but disk is cheaper than RAM.
- The encoder's freed buffers stayed in den's footprint as "reclaimable" `MALLOC_LARGE` (18 MB):
  den calls `malloc_zone_pressure_relief` after each encode. den with 9 discarded tabs went from
  62–73 MB to 42–47 MB.
- At utility QoS a busy Mac starved the encode for seconds; it runs at userInitiated (~10 ms).

## Mini player

`CPU=1 measure-memory.sh miniOff` (the video keeps playing in its hidden tab, setting off) vs
`CPU=1 measure-memory.sh mini` (the same video in the mini player), before the rebase:

| | miniOff | mini |
|---|---|---|
| total | 311 MB | 388 MB |
| den | 40 MB | 37 MB |
| WebContent (video tab) | 20 MB | 25 MB |
| GPU process | 33 MB | 103 MB |
| CPU, den + WebKit, mean of 10 s | 4.4% | 8.9% |
| loadavg | 375 | 462 |

The difference is the video being decoded and drawn on screen again (the GPU process); den adds
nothing, and no process: the tab's own web view moves into the panel. The page script sends
playback updates only while the player shows it (≤ 4 a second, on `timeupdate`).

**Debounce** (den away / back, `--scenario miniPlayer`): the notifications for one change arrive
within 35 ms (hide → resign active 17 ms → occlusion 21 ms; unhide → occlusion 33–49 ms;
miniaturize → occlusion 3 ms). den acts on a window state that held for **200 ms**, 6x that
burst: the player opened 226–263 ms after den resigned or hid, and the video was back inline
211–321 ms after den returned. A shorter away-and-back never opens it.
