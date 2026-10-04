import AVFoundation
import CordisValue

/// `speech` service: text to speech, on device. One queue at a time.
///
/// Voices come from providers. `system` is macOS (`AVSpeechSynthesizer`, every installed voice);
/// a plugin can add its own with `registerProvider` (a local TTS model, say). A queue spoken in a
/// provider's voice asks that plugin for each sentence's audio (`speech.synthesize`) and the host
/// plays it, so progress, pause, speed and the events are the same whoever made the voice
/// (SpeechProviders.swift). Listing voices (SpeechVoices.swift) happens only when asked.
///
/// | Method | Args | Returns |
/// |---|---|---|
/// | `speak` | `utterances: [string]`, `voice?`, `provider?` (default `system`), `lang?` (BCP 47, picks the system voice when there's no `voice`), `rate?` (1 = normal), `volume?` (0–1), `from?` (index), `request?` | `{request}`. Replaces the current queue |
/// | `pause`, `resume`, `stop` | – | ok |
/// | `setRate` | `rate` | ok. Restarts at the current utterance |
/// | `setVoice` | `voice?`, `provider?`, `lang?` | ok. Restarts at the current utterance in that voice |
/// | `state` | – | `{request, state, index, count, rate, voice, provider}` |
/// | `voices`, `voice`, `preview`, `personalVoice`, `openSettings` | | see SpeechVoices.swift |
/// | `registerProvider`, `unregisterProvider`, `provide` | | see SpeechProviders.swift |
///
/// Events: `speech.progress {request, index, count}` as each utterance starts, and
/// `speech.state {request, state: playing|paused|stopped|done, index, count, rate}`.
@MainActor
public final class SpeechService: NSObject, HostService, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
  public let name = "speech"
  let host: ServiceHost
  var synth: AVSpeechSynthesizer?
  var texts: [String] = []
  var keys: [ObjectIdentifier: Int] = [:]
  var request = ""
  var lang = ""
  /// The voice of the queue: an `AVSpeechSynthesisVoice` identifier for `system`, else the
  /// provider's own id. Empty: the system voice for `lang`.
  var voiceId = ""
  var provider = SpeechService.system
  var volume: Float = 1
  var nextRequest = 1
  var index = 0
  var rate: Double = 1
  var state = "stopped"
  /// Scenarios mute speech (read-aloud snapshots shouldn't talk).
  public var volumeOverride: Float?
  /// No audio device at all: utterances are synthesized to buffers (`write`) and dropped, with
  /// the same progress and state events. On under tests, so a test run never plays sound or
  /// holds an audio session open in coreaudiod.
  public var silent = TestMode.active
  var silentQueue: [AVSpeechUtterance] = []

  // Providers (SpeechProviders.swift)
  var providers: [SpeechProvider] = []
  var playback = ProviderPlayback()
  // Preview (SpeechVoices.swift)
  var previewSynth: AVSpeechSynthesizer?
  var previewPlayer: AVAudioPlayer?
  var previewKey = ""
  /// Times `openSettings` ran (tests don't open System Settings).
  public internal(set) var settingsOpened = 0

  public init(host: ServiceHost) { self.host = host }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "speak":
      let list = args.list("utterances").compactMap { $0.string }.filter { !$0.isEmpty }
      guard !list.isEmpty else { return .error("speech: nothing to speak") }
      let p = args.str("provider", Self.system)
      guard p == Self.system || providers.contains(where: { $0.id == p }) else { return .error("speech: no voice provider '\(p)'") }
      stop(emit: false)
      texts = list
      request = args.str("request")
      if request.isEmpty { request = "speech-\(nextRequest)"; nextRequest += 1 }
      lang = args.str("lang")
      voiceId = args.str("voice")
      provider = p
      if let r = args["rate"].double { rate = min(2.5, max(0.5, r)) }
      volume = Float(min(1, max(0, args.num("volume", 1))))
      begin(at: min(max(0, Int(args.num("from", 0))), texts.count - 1))
      return ["request": .string(request)]
    case "pause":
      guard state == "playing" else { return .ok }
      if provider == Self.system {
        guard let synth else { return .ok }
        synth.pauseSpeaking(at: .word)
      } else {
        playback.player?.pause()
      }
      publish("paused")
    case "resume":
      guard state == "paused" else { return .ok }
      if provider == Self.system {
        guard let synth else { return .ok }
        synth.continueSpeaking()
        publish("playing")
      } else {
        publish("playing")
        resumeProvider()
      }
      return .ok
    case "stop": stop(emit: true)
    case "setRate":
      rate = min(2.5, max(0.5, args.num("rate", 1)))
      if provider != Self.system {
        // The host plays a provider's audio: the player changes speed in place.
        playback.player?.rate = Float(min(2, rate))
        return .ok
      }
      restart()
    case "setVoice":
      let p = args.str("provider", Self.system)
      guard p == Self.system || providers.contains(where: { $0.id == p }) else { return .error("speech: no voice provider '\(p)'") }
      if !args["lang"].isNull { lang = args.str("lang") }
      let changed = voiceId != args.str("voice") || provider != p
      guard changed else { return .ok }
      let running = (state == "playing" || state == "paused") && !texts.isEmpty
      let paused = state == "paused"
      let at = index
      if running { stop(emit: false) }
      voiceId = args.str("voice")
      provider = p
      if running {
        begin(at: at)
        if paused { _ = handle(method: "pause", args: .null) }
      }
    case "state":
      return ["request": .string(request), "state": .string(state), "index": .int(Int64(index)), "count": .int(Int64(texts.count)), "rate": .double(rate),
              "voice": .string(voiceId), "provider": .string(provider)]
    case "voices": return voices()
    case "voice": return voice(args)
    case "preview": return preview(args)
    case "personalVoice": return personalVoice(args)
    case "openSettings": return openSettings()
    case "registerProvider": return registerProvider(args)
    case "unregisterProvider": return unregisterProvider(args)
    case "provide": return provide(args)
    default: return .error("speech: unknown method '\(method)'")
    }
    return .ok
  }

  /// Starts the queue at `first` in its voice: the system synthesizer or a provider's audio.
  func begin(at first: Int) {
    if provider == Self.system { start(at: first) } else { startProvider(at: first) }
  }

  /// Stops and starts again at the current utterance (a new rate or voice for the system synthesizer).
  private func restart() {
    guard synth != nil, !texts.isEmpty else { return }
    let paused = state == "paused"
    synth?.delegate = nil
    synth?.stopSpeaking(at: .immediate)
    synth = nil
    silentQueue = []
    start(at: index)
    if paused { _ = handle(method: "pause", args: .null) }
  }

  private func start(at first: Int) {
    let s = AVSpeechSynthesizer()
    // Silent mode reports progress itself (the delegate would report `write` utterances twice).
    s.delegate = silent ? nil : self
    synth = s
    keys = [:]
    let voice = Self.systemVoice(id: voiceId, lang: lang)
    let r = Float(Double(AVSpeechUtteranceDefaultSpeechRate) * rate)
    for i in first..<texts.count {
      let u = AVSpeechUtterance(string: texts[i])
      u.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, r))
      u.volume = volumeOverride ?? volume
      if let voice { u.voice = voice }
      keys[ObjectIdentifier(u)] = i
      if silent { silentQueue.append(u) } else { s.speak(u) }
    }
    index = first
    publish("playing")
    if silent { writeNext(s) }
  }

  /// Silent mode: synthesizes the next queued utterance to buffers; a zero-length buffer ends it.
  private func writeNext(_ s: AVSpeechSynthesizer) {
    guard synth === s, !silentQueue.isEmpty else { return }
    let u = silentQueue.removeFirst()
    let key = ObjectIdentifier(u)
    started(key)
    nonisolated(unsafe) let synthRef = s
    nonisolated(unsafe) var ended = false
    s.write(u) { [weak self] buffer in
      guard !ended, (buffer as? AVAudioPCMBuffer)?.frameLength ?? 0 == 0 else { return }
      ended = true
      Task { @MainActor in
        guard let self, self.synth === synthRef, self.state == "playing" || self.state == "paused" else { return }
        self.finished(key)
        self.writeNext(synthRef)
      }
    }
  }

  func stop(emit: Bool) {
    silentQueue = []
    stopProvider()
    stopPreview()
    guard let synth else {
      // A provider's queue (no synthesizer) stops the same way.
      if state == "playing" || state == "paused" {
        if emit { publish("stopped") } else { state = "stopped" }
      }
      return
    }
    synth.delegate = nil
    synth.stopSpeaking(at: .immediate)
    self.synth = nil
    keys = [:]
    if emit { publish("stopped") } else { state = "stopped" }
  }

  func publish(_ s: String, error: String = "") {
    state = s
    var v: Value = ["request": .string(request), "state": .string(s), "index": .int(Int64(index)), "count": .int(Int64(texts.count)), "rate": .double(rate)]
    if !error.isEmpty { v = v.with("error", .string(error)) }
    host.emit("speech.state", v)
  }

  /// An utterance started: the reader highlights it.
  func progress(_ i: Int) {
    index = i
    host.emit("speech.progress", ["request": .string(request), "index": .int(Int64(i)), "count": .int(Int64(texts.count))])
  }

  private func started(_ key: ObjectIdentifier) {
    guard let i = keys[key] else { return }
    progress(i)
  }

  private func finished(_ key: ObjectIdentifier) {
    guard let i = keys[key], i == texts.count - 1 else { return }
    synth?.delegate = nil
    synth = nil
    keys = [:]
    publish("done")
  }

  public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    let key = ObjectIdentifier(utterance)
    Task { @MainActor in self.started(key) }
  }

  public nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    let key = ObjectIdentifier(utterance)
    let s = ObjectIdentifier(synthesizer)
    Task { @MainActor in
      if let p = self.previewSynth, ObjectIdentifier(p) == s {
        self.previewSynth = nil
        return
      }
      self.finished(key)
    }
  }

  public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    let p = ObjectIdentifier(player)
    Task { @MainActor in self.playerFinished(p) }
  }
}
