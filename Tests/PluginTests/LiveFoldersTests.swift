import CordisValue
import DenTestSupport
import Foundation
import Testing

@testable import DenHost
@testable import PluginCores

/// Live folders in the `tabs` plugin: rows from a connection's feed items, unread dots, done
/// items in the "N ✓" chip and its Recently Closed popover, PR stacks, the reauth row, and the
/// favorite countdown chip (`tabs.badge`).
@MainActor
@Suite(.serialized, .watchdog)
struct LiveFoldersTests {
  func item(_ repo: String, _ n: Int, _ kind: String, head: String = "", base: String = "") -> Value {
    var v: Value = ["id": .string("github:" + repo + "#" + String(n)), "key": .string(repo + "#" + String(n)), "source": "github", "kind": .string(kind),
                    "title": .string("PR " + String(n)), "url": .string("https://gh.example/" + repo + "/pull/" + String(n)), "where": .string(repo)]
    if !head.isEmpty { v.put("head", .string(head)); v.put("base", .string(base)) }
    return v
  }

  var stack: [Value] {
    [item("denhq/den", 219, "authored", head: "stacks", base: "rows"), item("denhq/den", 218, "authored", head: "rows", base: "rank"),
     item("denhq/den", 209, "ci", head: "rank", base: "main")]
  }

  func feed(_ h: Harness, _ items: [Value], error: String? = nil) {
    var v: Value = ["source": "github", "items": .array(items)]
    if let error { v.put("error", .string(error)) }
    h.rt.plugins.emit("feed.items", v)
  }

  /// The live folder node in the current space's pinned slot.
  func folder(_ h: Harness, _ fid: String) -> Value {
    h.tree("sidebar.pinned", 0).list("children").first { $0.s("id") == fid } ?? .null
  }

  /// Whether any node in the tree carries `unread: true`.
  func anyUnread(_ node: Value) -> Bool {
    node["unread"] == true || node.list("children").contains { anyUnread($0) }
  }

  func rowIds(_ node: Value) -> [String] {
    node.list("children").flatMap { c -> [String] in c.s("type") == "folder" ? c.list("children").map { $0.s("id") } : [c.s("id")] }
  }

  @Test func stacksChainPRsByBranch() {
    let list = stack + [item("denhq/den", 300, "authored", head: "other", base: "main"), item("acme/web", 1, "review")]
    let s = LiveFoldersUI.stacks(list)
    #expect(s.count == 1)
    #expect(s[0].title == "den")
    #expect(s[0].members == ["github:denhq/den#209", "github:denhq/den#218", "github:denhq/den#219"])  // bottom first
    #expect(LiveFoldersUI.stacks([item("a/b", 1, "authored", head: "x", base: "y"), item("c/d", 2, "authored", head: "y", base: "main")]).isEmpty)
  }

  @Test func liveFolderRowsUnreadDoneAndReauth() {
    let h = Harness()
    var connected = true
    var opened: [String] = []
    h.rt.plugins.provide("connections") { m, a in
      m == "get" ? ["id": a["id"], "connected": .bool(connected)] : .null
    }
    let tabs = h.startTabs()
    let base = tabs.tabs.count
    h.record(["feed.refresh"])
    let fid = h.tabs("newLiveFolder", ["source": "github"]).s("id")
    #expect(!fid.isEmpty)
    #expect(h.ids("pinned").first == fid)
    #expect(h.events.contains { $0.0 == "feed.refresh" && $0.1.a("sources") == ["github"] })  // asks once, nothing polls
    #expect(folder(h, fid).list("children").first?.s("title") == "Loading…")

    // The first items prime the folder: nothing is unread yet.
    let review = item("acme/web", 1, "review"), mention = item("acme/api", 7, "mention")
    feed(h, [review, mention] + stack)
    var node = folder(h, fid)
    #expect(node.s("icon") == "https://github.com/favicon.ico")
    #expect(node.list("children").map { $0.s("type") } == ["tabRow", "tabRow", "folder"])
    let stackNode = node.list("children")[2]
    #expect(stackNode.s("title") == "den · 3 PRs")
    #expect(stackNode.list("children").map { $0.s("id") } == ["live:" + fid + ":github:denhq/den#209", "live:" + fid + ":github:denhq/den#218",
                                                                "live:" + fid + ":github:denhq/den#219"])
    #expect(!anyUnread(node))
    #expect(node["badge"].isNull)

    // Next refresh: the review was given (gone: done), something new arrived (unread).
    let fresh = item("acme/web", 2, "review")
    feed(h, [fresh, mention] + stack)
    node = folder(h, fid)
    #expect(node.s("badge") == "1 ✓")
    let freshRow = node.list("children").first { $0.s("id") == "live:" + fid + ":github:acme/web#2" }!
    #expect(freshRow["unread"] == true)
    #expect(freshRow["closeTitle"] == "Mark as Done")
    // Collapsed, the folder carries the dot.
    h.action(fid, "toggle")
    #expect(folder(h, fid)["unread"] == true)
    #expect(folder(h, fid).list("children").isEmpty)
    h.action(fid, "toggle")

    // A failed refresh marks nothing done.
    feed(h, [], error: "network error")
    #expect(folder(h, fid).s("badge") == "1 ✓")
    #expect(rowIds(folder(h, fid)).count == 5)

    // Opening a row opens its PR as a tab and clears its dot.
    h.action("live:" + fid + ":github:acme/web#2", "click")
    #expect(tabs.tabs.count == base + 1)
    opened = tabs.tabs.values.map(\.url)
    #expect(opened.contains("https://gh.example/acme/web/pull/2"))
    #expect(!anyUnread(folder(h, fid)))
    // A second click goes to that tab instead of opening another.
    h.action("live:" + fid + ":github:acme/web#2", "click")
    #expect(tabs.tabs.count == base + 1)

    // The row's × marks it done.
    h.action("live:" + fid + ":github:acme/api#7", "close")
    #expect(folder(h, fid).s("badge") == "2 ✓")
    #expect(!rowIds(folder(h, fid)).contains("live:" + fid + ":github:acme/api#7"))

    // The chip opens Recently Closed; reopening one brings its row back.
    h.action(fid, "badge")
    #expect(tabs.liveFolders.popoverFor == fid)
    #expect(h.rt.call("ui", "get")["overlays"].array?.contains("popover") == true)
    #expect(tabs.liveFolders.state[fid]?.a("done").map { $0.s("key") } == ["github:acme/api#7", "github:acme/web#1"])
    h.action("live.done:" + fid + ":github:acme/api#7", "click", ["button": "restore"])
    #expect(folder(h, fid).s("badge") == "1 ✓")
    #expect(rowIds(folder(h, fid)).contains("live:" + fid + ":github:acme/api#7"))
    #expect(tabs.tabs.values.contains { $0.url == "https://gh.example/acme/api/pull/7" })

    // Stacks collapse and stay collapsed.
    h.action("livestack:" + fid + ":github:denhq/den#209", "toggle")
    #expect(folder(h, fid).list("children").last?["open"] == false)
    #expect(h.storage("tabs", "live")[fid].a("closed") == ["github:denhq/den#209"])

    // Signed out: one row to sign in again.
    connected = false
    h.rt.plugins.emit("connections.changed", ["connections": []])
    #expect(folder(h, fid).list("children").map { $0.s("title") } == ["Sign in to GitHub to fill this folder"])

    // The folder and its state persist.
    let saved = h.storage("tabs", "live")[fid]
    #expect(saved.b("primed") && saved.a("done").count == 1)
    tabs.save()
    #expect(h.storage("tabs", "state").a("folders").first { $0.s("id") == fid }?.s("live") == "github")
    // Deleting the folder forgets its state.
    tabs.deleteFolder(fid)
    #expect(h.storage("tabs", "live")[fid].isNull)
  }

  @Test func favoriteCountdownChip() {
    let h = Harness()
    let tabs = h.startTabs()
    let id = h.tabs("open", ["url": "https://calendar.google.com/calendar/u/0/r", "kind": "favorite", "background": true]).s("id")
    func tile() -> Value { h.rt.ui.sidebarView.slot("sidebar.favorites", page: 0)?.root?.node.list("children").first { $0.s("id") == id } ?? .null }
    #expect(tile()["badge"].isNull)
    #expect(h.tabs("badge", ["owner": "calendar", "host": "calendar.google.com", "text": "in 8m"]) == ["ok": true])
    #expect(tile().s("badge") == "in 8m")
    h.tabs("badge", ["owner": "calendar", "host": "calendar.google.com", "text": ""])
    #expect(tile()["badge"].isNull)
    #expect(h.tabs("badge", ["text": "x"]).isErr)
    _ = tabs
  }
}
