import CordisValue
import DenTestSupport
import Testing

@testable import PluginCores

/// `OpenGraph.parse`: link-preview metadata from real-world `<head>` markup.
@Suite(.watchdog)
struct OpenGraphTests {
  @Test func githubRepoHead() {
    let html = """
      <!DOCTYPE html><html lang="en" data-color-mode="auto"><head><meta charset="utf-8">
        <link rel="dns-prefetch" href="https://github.githubassets.com">
        <script>var x = '<meta property="og:title" content="WRONG">';</script>
        <title>GitHub - apple/swift: The Swift Programming Language</title>
        <meta name="description" content="The Swift Programming Language. Contribute to apple/swift development by creating an account on GitHub.">
        <link rel="icon" class="js-site-favicon" type="image/svg+xml" href="https://github.githubassets.com/favicons/favicon.svg">
        <meta property="og:image" content="https://opengraph.githubassets.com/1a2b/apple/swift" /><meta property="og:image:alt" content="The Swift Programming Language" />
        <meta property="og:site_name" content="GitHub" /><meta property="og:type" content="object" />
        <meta property="og:title" content="GitHub - apple/swift: The Swift Programming Language" />
        <meta property="og:url" content="https://github.com/apple/swift" />
        <meta property="og:description" content="The Swift Programming Language. Contribute to apple/swift development by creating an account on GitHub." />
      </head><body><meta property="og:title" content="BODY"></body></html>
      """
    let v = OpenGraph.parse(html, url: "https://github.com/apple/swift")
    #expect(v.s("title") == "GitHub - apple/swift: The Swift Programming Language")
    #expect(v.s("description") == "The Swift Programming Language. Contribute to apple/swift development by creating an account on GitHub.")
    #expect(v.s("image") == "https://opengraph.githubassets.com/1a2b/apple/swift")
    #expect(v.s("site") == "GitHub")
    #expect(v.s("icon") == "https://github.githubassets.com/favicons/favicon.svg")
    #expect(v.s("url") == "https://github.com/apple/swift")
  }

  @Test func newsArticleWithTwitterTagsOnly() {
    let html = """
      <HEAD>
      <META NAME="twitter:card" CONTENT="summary_large_image">
      <META NAME='twitter:title' CONTENT='Rover finds  water\n  ice at the pole'>
      <meta name=twitter:description content="Scientists say the find changes plans.">
      <meta name="twitter:image:src" content="//cdn.example-news.com/img/rover.jpg">
      <link rel="apple-touch-icon" href="/touch.png">
      </HEAD><body></body>
      """
    let v = OpenGraph.parse(html, url: "https://www.example-news.com/science/2026/rover?ref=home#top")
    #expect(v.s("title") == "Rover finds water ice at the pole")
    #expect(v.s("description") == "Scientists say the find changes plans.")
    #expect(v.s("image") == "https://cdn.example-news.com/img/rover.jpg")
    #expect(v.s("site") == "example-news.com")
    #expect(v.s("icon") == "https://www.example-news.com/touch.png")
  }

  @Test func titleOnlyAndRelativeIcon() {
    let html = "<html><head><title>\n  Plain page  </title><link href=\"../img/fav.png\" rel=\"shortcut icon\"></head><body>hi</body></html>"
    let v = OpenGraph.parse(html, url: "https://example.org/docs/guide/intro.html")
    #expect(v.s("title") == "Plain page")
    #expect(v["description"].isNull)
    #expect(v["image"].isNull)
    #expect(v.s("icon") == "https://example.org/docs/img/fav.png")
    #expect(v.s("site") == "example.org")
    // No icon link at all: the origin's /favicon.ico.
    let bare = OpenGraph.parse("<title>x</title>", url: "http://example.org:8080/a/b")
    #expect(bare.s("icon") == "http://example.org:8080/favicon.ico")
  }

  @Test func entitiesAndReversedAttributes() {
    let html = """
      <head><meta content="Tom &amp; Jerry&#39;s &quot;Big&quot; Day &#x2014; Part&nbsp;2 &hellip;" property="og:title">
      <meta content='A &lt;b&gt;bold&lt;/b&gt; caf&#233;' name="description">
      <meta content="img/cover.png" property="og:image"></head>
      """
    let v = OpenGraph.parse(html, url: "https://site.test/posts/42")
    #expect(v.s("title") == "Tom & Jerry's \"Big\" Day — Part 2 …")
    #expect(v.s("description") == "A <b>bold</b> café")
    #expect(v.s("image") == "https://site.test/posts/img/cover.png")
  }

  @Test func descriptionIsCapped() {
    let long = String(repeating: "word ", count: 120)
    let v = OpenGraph.parse("<meta property=\"og:description\" content=\"" + long + "\">", url: "https://a.test/")
    let d = v.s("description")
    #expect(d.utf8.count <= OpenGraph.maxDescription + 3)
    #expect(d.hasSuffix("…"))
  }

  @Test func headOnlyCutsAtTheHeadClose() {
    #expect(OpenGraph.headOnly("<head><title>a</title></HEAD><body>big</body>") == "<head><title>a</title></HEAD>")
    #expect(OpenGraph.headOnly("<title>a</title>") == "<title>a</title>")
  }
}
