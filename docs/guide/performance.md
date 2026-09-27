# Performance

den tries to cost nothing it doesn't have to. Plugins load when used, web pages load when opened, and background tabs are unloaded. This page gives the numbers we've actually measured, and how.

> [!WARNING]
> **The launch times below were measured on a loaded machine.** Other builds were running the whole time, and the 1-minute load average never dropped below 4 (4.4 at best). All three browsers were launched in turn under the same load, so the comparison is fair, but the absolute times are inflated. Memory depends much less on load. A re-run on a quiet machine is on the list.

## The numbers

Measured 2026-09-27 on a MacBook Air (M3, 8 cores, 16 GB), macOS 26.5, on AC power. Memory is `phys_footprint` (what Activity Monitor shows), summed over the app and every helper process it owns, including WebKit's WebContent, Networking and GPU processes. Sampled 10 s after the first window appears.

### Launch to first window (warm)

Median of the 6 least-loaded rounds (load 4.7–7.9):

| | Median | Range |
|---|---|---|
| **den** | **209 ms** | 185–238 ms |
| Dia 1.50.1 | 653 ms | 563–923 ms |
| Arc 1.166.0 | 2147 ms | 2058–2190 ms |

### Memory

| State | den | Arc | Dia |
|---|---|---|---|
| Idle, no tabs | **20.0 MB** (no WebKit process running at all) | 189.0 MB (empty space) | 614.7 MB (sign-in screen) |
| One page (example.com) | **79.8 MB** | 366.8 MB | not measured |
| 200 unloaded tabs | 35.7 MB | | |

- An unloaded tab costs about **80 KB** ((35.7 − 20.0) MB / 200). The goal is 8 KB, so this is still being worked on.
- Idle CPU with no tabs: 0.2 % median, 0.1 wakeups/s.
- Dia's copy was never signed in, so every Dia number is its sign-in screen, and there's no valid Dia one-page number.

## Not measured yet

- Launch times on a quiet machine.
- Cold launch (it needs `sudo purge`).
- Energy (`powermetrics` needs root). CPU time and wakeup counters were used instead.

## Why it's small

- **Plugins load lazily.** Settings, connections, previews and the briefing build nothing until you use them.
- **Idle tabs unload** after 5 minutes in the background by default (Settings ▸ Tabs, or 0 to turn it off). An unloaded tab keeps its history, scroll position and a snapshot on disk, and reloads when you come back; its WebKit process exits. Tabs on screen, tabs playing media or in picture in picture, tabs using the camera or microphone, and tabs with unsaved form input never unload.
- **Nothing polls** until you connect an account.

## Measure it yourself

```sh
scripts/perf.sh [den.app]               # check against docs/perf/budgets.json
scripts/measure-memory.sh main          # memory of den and its WebKit processes
scripts/perf/compare.sh <outdir> den=… dia=… arc=…   # the interleaved comparison
```

Every run, raw value, command and caveat is in [docs/perf/baseline.md](../perf/baseline.md).
