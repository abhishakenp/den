import AppKit
import CordisValue
import MediaPlayer

/// `nowplaying` service: den's entry in Control Center's Now Playing and the media keys
/// (`MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`). A generic bridge: which tab is "now
/// playing", and what a command does, is the `media` plugin's business.
///
/// Methods:
///   set {title, artist?, album?, artwork? (http(s)/data: URL), duration?, elapsed?, playing,
///        commands?: [play, pause, toggle, next, previous, stop]}   -> ok. Shows (or updates) the
///        Now Playing entry; only the listed commands are enabled (all but next/previous by default)
///   clear                                                          -> ok. Removes the entry and every
///        command handler
///   get                                                            -> {active, title, playing, commands}
/// Events: nowplaying.command {command: play|pause|toggle|next|previous|stop}
///
/// Cost: nothing is registered until the first `set`, and `clear` removes it all again.
@MainActor
public final class NowPlayingService: HostService {
  public let name = "nowplaying"
  let host: ServiceHost
  public private(set) var active = false
  public private(set) var info: Value = .null
  public private(set) var commands: Set<String> = []
  private var targets: [(MPRemoteCommand, Any)] = []
  private var artworkURL = ""
  private var artwork: MPMediaItemArtwork?

  public init(host: ServiceHost) { self.host = host }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "set": set(args)
    case "clear": clear()
    case "get":
      return ["active": .bool(active), "title": info["title"], "playing": .bool(info.flag("playing")),
              "commands": .array(commands.sorted().map { .string($0) })]
    default: return .error("nowplaying: unknown method '\(method)'")
    }
    return .ok
  }

  static let allCommands = ["play", "pause", "toggle", "next", "previous", "stop"]

  func set(_ args: Value) {
    info = args
    let wanted = args["commands"].array.map { Set($0.compactMap(\.string)) } ?? ["play", "pause", "toggle", "stop"]
    if !active { register() }
    active = true
    commands = wanted
    let c = MPRemoteCommandCenter.shared()
    c.playCommand.isEnabled = wanted.contains("play")
    c.pauseCommand.isEnabled = wanted.contains("pause")
    c.togglePlayPauseCommand.isEnabled = wanted.contains("toggle")
    c.nextTrackCommand.isEnabled = wanted.contains("next")
    c.previousTrackCommand.isEnabled = wanted.contains("previous")
    c.stopCommand.isEnabled = wanted.contains("stop")
    var d: [String: Any] = [MPMediaItemPropertyTitle: args.str("title")]
    if !args.str("artist").isEmpty { d[MPMediaItemPropertyArtist] = args.str("artist") }
    if !args.str("album").isEmpty { d[MPMediaItemPropertyAlbumTitle] = args.str("album") }
    let dur = args.num("duration", 0)
    if dur > 0 { d[MPMediaItemPropertyPlaybackDuration] = dur }
    if let t = args["elapsed"].double { d[MPNowPlayingInfoPropertyElapsedPlaybackTime] = t }
    d[MPNowPlayingInfoPropertyPlaybackRate] = args.flag("playing") ? 1.0 : 0.0
    let url = args.str("artwork")
    if url != artworkURL {
      artworkURL = url
      artwork = nil
      if !url.isEmpty { loadArtwork(url) }
    }
    if let a = artwork { d[MPMediaItemPropertyArtwork] = a }
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = d
    center.playbackState = args.flag("playing") ? .playing : .paused
  }

  func loadArtwork(_ url: String) {
    ImageCache.shared.load(url) { [weak self] img in
      guard let self, self.active, self.artworkURL == url, let img else { return }
      let box = ArtworkImage(img)
      // @Sendable: MediaPlayer calls it on any thread (a closure isolated to the main actor
      // would trap there).
      self.artwork = MPMediaItemArtwork(boundsSize: img.size) { @Sendable _ in box.image }
      var d = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
      d[MPMediaItemPropertyArtwork] = self.artwork
      MPNowPlayingInfoCenter.default().nowPlayingInfo = d
    }
  }

  func register() {
    let c = MPRemoteCommandCenter.shared()
    let pairs: [(MPRemoteCommand, String)] = [
      (c.playCommand, "play"), (c.pauseCommand, "pause"), (c.togglePlayPauseCommand, "toggle"),
      (c.nextTrackCommand, "next"), (c.previousTrackCommand, "previous"), (c.stopCommand, "stop"),
    ]
    for (cmd, name) in pairs {
      let token = cmd.addTarget { @Sendable [weak self] _ in
        let s = self
        Task { @MainActor in s?.fire(name) }
        return .success
      }
      targets.append((cmd, token))
    }
  }

  /// What a Control Center button or media key does: `nowplaying.command {command}`.
  func fire(_ command: String) {
    guard active, commands.contains(command) else { return }
    host.emit("nowplaying.command", ["command": .string(command)])
  }

  func clear() {
    guard active else { return }
    active = false
    info = .null
    commands = []
    artworkURL = ""
    artwork = nil
    for (cmd, token) in targets { cmd.removeTarget(token) }
    targets = []
    let center = MPNowPlayingInfoCenter.default()
    center.nowPlayingInfo = nil
    center.playbackState = .stopped
  }
}

/// The artwork image, handed to MediaPlayer's (any-thread) request handler. Never mutated.
final class ArtworkImage: @unchecked Sendable {
  let image: NSImage
  init(_ image: NSImage) { self.image = image }
}
