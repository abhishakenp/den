# Memory Budgets

> Per-feature memory budgets tracked by the `performance` service (`Sources/DenHost/Services/PerformanceBudgets.swift`).
> The service reports usage, alerts on exceedance, and suggests cleanup actions.

## Overview

den allocates a memory budget to each feature area to ensure the browser stays within a
predictable footprint. The `performance` service (`"performance"` host service) exposes methods
to query usage, set custom budgets, record per-feature consumption, and get cleanup suggestions.

```swift
// Query a feature's usage
runtime.call("performance", "usage", ["feature": "tabs"])
// → {feature: "tabs", budgetMB: 128, usedMB: 45, ratio: 0.35}

// Full report of all features
runtime.call("performance", "report")
// → {features: [...], total: 312, totalBudgetMB: 656}

// Record memory usage for a feature
runtime.call("performance", "record", ["feature": "tabs", "usedMB": 45])

// Get cleanup suggestions when budgets are exceeded
runtime.call("performance", "suggestions")
// → {actions: [{feature: "tabs", reason: "Memory budget at 92%", benefitMB: 56, action: "unloadDiscardedTabs"}]}
```

## Default Budgets

| Feature | Budget (MB) | Description |
|---|---|---|
| `host` | 64 | Host framework (Cordis, UI, services) |
| `tabs` | 128 | Tab state, favicons, session history |
| `webviews` | 256 | WKWebView objects + backing stores (not WebContent) |
| `extensions` | 96 | Extension processes + native memory |
| `plugins` | 64 | Plugin VM state |
| `shields` | 16 | Content rules, filter data |
| `connections` | 16 | Connection state, feed data |
| `commandbar` | 8 | Search index, suggestions cache |
| `spaces` | 4 | Space state, workspace config |

**Total: 656 MB** — derived from den's baseline numbers in `docs/perf/budgets.json`.
With a no-tabs footprint of ~21.5 MB and one-page total of ~81 MB, the per-feature budgets
allow for heavy usage before alerting.

## Auto-cleanup

When a feature's usage reaches 85%+ of its budget, the `suggestions` method recommends:

1. **`unloadDiscardedTabs`** — Discards inactive tabs to reclaim tab-state memory.
2. **`reloadExtensions`** — Reloads extensions to clear accumulated extension memory.
3. **`memoryRelief`** — Calls `malloc_zone_pressure_relief` to return freed buffers to the OS.

Alerts fire at 90% usage. Cleanup suggestions at 85%. The `memoryRelief` helper
(`Sources/DenHost/Core/MemoryRelief.swift`) runs on a background queue and returns buffers
from the snapshot encoder's allocations.

## Setting Custom Budgets

```swift
// Increase the tabs budget
runtime.call("performance", "setBudget", ["feature": "tabs", "budgetMB": 256])

// List all budgets
runtime.call("performance", "listBudgets")
```

## Recording Usage

Features record their usage via the `record` method. The `recordSystemMemory()` internal method
approximates den's per-feature memory split using `ProcessInfo` for total RSS and heuristic
proportions for each feature area. Plugin cores and host services call `record` when they
allocate significant memory.

```swift
// Example: a tab plugin records its own memory after loading a page
performance.recordUsage(feature: "tabs", usedMB: 12.5)
```

## Integration with MemoryRelief

The `MemoryRelief` helper (`soon(after:)`) returns freed buffers to the system on a
background queue. It's called after snapshot encodes and during cleanup suggestions.
den also disables malloc's large-block cache via `MallocLargeCache=0` in Info.plist's
`LSEnvironment`.

## Monitoring

For production monitoring, the `report` method returns a complete breakdown:

```json
{
  "features": [
    {"feature": "commandbar", "budgetMB": 8, "usedMB": 2.1, "ratio": 0.26, "alert": false},
    {"feature": "connections", "budgetMB": 16, "usedMB": 5.4, "ratio": 0.34, "alert": false},
    {"feature": "extensions", "budgetMB": 96, "usedMB": 42.0, "ratio": 0.44, "alert": false},
    {"feature": "host", "budgetMB": 64, "usedMB": 28.3, "ratio": 0.44, "alert": false},
    {"feature": "plugins", "budgetMB": 64, "usedMB": 31.5, "ratio": 0.49, "alert": false},
    {"feature": "shields", "budgetMB": 16, "usedMB": 3.2, "ratio": 0.20, "alert": false},
    {"feature": "spaces", "budgetMB": 4, "usedMB": 1.1, "ratio": 0.28, "alert": false},
    {"feature": "tabs", "budgetMB": 128, "usedMB": 52.7, "ratio": 0.41, "alert": false},
    {"feature": "webviews", "budgetMB": 256, "usedMB": 87.4, "ratio": 0.34, "alert": false}
  ],
  "total": 253.7,
  "totalBudgetMB": 656
}
```

## Related

- `docs/perf/budgets.json` — Absolute performance targets (launch time, footprint, CPU)
- `docs/perf/memory.md` — Memory measurement methodology and historical data
- `Sources/DenHost/Core/MemoryRelief.swift` — `malloc_zone_pressure_relief` helper
- `Sources/DenHost/Services/PerformanceBudgets.swift` — Service implementation