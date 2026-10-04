import AVFoundation
import CordisValue

/// A plugin's voices, added to `speech` beside macOS's (a local TTS model, say).
struct SpeechProvider {
  let id: String
  var name: String
  var voices: [Value]

  /// A provider voice as `speech.voices` lists it.
  func info(_ v: Value) -> Value {
    var pairs: [(String, Value)] = [("id", .string(v.str("id"))), ("name", .string(v.str("name"))), ("language", .string(v.str("language"))),
                                    ("quality", .string(v.str("quality", "default"))), ("provider", .string(id)), ("providerName", .string(name))]
    let g = v.str("gender")
    if g == "male" || g == "female" { pairs.append(("gender", .string(g))) }
    return .object(pairs)
  }
}

/// A provider queue's audio: sentence index -> audio, fetched one ahead of the one playing.
struct ProviderPlayback {
  var generation = 0
  var audio: [Int: Data] = [:]
  var asked: Set<Int> = []
  var player: AVAudioPlayer?
  var playing = -1
}

/// Voice providers: plugins that make speech audio themselves (docs/host-api.md#speech).
///
/// | Method | Args | Returns |
/// |---|---|---|
/// | `registerProvider` | `id`, `name` (the picker's section title), `voices: [{id, name, language, quality?, gender?}]` | ok. Again with the same `id` replaces its voices |
/// | `unregisterProvider` | `id` | ok. A queue in its voice stops |
/// | `provide` | `key`, and `path` (an audio file) or `url` (`file:` or http on localhost) or `error` | ok. The answer to one `speech.synthesize` |
///
/// Event to the provider: `speech.synthesize {provider, key, request, index, text, voice, lang}`,
/// one sentence at a time (the next one is asked for while the current one plays). The host plays
/// the audio (anything `AVAudioPlayer` reads: WAV, AIFF, MP3, AAC), so pause, speed (0.5–2×),
/// progress and `speech.state` work as for macOS voices. An `error` stops the queue with
/// `speech.state {state: "stopped", error}`.
extension SpeechService {
  func registerProvider(_ args: Value) -> Value {
    let id = args.str("id")
    guard !id.isEmpty, id != Self.system else { return .error("speech: a provider needs an id other than 'system'") }
    let voices = args.list("voices").filter { !$0.str("id").isEmpty && !$0.str("name").isEmpty }
    let p = SpeechProvider(id: id, name: args.str("name", id), voices: voices)
    if let i = providers.firstIndex(where: { $0.id == id }) { providers[i] = p } else { providers.append(p) }
    return .ok
  }

  func unregisterProvider(_ args: Value) -> Value {
    let id = args.str("id")
    providers.removeAll { $0.id == id }
    if provider == id {
      stop(emit: true)
      provider = Self.system
      voiceId = ""
    }
    return .ok
  }

  func startProvider(at first: Int) {
    let g = playback.generation + 1
    playback = ProviderPlayback()
    playback.generation = g
    index = first
    publish("playing")
    ask(first)
    if playback.generation == g { ask(first + 1) }  // unless the first answer stopped it
  }

  func stopProvider() {
    playback.player?.delegate = nil
    playback.player?.stop()
    let g = playback.generation + 1
    playback = ProviderPlayback()
    playback.generation = g
  }

  func resumeProvider() {
    if let p = playback.player { p.play() } else { tryPlay(index) }
  }

  private func ask(_ i: Int) {
    guard i >= 0, i < texts.count, !playback.asked.contains(i) else { return }
    playback.asked.insert(i)
    host.emit("speech.synthesize", ["provider": .string(provider), "key": .string("\(request)#\(playback.generation)#\(i)"), "request": .string(request),
                                    "index": .int(Int64(i)), "text": .string(texts[i]), "voice": .string(voiceId), "lang": .string(lang)])
  }

  func provide(_ args: Value) -> Value {
    let key = args.str("key")
    if !previewKey.isEmpty, key == previewKey {
      audio(args) { [weak self] data, _ in
        guard let self, self.previewKey == key else { return }
        self.previewKey = ""
        guard let data, !self.silent, let player = try? AVAudioPlayer(data: data) else { return }
        player.volume = self.volumeOverride ?? 1
        player.delegate = self
        self.previewPlayer = player
        player.play()
      }
      return .ok
    }
    let parts = key.split(separator: "#", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 3, let g = Int(parts[parts.count - 2]), let i = Int(parts[parts.count - 1]) else { return .error("speech: unknown key '\(key)'") }
    guard g == playback.generation, provider != Self.system else { return .ok }  // an answer for a queue that's gone
    audio(args) { [weak self] data, error in
      guard let self, g == self.playback.generation else { return }
      guard let data else {
        self.stopProvider()
        self.publish("stopped", error: error)
        return
      }
      self.playback.audio[i] = data
      if self.playback.playing < 0, self.playback.player == nil, i == self.index, self.state == "playing" { self.play(i) }
    }
    return .ok
  }

  /// The audio of a `provide` answer: a file, or a `file:` / localhost http URL.
  private func audio(_ args: Value, _ done: @escaping @MainActor @Sendable (Data?, String) -> Void) {
    if !args.str("error").isEmpty { return done(nil, args.str("error")) }
    var url: URL?
    if !args.str("path").isEmpty { url = URL(fileURLWithPath: args.str("path")) } else { url = URL(string: args.str("url")) }
    guard let url else { return done(nil, "speech: no audio") }
    if url.isFileURL {
      guard let d = try? Data(contentsOf: url), !d.isEmpty else { return done(nil, "speech: can't read \(url.path)") }
      return done(d, "")
    }
    let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host() ?? "")
    guard local, url.scheme == "http" || url.scheme == "https" else { return done(nil, "speech: audio must be a file or a localhost URL") }
    Task { @MainActor in
      do {
        let (d, r) = try await URLSession.shared.data(from: url)
        if let h = r as? HTTPURLResponse, h.statusCode != 200 { return done(nil, "speech: HTTP \(h.statusCode) from \(url.absoluteString)") }
        done(d, "")
      } catch {
        done(nil, "speech: \(error.localizedDescription)")
      }
    }
  }

  private func tryPlay(_ i: Int) {
    if playback.audio[i] != nil { play(i) } else { ask(i) }
  }

  private func play(_ i: Int) {
    guard let data = playback.audio.removeValue(forKey: i) else { return }
    guard let player = try? AVAudioPlayer(data: data) else {
      stopProvider()
      return publish("stopped", error: "speech: the provider's audio can't be played")
    }
    playback.playing = i
    progress(i)
    ask(i + 1)
    if silent {
      // No audio device under tests: the sentence ends at once, with the same events.
      let g = playback.generation
      Task { @MainActor in if g == self.playback.generation, self.playback.playing == i { self.advance() } }
      return
    }
    player.enableRate = true
    player.rate = Float(min(2, rate))
    player.volume = volumeOverride ?? volume
    player.delegate = self
    playback.player = player
    player.play()
  }

  /// A player ended: the preview's, or the queue's current sentence.
  func playerFinished(_ p: ObjectIdentifier) {
    if let pp = previewPlayer, ObjectIdentifier(pp) == p {
      previewPlayer = nil
      return
    }
    guard let cur = playback.player, ObjectIdentifier(cur) == p else { return }
    advance()
  }

  private func advance() {
    let i = playback.playing
    playback.player = nil
    playback.playing = -1
    guard i >= 0 else { return }
    if i >= texts.count - 1 {
      publish("done")
      return
    }
    index = i + 1
    if state == "playing" { tryPlay(i + 1) }
  }
}
