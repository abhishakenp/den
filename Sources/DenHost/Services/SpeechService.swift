import AVFoundation
import CordisValue

/// `speech` service: text to speech with the system voices (`AVSpeechSynthesizer`), on device.
/// One queue at a time. The synthesizer is created on the first `speak` and released when the
/// queue ends or stops, so an unused den pays nothing. Listing voices (SpeechVoices.swift)
/// happens only when asked.
///
/// | Method | Args | Returns |
/// |---|---|---|
/// | `speak` | `utterances: [string]`, `voice?` (a voice id), `lang?` (BCP 47, picks the system voice when there's no `voice`), `rate?` (1 = normal), `volume?` (0–1), `from?` (index), `request?` | `{request}`. Replaces the current queue |
/// | `pause`, `resume`, `stop` | – | ok |
/// | `setRate` | `rate` | ok. Restarts at the current utterance |
/// | `setVoice` | `voice?`, `lang?` | ok. Restarts at the current utterance in that voice |
/// | `state` | – | `{request, state, index, count, rate, voice}` |
/// | `voices`, `voice`, `preview`, `personalVoice`, `openSettings` | | see SpeechVoices.swift |
///
/// Events: `speech.progress {request, index, count}` as each utterance starts, and
/// `speech.state {request, state: playing|paused|stopped|done, index, count, rate}`.
@MainActor
public final class SpeechService: NSObject, HostService, AVSpeechSynthesizerDelegate {
  public let name = "speech"
  let host: ServiceHost
  var synth: AVSpeechSynthesizer?
  var texts: [String] = []
  var keys: [ObjectIdentifier: Int] = [:]
  var request = ""
  var lang = ""
  /// The queue's voice (an `AVSpeechSynthesisVoice` identifier). Empty: the system voice for `lang`.
  var voiceId = ""
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

  // Preview (SpeechVoices.swift)
  var previewSynth: AVSpeechSynthesizer?
  /// Times `openSettings` ran (tests don't open System Settings).
  public internal(set) var settingsOpened = 0

  public init(host: ServiceHost) { self.host = host }

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "speak":
      let list = args.list("utterances").compactMap { $0.string }.filter { !$0.isEmpty }
      guard !list.isEmpty else { return .error("speech: nothing to speak") }
      stop(emit: false)
      texts = list
      request = args.str("request")
      if request.isEmpty { request = "speech-\(nextRequest)"; nextRequest += 1 }
      lang = args.str("lang")
      voiceId = args.str("voice")
      if let r = args["rate"].double { rate = min(2.5, max(0.5, r)) }
      volume = Float(min(1, max(0, args.num("volume", 1))))
      start(at: min(max(0, Int(args.num("from", 0))), texts.count - 1))
      return ["request": .string(request)]
    case "pause":
      guard state == "playing", let synth else { return .ok }
      synth.pauseSpeaking(at: .word)
      publish("paused")
    case "resume":
      guard state == "paused", let synth else { return .ok }
      synth.continueSpeaking()
      publish("playing")
    case "stop": stop(emit: true)
    case "setRate":
      rate = min(2.5, max(0.5, args.num("rate", 1)))
      restart()
    case "setVoice":
      if !args["lang"].isNull { lang = args.str("lang") }
      guard voiceId != args.str("voice") else { return .ok }
      voiceId = args.str("voice")
      restart()
    case "state":
      return ["request": .string(request), "state": .string(state), "index": .int(Int64(index)), "count": .int(Int64(texts.count)), "rate": .double(rate),
              "voice": .string(voiceId)]
    case "voices": return voices()
    case "voice": return voice(args)
    case "preview": return preview(args)
    case "personalVoice": return personalVoice(args)
    case "openSettings": return openSettings()
    default: return .error("speech: unknown method '\(method)'")
    }
    return .ok
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
    stopPreview()
    guard let synth else { return }
    synth.delegate = nil
    synth.stopSpeaking(at: .immediate)
    self.synth = nil
    keys = [:]
    if emit { publish("stopped") } else { state = "stopped" }
  }

  func publish(_ s: String) {
    state = s
    host.emit("speech.state", ["request": .string(request), "state": .string(s), "index": .int(Int64(index)), "count": .int(Int64(texts.count)), "rate": .double(rate)])
  }

  /// An utterance started: the reader highlights it.
  private func started(_ key: ObjectIdentifier) {
    guard let i = keys[key] else { return }
    index = i
    host.emit("speech.progress", ["request": .string(request), "index": .int(Int64(i)), "count": .int(Int64(texts.count))])
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
}
