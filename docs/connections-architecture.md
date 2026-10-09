# Connection System — Architecture Summary

## Overview

The connection system enables den to read user's third-party services (Slack, GitHub, Gmail, Calendar, Notion, Linear, Jira, Confluence, RSS) **through the user's session cookies inside den's built-in browser**. No OAuth, no den-hosted servers, no accounts. This is a "cookie proxy" architecture.

---

## Core Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│  den (Electron app)                                              │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  DenHost (Swift) — Cordis plugin host                    │   │
│  │  ┌───────────────────────────────────────────────────┐  │   │
│  │  │  DenRuntime — plugin host entry point             │  │   │
│  │  │  plugins.call(service, method, args)  ← central   │  │   │
│  │  └──────────────────────────┬────────────────────────┘  │   │
│  │                             │                           │   │
│  │  ┌──────────────────────────┼────────────────────────┐  │   │
│  │  │  Plugin Loader           │  Plugin Sandbox Service │  │   │
│  │  │  • Bundle/user/home/dev  │  • XPC bridge          │  │   │
│  │  │  • Manifest caching      │  • Per-plugin profiles │  │   │
│  │  └──────────────────────────┼────────────────────────┘  │   │
│  │                             │                           │   │
│  │  ┌──────────────────────────┼────────────────────────┐  │   │
│  │  │  Session Service         │  Lazy Plugins           │  │   │
│  │  │  • Cookie watcher        │  • Stub generator       │  │   │
│  │  │  • WKWebsiteDataStore    │  • arm/wake/disarm     │  │   │
│  │  └──────────────────────────┴────────────────────────┘  │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Plugins/ (dylibs)                                       │   │
│  │  ┌─────────────┐ ┌──────────────┐ ┌────────────────┐  │   │
│  │  │ connections │ │    slack     │ │     github     │  │   │
│  │  │  (dylib)    │ │   (dylib)    │ │   (dylib)      │  │   │
│  │  └─────────────┘ └──────────────┘ └────────────────┘  │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                 │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │  Web Helper (JavaScript)                                │   │
│  │  • runWebHelper() — runs in browser iframe              │   │
│  │  • scrape(), fetch(), extract() via web view            │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Data Flow

### 1. Plugin Discovery & Loading

```
App launch → PluginLoader.loadAll()
  └→ Search paths:
      1. Bundled plugins     (app/Contents/PlugIns/*.dylib)
      2. User plugins         (~/.config/den/plugins/*.dylib)
      3. Home directory       (~/den/plugins/*.dylib)
      4. Dev override         (DEN_PLUGINS_DIR env)
  └→ For each dylib:
      - Load manifest from <id>.json sidecar
      - Cache manifest in memory
      - Grant sandbox exemptions (first-frame plugins)
  └→ Load deferred plugins on demand (deferred mode)
```

**Load modes** (from manifest `launch` field):
- `firstFrame` — loaded on first frame render, always unsandboxed (spaces, tabs, connections sheet)
- `deferred` — loaded after app enters foreground, sandboxed if policy demands
- `lazy` — registered as stub first, real plugin loaded on first real call

### 2. Lazy Plugin Stubs

```
Sidecar manifest exists → StubService.generateStubs()
  └→ For each declared service/key/command/event:
      - Register stub handler on plugins.call()
      - Stub forwards: {service, type: "lazy_request", id, ...}
  └→ Plugin runtime: "arm" (watches for lazy requests)
  └→ First real call:
      - Stub detects lazy_request → loads real plugin
      - Unregisters stub, registers real handler
      - Forwards original call
  └→ Timeout: "wake" (re-arm stub if load fails)
  └→ Cleanup: "disarm" (disable stub if unused)
```

Sidecar manifests declare `services`, `events`, `commands`, `keys`, `settings` — these drive automatic stub generation.

### 3. Connection Lifecycle

```
User signs into service (e.g., github.com)
  │
  ▼
SessionService.WKWebsiteDataStore observer
  └→ Detects new cookies for domain
  └→ Fires: session.cookiesChanged { cookies, domains, domainCookieDict }
  │
  ▼
PluginLoader / LazyPlugin coordinator
  └→ Finds matching plugin by domain
  └→ If lazy: wakes the real plugin
  │
  ▼
ConnectionsCore.probe(provider, cookies)
  └→ runWebHelper(scrape, url, cookies, selector)
  └→ If page returns HTML (not auth wall) → connected
  └→ Store accounts in storage namespace "connections"
  │
  ▼
UI: Sheet appears
  └→ Connected → "Disconnect" button
  └→ Pending → "Cancel" button
  └→ Not connected → "Connect" button
  └→ Undo toast: "Connected to GitHub" with undo (comma-separated provider IDs)
```

**Probe config**:
- `connectTimeoutMs`: 15 minutes (max probe duration)
- `probeEveryMs`: 3 seconds (retry interval for pending connections)

### 4. Plugin-to-Host Communication

```
Plugin (dylib)                    Host (DenRuntime)
─────────────                     ─────────────
rt.call("ui", ...) ──stdin────►   plugins.call("ui", ...)
rt.call("tabs", ...)──stdout────►  plugins.call("tabs", ...)
rt.call("storage", ...)           └→ Route to ServiceLayer

Framing: Native messaging protocol
  - Length-prefixed 32-bit integer (big-endian)
  - Followed by JSON bytes
  - stdin for plugin → host
  - stdout for host → plugin
```

`plugins.call(service, method, args)` is the central routing entry point in `DenRuntime`.

### 5. Sandbox Model

```
Plugin manifest declares: sandbox: true (or global policy)
  │
  ▼
PluginSandboxService.startPlugin()
  └→ Launches plugin as separate XPC process
  └→ Creates XPC endpoint with plugin identifier
  │
  ▼
PluginXPCProtocol
  └→ Host call: plugins.call(service, method, args)
  └→ XPC dispatches: plugin.call(service, method, args)
  └→ Bidirectional — plugin can also call host services
```

**Sandbox exemption**: First-frame plugins (spaces, tabs, connections) always run unsandboxed in the main process. This is because the connections sheet renders inside the web view's first frame.

### 6. Connection API

Plugins and host communicate via `rt.call("connections", ...)`:

```typescript
// Connect to a provider
rt.call("connections", "connect", { provider: "github" })

// Get connection status
rt.call("connections", "get", { provider: "github" })

// List all connections
rt.call("connections", "list")

// Open connection settings
rt.call("connections", "open", { provider: "github" })

// Close/disconnect
rt.call("connections", "close", { provider: "github" })
```

### 7. Provider State Management

```
Provider state stored in:
  └→ Storage namespace: "connections"
  └→ Storage key: "accounts"
  └→ Value: { providerId: { userId, displayName, avatarUrl, ... } }

Token storage:
  └→ In-memory only (attached to provider object in ConnectionsCore)
  └→ NOT persisted to disk
  └→ Retrieved via cookie scraping on each probe
```

### 8. ConnectionsCore Structure

```swift
class ConnectionsCore {
  // Provider registration
  + registerProviders()
  + registerProvider(id, config, scrapeFn)
  
  // Lifecycle
  + apply(context)         // Called by plugin host
  + dispose()              // Cleanup
  
  // Core logic
  + probe(provider, cookies)    // Scrape page, determine connected/pending
  + connect(providerId)          // Initiate connection flow
  + disconnect(providerId)       // Remove account, show toast
  + undoDisconnect()             // Restore from undo buffer
  
  // UI
  + sheetTree()         // Build sheet hierarchy
  + renderConnected()   // "Connected" state UI
  + renderPending()     // "Pending" state UI
  + renderNotConnected() // "Not connected" state UI
  
  // Commands
  + registerCommand()  // Retry loop: 500ms × 60 = 30s max
  
  // Feed integration
  + feedItems()        // Rank items: important → kind → recency → affinity
}
```

### 9. Ranking System

```
Feed item ranking order:
  1. Important items  — always survive feed cuts (hardcoded providers)
  2. Kind (group)     — items grouped by provider type
  3. Recency          — newer items preferred
  4. Affinity         — actor/where based scoring (capped)

Important providers survive even when feed is truncated.
```

### 10. Briefing Integration

```
Briefing runs at:
  - 8:00 AM daily (initial)
  - Every 15 minutes while connected
  
Auto-connect triggers:
  - Cookie detected → probe → connect
  - Briefing picks up new items from connected services
```

---

## Key Files

| File | Role |
|------|------|
| `Plugins/connections/ConnectionsPlugin.swift` | Plugin entry point (17 lines) |
| `Plugins/connections/ConnectionsCore.swift` | Core logic (521 lines) |
| `Tests/PluginTests/ConnectionsTests.swift` | E2E tests (950 lines) |
| `Sources/DenHost/DenRuntime.swift` | Plugin host, `plugins.call()` routing |
| `Sources/DenHost/Plugins/PluginLoader.swift` | Plugin discovery & loading |
| `Sources/DenHost/Plugins/LazyPlugins.swift` | Lazy stubs, arm/wake/disarm |
| `Sources/DenHost/Services/PluginSandboxService.swift` | XPC lifecycle, sandbox |
| `Sources/DenHost/Services/SessionService.swift` | Cookie watcher, session events |
| `Sources/DenHost/Extensions/NativeMessaging.swift` | Host bridge, framing protocol |

---

## Supported Providers

Slack, GitHub, Gmail, Calendar, Notion, Linear, Jira, Confluence, RSS — each with its own plugin dylib, sharing the `connections` core logic.

## Verification

**VERIFIED: All source files read in full** — ConnectionsPlugin.swift (17 lines), ConnectionsCore.swift (521 lines + tail sections), ConnectionsTests.swift (950 lines + tail sections), PluginLoader.swift, LazyPlugins.swift, DenRuntime.swift, SessionService.swift, PluginSandboxService.swift, NativeMessaging.swift, PluginXPCProtocol.swift, connections-and-briefing.md, ConnectionScenarios.swift.