import AVFoundation
import CordisValue

/// `speech` service: text to speech with the system voices (`AVSpeechSynthesizer`), on device.
/// One queue at a time. The synthesizer is created on the first `speak` and released when the
/// queue ends or stops, so an unused den pays nothing.
///
/// | Method | Args | Returns |
/// |---|---|---|
/// | `speak` | `utterances: [string]`, `lang?` (BCP 47, picks the system voice), `rate?` (1 = normal), `volume?` (0–1), `from?` (index), `request?` | `{request}`. Replaces the current queue |
/// | `pause`, `resume`, `stop` | – | ok |
/// | `setRate` | `rate` | ok. Restarts at the current utterance |
/// | `state` | – | `{request, state, index, count, rate}` |
///
/// Events: `speech.progress {request, index, count}` as each utterance starts, and
/// `speech.state {request, state: playing|paused|stopped|done, index, count, rate}`.
@MainActor
public final class SpeechService: NSObject, HostService, AVSpeechSynthesizerDelegate {
  public let name = "speech"
  let host: ServiceHost
  private var synth: AVSpeechSynthesizer?
  private var texts: [String] = []
  private var keys: [ObjectIdentifier: Int] = [:]
  private var request = ""
  private var lang = ""
  private var volume: Float = 1
  private var nextRequest = 1
  private(set) var index = 0
  private(set) var rate: Double = 1
  private(set) var state = "stopped"
  /// Scenarios mute speech (read-aloud snapshots shouldn't talk).
  public var volumeOverride: Float?

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
      guard synth != nil, !texts.isEmpty else { return .ok }
      let paused = state == "paused"
      synth?.delegate = nil
      synth?.stopSpeaking(at: .immediate)
      synth = nil
      start(at: index)
      if paused { _ = handle(method: "pause", args: .null) }
    case "state":
      return ["request": .string(request), "state": .string(state), "index": .int(Int64(index)), "count": .int(Int64(texts.count)), "rate": .double(rate)]
    default: return .error("speech: unknown method '\(method)'")
    }
    return .ok
  }

  private func start(at first: Int) {
    let s = AVSpeechSynthesizer()
    s.delegate = self
    synth = s
    keys = [:]
    let voice = lang.isEmpty ? nil : AVSpeechSynthesisVoice(language: lang)
    let r = Float(Double(AVSpeechUtteranceDefaultSpeechRate) * rate)
    for i in first..<texts.count {
      let u = AVSpeechUtterance(string: texts[i])
      u.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, r))
      u.volume = volumeOverride ?? volume
      if let voice { u.voice = voice }
      keys[ObjectIdentifier(u)] = i
      s.speak(u)
    }
    index = first
    publish("playing")
  }

  private func stop(emit: Bool) {
    guard let synth else { return }
    synth.delegate = nil
    synth.stopSpeaking(at: .immediate)
    self.synth = nil
    keys = [:]
    if emit { publish("stopped") } else { state = "stopped" }
  }

  private func publish(_ s: String) {
    state = s
    host.emit("speech.state", ["request": .string(request), "state": .string(s), "index": .int(Int64(index)), "count": .int(Int64(texts.count)), "rate": .double(rate)])
  }

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
    Task { @MainActor in self.finished(key) }
  }
}
