# Filter lists shipped with den's Shields

These files are data, not den's code, and keep their own licences. den's code is MIT.

| File | Made from | Licence |
|---|---|---|
| `ads.json.lzfse` | EasyList (network rules and site-specific element hiding), https://easylist.to | CC BY-SA 3.0 Unported. EasyList is dual licensed GPL-3.0-or-later / CC BY-SA 3.0-or-later; den uses the CC BY-SA option |
| `trackers.json.lzfse` | EasyPrivacy (network rules), https://easylist.to | CC BY-SA 3.0 Unported (same dual licence) |
| `cookies.json.lzfse` | EasyList Cookie List, https://easylist.to | CC BY 3.0 Unported (the list's own header) |

Attribution: "The EasyList authors (https://easylist.to/)". Licence texts: https://creativecommons.org/licenses/by-sa/3.0/ and https://creativecommons.org/licenses/by/3.0/, and https://easylist.to/pages/licence.html.

Each file is an adaptation: the lists' rules converted to WebKit content-blocker JSON with adblock-rust (https://github.com/brave/adblock-rust, MPL-2.0, used as a build tool only), with rules WebKit can't compile removed, then LZFSE-compressed. The adaptation is shared under the same licence as its source. How to rebuild them: `scripts/shields/build-lists.sh`.
