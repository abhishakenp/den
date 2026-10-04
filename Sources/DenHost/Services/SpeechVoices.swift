import AVFoundation
import AppKit
import CordisValue

/// `speech` voices: what can speak, one voice for a label, a spoken sample, Personal Voice and
/// the system's voice settings. Nothing here runs until a plugin asks (a voice picker opening):
/// the voice list is read from macOS on each `voices` call and never kept.
///
/// | Method | Args | Returns |
/// |---|---|---|
/// | `voices` | – | `{voices: [voice], personalVoice}`. Every installed macOS voice (`AVSpeechSynthesisVoice.speechVoices()`) |
/// | `voice` | `voice?`, `lang?` | `voice`: the one that would speak (with no `voice`, the system's voice for `lang`), or `{}` |
/// | `preview` | `text`, `voice?`, `lang?`, `volume?` | ok. Speaks `text` once beside the queue (a new preview replaces the last) |
/// | `personalVoice` | `request?` | `{status: notDetermined|denied|unsupported|authorized}`. With `request` (after a click), asks macOS once and emits `speech.personalVoice {status}` |
/// | `openSettings` | – | ok. System Settings > Accessibility > Read & Speak (Spoken Content), where voices are downloaded |
///
/// A voice: `{id, name, language (BCP 47), quality: default|enhanced|premium, gender?: male|female,
/// provider: "system", novelty?, personal?}`.
extension SpeechService {
  static let system = "system"
  /// Verified on macOS 26.5: opens Accessibility > Read & Speak (the pane was "Spoken Content").
  static let settingsURL = "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent"

  static func systemVoice(id: String, lang: String) -> AVSpeechSynthesisVoice? {
    if !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
    return lang.isEmpty ? nil : AVSpeechSynthesisVoice(language: lang)
  }

  static func quality(_ q: AVSpeechSynthesisVoiceQuality) -> String {
    switch q {
    case .premium: return "premium"
    case .enhanced: return "enhanced"
    default: return "default"
    }
  }

  static func info(_ v: AVSpeechSynthesisVoice) -> Value {
    var pairs: [(String, Value)] = [("id", .string(v.identifier)), ("name", .string(v.name)), ("language", .string(v.language)),
                                    ("quality", .string(quality(v.quality))), ("provider", .string(system))]
    switch v.gender {
    case .male: pairs.append(("gender", "male"))
    case .female: pairs.append(("gender", "female"))
    default: break
    }
    if v.voiceTraits.contains(.isNoveltyVoice) { pairs.append(("novelty", true)) }
    if v.voiceTraits.contains(.isPersonalVoice) { pairs.append(("personal", true)) }
    return .object(pairs)
  }

  func voices() -> Value {
    let list = AVSpeechSynthesisVoice.speechVoices().map(Self.info)
    return ["voices": .array(list), "personalVoice": .string(Self.personalStatus(AVSpeechSynthesizer.personalVoiceAuthorizationStatus))]
  }

  func voice(_ args: Value) -> Value {
    let lang = args.str("lang")
    guard let v = Self.systemVoice(id: args.str("voice"), lang: lang.isEmpty ? AVSpeechSynthesisVoice.currentLanguageCode() : lang) else { return [:] }
    return Self.info(v)
  }

  func preview(_ args: Value) -> Value {
    let text = args.str("text")
    guard !text.isEmpty else { return .error("speech: nothing to preview") }
    stopPreview()
    let vol = volumeOverride ?? Float(min(1, max(0, args.num("volume", 1))))
    let s = AVSpeechSynthesizer()
    let u = AVSpeechUtterance(string: text)
    if let v = Self.systemVoice(id: args.str("voice"), lang: args.str("lang")) { u.voice = v }
    u.volume = vol
    previewSynth = s
    if silent {
      nonisolated(unsafe) let synthRef = s
      nonisolated(unsafe) var ended = false
      s.write(u) { [weak self] buffer in
        guard !ended, (buffer as? AVAudioPCMBuffer)?.frameLength ?? 0 == 0 else { return }
        ended = true
        Task { @MainActor in if let self, self.previewSynth === synthRef { self.previewSynth = nil } }
      }
    } else {
      s.delegate = self
      s.speak(u)
    }
    return .ok
  }

  /// A preview is speaking.
  public var previewing: Bool { previewSynth != nil }

  func stopPreview() {
    previewSynth?.delegate = nil
    previewSynth?.stopSpeaking(at: .immediate)
    previewSynth = nil
  }

  static func personalStatus(_ s: AVSpeechSynthesizer.PersonalVoiceAuthorizationStatus) -> String {
    switch s {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .unsupported: return "unsupported"
    default: return "notDetermined"
    }
  }

  /// Personal Voice (macOS 14+): voices the user recorded, listed only once they allow den to use
  /// them. macOS asks only on `request`, which a plugin sends after a click, never on its own.
  func personalVoice(_ args: Value) -> Value {
    let s = AVSpeechSynthesizer.personalVoiceAuthorizationStatus
    guard args.flag("request"), s == .notDetermined, !TestMode.active else { return ["status": .string(Self.personalStatus(s))] }
    // @Sendable: macOS answers on its own queue, not the main actor's.
    AVSpeechSynthesizer.requestPersonalVoiceAuthorization { @Sendable [weak self] status in
      let name = SpeechService.personalStatus(status)
      Task { @MainActor in self?.host.emit("speech.personalVoice", ["status": .string(name)]) }
    }
    return ["status": "notDetermined", "pending": true]
  }

  func openSettings() -> Value {
    settingsOpened += 1
    if !TestMode.active, let url = URL(string: Self.settingsURL) { NSWorkspace.shared.open(url) }
    return .ok
  }
}
