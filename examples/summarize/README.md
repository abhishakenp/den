# Summarize: an example third-party plugin

"Summarize This Page" (command bar, or ⌃⇧S) reads the page in front and asks Apple's on-device model for a few bullet points, shown in a dialog. den itself ships no AI chat; this is how someone else would build an AI feature on den's plugin API.

## Install

```sh
mkdir -p ~/.den/plugins && cp -R examples/summarize ~/.den/plugins/summarize
```

den compiles the folder (it needs a swift.org toolchain with Embedded Swift, see [den-home.md](../../docs/den-home.md#source-plugins)), then asks:

> **Allow the “summarize” plugin?**
> See and manage your tabs · Read and change every page you visit · Use Apple's on-device model

After **Allow** it runs in its own sandboxed process. Change your mind in Settings ▸ Plugins.

## What it uses

| Step | Call | Permission |
|---|---|---|
| A command and a shortcut | `commands.register`, `keys.bind` (ids start with `summarize.`) | none |
| The page in front | `tabs.selected` | `tabs` |
| Its text | `webviews.inject` → `webviews.injectResult` | `pages:*` |
| The summary | `ai.availability`, `ai.respond` → `ai.result` | `ai` |
| Progress and result | `ui.set {slot: toast \| dialog}` | none |

`plugin.json` declares the three permissions. Everything else a sandboxed plugin can do is in [den-home.md](../../docs/den-home.md#third-party-plugins-sandbox-and-permissions); the services are in [host-api.md](../../docs/host-api.md).

## Going further

A chat or agent panel builds on the same pieces: a web view of its own (`webviews.create {id: "<plugin>.panel"}`, no permission needed) shown beside the page with `content.side` (with `tabs`), or native `ui` sheets and dialogs; `webviews.inject` to read pages; `tabs.*` to open and switch tabs; `ai.respond` for the on-device model; `net.fetch` to the hosts it declares with `net:<domain>`.

`PluginPlatformTests.theSummarizeExampleSummarizesThePageInFront` builds this folder with cordis-build, allows it, runs the command with a fake page and model, and checks the dialog.
