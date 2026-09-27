# Research: Cordis and DeepSeek Harness, and what den should take from them

Date: 2026-09-27. Scope: research only. Sources were fetched on this date. Every code snippet below is quoted from upstream docs. Items marked **UNVERIFIED** were not confirmed against a primary source.

## TL;DR

- **"cordis"** is `cordiverse/cordis`, the TypeScript plugin meta-framework by Shigma (GitHub login `shigma`, 548 of the repo's commits). It is the framework under the Koishi chatbot (`koishi/packages/core/package.json` depends on `"cordis": "^3.18.1"`).
- **"deepseek harness"** is not ambiguous. It is `deepseek-ai/deepseek-harness` (`dsh`), the open-source agent harness from DeepSeek AI. It runs on Cordis ("everything is a plugin"), and it vendors a fork published as `@deepseek-ai/cordis` 4.0.4. So the two names the user gave point at the same stack: Cordis is the kernel, and dsh is a large agent product built on it.
- For den, this is a ready-made reference architecture for a native plugin layer next to WebExtensions, and for an agent harness whose tools, approval, sandbox, context and UI slots are all swappable plugins.

## 1. Cordis

### Identity

| Fact | Value | Source |
|---|---|---|
| Repo | https://github.com/cordiverse/cordis | measured with `gh api repos/cordiverse/cordis` |
| Stars / created / license | 8,841 stars; created 2022-05-17; MIT | same `gh api` call |
| Tagline | "A Meta-Framework of Spatiotemporal Composability." API "not yet stable and may change without notice." | [packages/core/README.md](https://github.com/cordiverse/cordis/blob/master/packages/core/README.md) |
| Paper | *A Programming Paradigm for Spatiotemporal Composability*, arXiv:2608.25512 (authors listed: Shi Yifan, Zhang Wei, Cui Tianyi, and others) | https://arxiv.org/abs/2608.25512 |
| Packages | `core`, `create`, `group`, `hmr`, `include`, `loader`, `logger-console`, `timer`, `utils` | [packages/](https://github.com/cordiverse/cordis/tree/master/packages) |
| Config schema lib | Schemastery (also by Shigma). Cordis itself accepts any Standard Schema validator. | [tutorial ch.5](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/cordis-tutorial/05-config.md) |
| Official docs | Upstream points to the dsh-hosted primer ("official documentation is still under construction") | [primer](https://deepseek-harness.github.io/deepseek-harness/reference/cordis-primer) |

There is no more plausible browser-related "cordis". Other hits were `geohotstan/cordis-py` (a Python port) and the unrelated EU research database named CORDIS.

The best docs for Cordis are the dsh tutorial ([index](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/cordis-tutorial/index.md)) and the [primer](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/cordis-primer.md). The examples below come from those docs and use the `@deepseek-ai/cordis` fork. Upstream uses the import path `cordis`. How far the fork's API has drifted from upstream is **UNVERIFIED**.

### Core concepts

**1. Context (`ctx`) as a service repository.** A plugin receives a `ctx`. It registers everything it contributes through `ctx`, and it reaches other capabilities as `ctx.<name>` instead of importing them.

**2. Plugins come in three shapes** ([ch.1](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/cordis-tutorial/01-first-plugin.md)):
```ts
// 1. Function plugin
export function apply(ctx: Context) {}
// 2. Object plugin
export const objectPlugin = { name: 'object-plugin', apply(ctx: Context) {} }
// 3. Class plugin: a Service subclass
export class MyService extends Service {
  constructor(ctx: Context) { super(ctx, 'myTutorialService') }
}
```
The app is composed from YAML (`cordis.yml`, for example `- name: './hello.ts'`), not from bootstrap code. A plugin whose `apply` throws is a loud failure, not a skipped entry.

**3. Effects and disposal** ([ch.2](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/cordis-tutorial/02-lifecycle-and-effects.md)). Every registration is an *effect* with a disposer. If a resource is not managed by Cordis, you wrap it:
```ts
ctx.effect(() => {
  const timer = setInterval(() => console.log('tick'), 200)
  return () => clearInterval(timer)
})
```
- `ctx.on(...)`, `ctx.plugin(child)` and service registrations are already effects.
- `ctx.plugin()` returns a **fiber**. `fiber.dispose()` resolves only after all cleanup has finished, including async cleanup, and it disposes children recursively.
- Fiber states: `PENDING → LOADING → ACTIVE → UNLOADING → DISPOSED`, with a branch to `FAILED`.
- Caveat: disposers start in reverse order, but async disposers run concurrently.

**4. Services and `inject`** ([ch.3](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/cordis-tutorial/03-services.md)):
```ts
declare module '@deepseek-ai/cordis' {
  interface Context { greeter: GreeterService }
}
export class GreeterService extends Service {
  constructor(ctx: Context) { super(ctx, 'greeter') }
  greet(who: string) { return `Hello, ${who}!` }
}
// consumer
export const inject = ['greeter']
export function apply(ctx: Context) { console.log(ctx.greeter.greet('world')) }
```
- A plugin stays PENDING until every injected service exists, so load order comes from dependencies, not from file order.
- Dependencies are tracked live. If a provider unloads or is hot-replaced, every dependent unloads and later reloads.
- For optional dependencies, use `ctx.get('greeter')` instead.
- All service names share one flat namespace. Declaration merging on `Context` provides the typing.

**5. Typed events with five dispatch modes** ([ch.4](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/cordis-tutorial/04-events.md)). Events are declared by merging into `interface Events`.

| Mode | Semantics |
|---|---|
| `emit` | Synchronous broadcast; return values are ignored |
| `parallel` | Awaits all listeners concurrently |
| `serial` | Awaits listeners in order; the first non-null result wins |
| `bail` | Synchronous version of serial |
| `waterfall` | Around-middleware: listener gets `(...args, next)`. It can transform the result of `next()` or short-circuit ("veto") by not calling it |

The waterfall mode is the interception primitive. dsh uses it for `agent/request`, `tools/*` and `approval/request`. There is a standing rule for it: a listener that only observes must still call `next()`.

**6. Config schemas** ([ch.5](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/cordis-tutorial/05-config.md)):
```ts
export const Config: Schema<Config> = Schema.object({
  greeting: Schema.string().default('Hello'),
  targets: Schema.array(String).default(['world']),
})
export function apply(ctx: Context, config: Config) { ... }
```
- Invalid config sends the fiber to FAILED with a precise path error.
- `.volatile()` fields hot-update without a remount.
- dsh's loader adds `!!js` for computed values.
- Serialized schemas drive settings forms.

**7. Composition and HMR** ([ch.6](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/cordis-tutorial/06-composition-and-hmr.md)):
- Entries carry a stable `id`, and `disabled: true` turns one off.
- Groups load and unload as a unit.
- `isolate` gives a group its own instance of a service name.
- HMR unloads a plugin (which unwinds its effects) and reloads it. The loader diffs `cordis.yml` by `id`, so only changed entries remount.
- `ctx.registry` enumerates fibers, which is how you diagnose PENDING plugins.

Other upstream APIs mentioned by third-party summaries include `ctx.provide`, `ctx.set`, `ctx.isolate`, `ctx.intercept` and an `@Inject` decorator. These are **UNVERIFIED**; they come from a search-engine summary, not from reading the source.

## 2. DeepSeek Harness (dsh)

### Identity

| Fact | Value | Source |
|---|---|---|
| Repo | https://github.com/deepseek-ai/deepseek-harness | — |
| Stars / created / license | 237,266 stars; created 2026-08-13; MIT; last push 2026-09-24 | measured with `gh api` |
| Status | "developer preview … THERE WILL BE COMPATIBILITY-BREAKING CHANGES"; not security-audited ([SAFETY.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/SAFETY.md)) | [README](https://github.com/deepseek-ai/deepseek-harness/blob/master/README.md) |
| Run | `npx @deepseek-ai/dsh web` starts a Web UI at `127.0.0.1:3080`; there is also an Electron desktop app | README, [architecture.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/architecture.md) |
| Size | 312 `packages/*/*/package.json` workspaces | measured from the git tree via `gh api .../git/trees/master?recursive=1` |
| Docs | https://deepseek-harness.github.io/deepseek-harness/ | — |
| Press | [The New Stack](https://thenewstack.io/deepseek-harness-open-source-plugins/), [DataCamp tutorial](https://www.datacamp.com/tutorial/deepseek-harness), [MindStudio explainer](https://www.mindstudio.ai/blog/deepseek-harness-agentic-coding) | — |

### Architecture ([architecture.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/architecture.md))

**Everything is a plugin, with no privileged core.** The model adapter, the tool registry, the session log and the agent loop are each a plugin that can be swapped from config: "you extend dsh by mounting a plugin beside the others".

**Profiles and bundles.**
- A bundle is a set of Cordis config rows plus the code they mount.
- A profile stacks bundles in order: `dsh-base`, then the app bundle (`web-app`, `headless`, `sdk-app`, `acp-app`), then the profile `cordis.patch.yml`, then the home patch, then any `--patch` overlay.
- Patches target config rows by `id`.
- `dsh --profile web --dump-config` prints the effective tree.

**Capability seams (three roles).** Each capability has a Service Definition, a Provider and a Consumer. The Consumer is usually the model-facing tool. Example: `dsh-shell` (definition), `dsh-bash-local` (provider) and `dsh-tool-bash` (consumer). The provider and consumer never depend on each other ([practice guide](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/user/develop/practice/index.md), [capability-seams.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/capability-seams.md)).

**Agent loop and turn flow.** A *step* is one model request plus the tools it calls. A *turn* is zero or more steps.
```text
turn/start
  -> agent/pre-step   (waterfall: rewrite/reject claimed input)
     step/start -> agent/request (waterfall: route/model config)
     stream -> llm/stream -> agent/assistant-stream
     tool/call* -> tools/pre-execute -> tools/execute -> tools/post-execute -> tool/result*
     step/end ; loop while tools owe another request
  -> agent/turn-stopping
turn/end
```
- `agent/pre-step`, `agent/request`, `llm/stream` and the three `tools/*` events are waterfalls.
- One inbox feeds the driver.
- `agent.inject()` adds context that "lands in the next admitted request".

**The session log is ground truth.** In the doc's words: "Model-visible means logged." A runtime invariant checks that every model request can be reconstructed from the append-only JSONL log.
- Fork, resume, transcripts and telemetry are all derived from that log.
- The format is versioned, with migration chains (v0 to v4).
- Compaction is an optional seam. It appends `compaction/start|summary|end` events plus a `user/message` with `surfaceOp: replace`, so a crash leaves a detectable orphaned lock ([compaction.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/compaction.md)).

**Tools** ([tools.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/tools.md), [ch.7](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/cordis-tutorial/07-into-the-harness.md)):
```ts
export const inject = ['tools']
export function apply(ctx: Context) {
  ctx.tools.register(defineTool({
    name: 'greet',
    description: 'Greet the named person.',
    parameters: { name: { type: 'string', required: true, description: 'Who to greet' } },
    output: { schema: { type: 'string' }, render: (_args, value) => [{ type: 'text', text: value }] },
    async execute(args) { return `Hello, ${args.name}!` },
  }))
}
```
- Arguments are validated before `execute` runs.
- `schemas()` sends only an allowlist of fields to the model. `timeoutMs`, `isConcurrencySafe` and the presenters are never model-visible.
- Parallel execution is opt-in through `isConcurrencySafe`.
- The registration is disposed along with the plugin.

**Approval** ([approval.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/approval.md)):
- The outcome type is closed and fails closed: `'allowed-once' | 'rejected' | 'cancelled' | 'unavailable'`. A missing or throwing answerer yields `unavailable`, which means deny.
- Per-session policy is `ask | never`, and `never` is enforced before the waterfall, so a late-registered answerer cannot bypass it.
- Answerers are listeners on the `approval/request` waterfall. The UI is one answerer and the ACP bridge is another.
- Every ask and decision appends an audit pair (`approval/asked`, `approval/decided`) to the log.
- The request carries `callId`, not the arguments, so the prompt attaches to the tool call that was already streamed and cannot drift from it.

**Sandbox** ([sandbox.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/sandbox.md)):
- Modes: `read-only | workspace-write | danger-full-access`, covering file effects only. Network is outside this vocabulary.
- Backends: macOS Seatbelt, Linux bwrap/Landlock, Windows ACL restricted token, and SSH.
- Enforcement strength is reported as a fact (`full | partial`).
- Policy travels with each call, which allows one-shot escalated retries.
- Permission presets bundle a sandbox mode with an approval policy, for example `workspace-write` + `ask` ([permission-presets.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/permission-presets.md)).

**Browser use** ([browser-use.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/browser-use.md)):
- The service registers only a provider name and allows one provider: Playwright MCP, Chrome DevTools MCP or Stagehand, all experimental and Chromium-based.
- A launched browser belongs to exactly one live Session.
- An attached (external) browser is reserved for one Session, keeps its existing state, and is left running on teardown.
- Login state is not restored from the log.

**UI extension ("slots")** ([slots.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/slots.md)):
- Plugins contribute React components through `ctx.slots.register()` into declared slots.
- Each slot has a cardinality (`single | list | keyed | chain`) and a scope (`root | session-maybe | session`).
- Registering into an undeclared slot fails at activation.
- `ctx.slots.inject(key, cb)` re-contributes each time the owning slot remounts.
- The client includes sidebar packages such as `ui-sidebar-browser`, `ui-sidebar-files`, `ui-sidebar-terminal` and `ui-sidebar-right`. Package names were read from the git tree; their behavior is **UNVERIFIED**.

**Commands** ([commands.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/commands.md)): `ctx.commands` holds human slash commands that run against an agent without producing a model message.

**Interop:**
- MCP client: `packages/mcp/mcp-client`.
- ACP (Agent Client Protocol) server: `dsh --profile acp` ([acp README](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/acp/acp/README.md)).
- Subagent providers for in-process agents, ACP, Claude Code and Codex.
- Hooks compatible with Claude Code and Codex (`packages/hooks/*`).
- `agent-instructions` context.
- Reading AGENTS.md and CLAUDE.md is reported by the press; the exact file handling is **UNVERIFIED**.

**Self-extension** ([packages/extensions](https://github.com/deepseek-ai/deepseek-harness/blob/master/packages/extensions/README.md)):
- The agent can author versioned Cordis packages with a host half and a browser half.
- `tool-cordis` offers read-only runtime API discovery.
- The host runner runs the host half "sandboxed". The exact sandbox semantics live in an Agent Note that was not read, so they are **UNVERIFIED**.

**Defensive patterns worth copying** ([defensive-patterns.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/defensive-patterns.md)):
- Spawned commands get a scrubbed environment: drop `*KEY*`, `*SECRET*`, `*TOKEN*` and `*PASSWORD*`.
- Spill files go in a private `0700` directory with exclusive `0600` opens.
- Dispose must wait until the work actually stops, not just request it.
- A throwing listener is contained so it cannot break the dispatcher.

**Prompt injection:**
- No dedicated prompt-injection defense layer was found in the docs read. `gh search code "prompt injection"` in the repo returned only 2 Agent Notes.
- Defense relies on sandbox, approval, the scrubbed environment and SAFETY.md's "do not rely on DeepSeek Harness as the sole security control".
- The `session-reference` resolver projects conversation snapshots into "durable **untrusted** message context". That is the only explicit untrusted-content labeling seen.

## 3. Design lessons for den

### (a) Native plugin architecture next to WebExtensions

1. **Adopt the Cordis model (or Cordis itself) for native plugins.** Use context plus services plus `inject` plus effects. Every contribution (sidebar panel, command, connector, AI tool, settings page) is an effect that unwinds on unload. That gives hot reload, disable-without-uninstall and clean crash recovery for free. den's host side would be Swift; Cordis is TypeScript. One option is a JS plugin host (JSContext or a hidden WKWebView per plugin group) with a Swift bridge exposing services. The cost and feasibility of that are **UNVERIFIED**.
2. **Put the browser's own features behind seams**, like dsh's "no privileged core". Tabs, history, bookmarks, downloads, the sidebar and the omnibox should be Service Definitions with built-in providers. Then native plugins, WebExtension shims and the agent all consume the same interfaces.
3. **Use the three-role seam for connectors.** For example, `connector.slack` (definition), a provider that holds OAuth and the API client, and consumers (a sidebar panel, AI tools, commands). Swapping to a self-hosted or MCP-backed provider then changes no consumers.
4. **Build UI extension as declared, typed slots**, like dsh slots. The browser chrome declares slots such as `sidebar.panels` (list), `toolbar.actions` (list), `omnibox.providers` (chain) and `tab.contextMenu` (list), each with a scope. Registering into an undeclared slot fails at load. This is safer and more composable than free-form DOM injection.
5. **Validate config against a schema, and generate settings UI from the same schema.** Use per-field hot updates (`volatile`), and let bad config fail loudly at load.
6. **Make composition a patchable file** (profile, bundles, user patch, keyed by `id`). This enables per-profile plugin sets ("work", "research") and user overrides without forking. Build a dump-config equivalent and a "why is this PENDING" inspector.
7. **Keep WebExtensions separate.** Do not reimplement them as Cordis plugins. Instead, expose a narrow bridge service (`ctx.webext`) so native plugins can observe or message extensions. This keeps the WebExtensions security model intact.

### (b) AI agent harness inside the browser

1. **Treat an append-only session log as ground truth.** Enforce "model-visible means logged", so every model request can be reconstructed. That gives replay, fork, audit and debugging of injection incidents. Page content fed to the model should be logged with provenance: tab id, URL, timestamp and a content hash.
2. **Build the loop from waterfall seams.** Use pre-step, request, tool pre/execute/post and turn-stopping. Permission checks, redaction, rate limits and injection filters then become composable middleware, not edits to the loop.
3. **Model tools as registry entries with a strict model-visible allowlist.** Tab, DOM, form-fill and connector actions are all tools. Add concurrency opt-in, timeouts and cancellation that must reach quiescence.
4. **Make approval closed and fail-closed.** Use `allowed-once` as the only grant. Missing UI means deny. Attach the approval prompt to the exact streamed call, and log every ask and decision. Browser-specific policy should be keyed by origin and action class: read page, click, type, submit, navigate cross-origin, send via connector.
5. **Compose presets from independent knobs.** dsh bundles sandbox mode and approval policy. den could bundle: which origins are visible to the agent, whether actions can be taken, whether connectors may write, and whether approval is needed. Show one "Permissions" selector.
6. **Scope browser resources to a session.** Follow dsh's rule that one launched or attached browser belongs to one session. In den, an agent session should own an explicit set of tabs, or a dedicated tab group or profile. Do not let it default to the user's whole browser. Login state should not leak through the log.
7. **Prompt injection is den's gap to fill.** dsh offers little beyond sandbox and approval. For a browser, where every page is untrusted input, den should:
   - tag all page and connector content as untrusted in session events, with provenance, and render it in delimited blocks;
   - never let untrusted content widen permissions. Escalation should require user approval, as with dsh's approved retry being a new call;
   - gate cross-origin data movement, such as reading tab A and then writing to tab B or Slack, as a high-risk action class;
   - scrub credentials from anything tools return, like dsh's scrubbed environment.
8. **Keep context-building pluggable.** dsh uses `agent.inject()` together with optional compaction and image-offload seams. den can provide tab and page extractors, selection and history as context providers, all reconstructable from the log.
9. **Interop.** An MCP client for connectors and an ACP server for external agents to drive den are both proven patterns in dsh. dsh's Playwright and DevTools MCP browser providers are Chromium-only. den on WebKit needs its own native provider behind the same kind of registration-only service.

## Sources

- https://github.com/cordiverse/cordis and [core README](https://github.com/cordiverse/cordis/blob/master/packages/core/README.md)
- https://arxiv.org/abs/2608.25512
- https://github.com/koishijs/koishi/blob/master/packages/core/package.json
- https://github.com/deepseek-ai/deepseek-harness ([README](https://github.com/deepseek-ai/deepseek-harness/blob/master/README.md), [AGENTS.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/AGENTS.md), [SAFETY.md](https://github.com/deepseek-ai/deepseek-harness/blob/master/SAFETY.md))
- dsh docs: [architecture](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/architecture.md), [cordis-primer](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/cordis-primer.md), [cordis-tutorial](https://github.com/deepseek-ai/deepseek-harness/tree/master/docs/cordis-tutorial), [subsystems](https://github.com/deepseek-ai/deepseek-harness/tree/master/docs/subsystems)
- https://deepseek-harness.github.io/deepseek-harness/
- https://thenewstack.io/deepseek-harness-open-source-plugins/ (only the search snippet was readable; the page fetch returned boilerplate)
- https://www.datacamp.com/tutorial/deepseek-harness, https://www.mindstudio.ai/blog/deepseek-harness-agentic-coding (search snippets only)
