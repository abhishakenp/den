// The reader's voice picker: which voice reads aloud, and remembering it. The host's `speech`
// service lists the Mac's voices and speaks; this file owns the choice,
// its memory and the ranking. The picker itself is drawn by resources/reader.js.
//
// Memory (storage ns "pagetools", key "voice"): `langs` keeps a voice per page language, `last` is
// the voice picked last (used when a page's language is unknown). A page in language L reads with
// langs[L]; with none, the Mac's own voice for L (System Settings > Accessibility > Read & Speak).
// Picking a voice in L's own language keeps it for L; picking one from another language uses it
// for this page only, unless "Use for all L pages" is on.
//
// Cost: nothing at launch beyond reading one storage key; the voice list is asked for only when
// the picker opens.

#if !hasFeature(Embedded)
  import CordisValue
#endif

struct VoiceRef: Equatable {
  var id: String
  var provider: String
  var name: String
  var lang: String

  var value: Value { ["id": .string(id), "provider": .string(provider), "name": .string(name), "lang": .string(lang)] }

  static func from(_ v: Value) -> VoiceRef? {
    let id = v.s("id")
    guard !id.isEmpty else { return nil }
    return VoiceRef(id: id, provider: v.sOpt("provider") ?? "system", name: v.s("name"), lang: v.sOpt("lang") ?? v.s("language"))
  }

  func same(_ o: VoiceRef?) -> Bool { o != nil && o!.id == id && o!.provider == provider }
}

extension PageToolsCore {
  /// Sample sentences for a voice's preview, by base language. Others say their own name.
  static let samples: [String: String] = [
    "en": "Hello! This is how I sound reading an article.",
    "fr": "Bonjour ! Voici ma voix quand je lis un article.",
    "de": "Hallo! So klinge ich, wenn ich einen Artikel vorlese.",
    "es": "¡Hola! Así sueno cuando leo un artículo.",
    "it": "Ciao! Ecco come suono quando leggo un articolo.",
    "pt": "Olá! É assim que eu soo ao ler um artigo.",
    "nl": "Hallo! Zo klink ik als ik een artikel voorlees.",
    "sv": "Hej! Så här låter jag när jag läser en artikel.",
    "da": "Hej! Sådan lyder jeg, når jeg læser en artikel op.",
    "nb": "Hei! Slik høres jeg ut når jeg leser en artikkel.",
    "fi": "Hei! Tältä kuulostan, kun luen artikkelin.",
    "pl": "Cześć! Tak brzmię, gdy czytam artykuł.",
    "cs": "Ahoj! Takhle zním, když čtu článek.",
    "ru": "Привет! Так звучит мой голос, когда я читаю статью.",
    "uk": "Привіт! Так звучить мій голос, коли я читаю статтю.",
    "tr": "Merhaba! Bir makale okurken sesim böyle.",
    "el": "Γεια σας! Έτσι ακούγομαι όταν διαβάζω ένα άρθρο.",
    "ar": "مرحبًا! هكذا يبدو صوتي عندما أقرأ مقالًا.",
    "he": "שלום! כך נשמע הקול שלי כשאני קורא מאמר.",
    "hi": "नमस्ते! लेख पढ़ते समय मेरी आवाज़ ऐसी लगती है।",
    "ja": "こんにちは。記事を読むときの私の声です。",
    "zh": "你好！这是我朗读文章时的声音。",
    "ko": "안녕하세요! 기사를 읽을 때 제 목소리는 이렇습니다.",
    "th": "สวัสดีครับ นี่คือเสียงของฉันเวลาอ่านบทความ",
    "vi": "Xin chào! Đây là giọng của tôi khi đọc một bài báo.",
    "id": "Halo! Beginilah suara saya saat membaca artikel.",
  ]

  static func sample(_ lang: String, name: String) -> String {
    if let s = samples[baseLang(lang)] { return s }
    return name.isEmpty ? "Hello!" : "Hello, I'm " + name + "."
  }

  /// "fr-CA" / "fr_CA" -> "fr".
  static func baseLang(_ lang: String) -> String {
    var out: [UInt8] = []
    for c in lang.utf8 {
      if c == 45 || c == 95 { break }
      out.append(c >= 65 && c <= 90 ? c + 32 : c)
    }
    return String(decoding: out, as: UTF8.self)
  }

  // MARK: Memory

  func loadVoices() {
    let v = env.call("storage", "get", ["ns": .string(Self.ns), "key": "voice"])
    voiceLast = VoiceRef.from(v["last"])
    voiceLangs = [:]
    for (k, x) in v["langs"].objectPairs { if let r = VoiceRef.from(x) { voiceLangs[k] = r } }
    for (k, x) in v["langNames"].objectPairs { if let n = x.string { voiceLangNames[k] = n } }
  }

  func saveVoices() {
    var langs: [(String, Value)] = []
    var names: [(String, Value)] = []
    for (k, r) in voiceLangs {
      langs.append((k, r.value))
      if let n = voiceLangNames[k] { names.append((k, .string(n))) }
    }
    save("voice", ["last": voiceLast?.value ?? .null, "langs": .object(langs), "langNames": .object(names)])
    if settingsRegistered { registerSettings() }
  }

  /// The page's language as a base code ("" when unknown).
  func pageLang(_ w: String) -> String { Self.baseLang(probes[w]?.lang ?? "") }

  /// The voice that reads `w`: this page's own pick, else the one kept for its language, else
  /// (language unknown) the last pick. nil: the Mac's voice for the page's language.
  func chosenVoice(_ w: String) -> VoiceRef? {
    if let v = pageVoice[w] { return v }
    let l = pageLang(w)
    if l.isEmpty { return voiceLast }
    return voiceLangs[l]
  }

  /// The speech args for `w`'s voice.
  func voiceArgs(_ w: String, into a: inout Value) {
    if let v = chosenVoice(w) {
      a.put("voice", .string(v.id))
      a.put("provider", .string(v.provider))
    }
  }

  /// The name on the toolbar's voice button.
  func voiceLabel(_ w: String) -> String {
    if let v = chosenVoice(w), !v.name.isEmpty { return v.name }
    let n = env.call("speech", "voice", ["lang": .string(probes[w]?.lang ?? "")]).s("name")
    return n.isEmpty ? "Voice" : n
  }

  // MARK: Picker

  /// Opens the picker in the reader: the voice list is read now, not before.
  func openVoices(_ w: String) {
    let r = env.call("speech", "voices")
    if userLang.isEmpty { userLang = env.call("translate", "userLanguage").s("lang") }
    let lang = pageLang(w)
    let sys = env.call("speech", "voice", ["lang": .string(probes[w]?.lang ?? "")])
    let cur = chosenVoice(w)
    let o: Value = [
      "voices": .array(Self.rank(r.a("voices"))),
      "current": cur.map { ["id": .string($0.id), "provider": .string($0.provider)] } ?? .null,
      "system": ["id": sys["id"], "name": sys["name"]],
      "pageLang": .string(lang), "userLang": .string(Self.baseLang(userLang)),
      "pinned": .bool(!lang.isEmpty && cur != nil && cur!.same(voiceLangs[lang])),
      "personal": r["personalVoice"],
    ]
    script(w, "voices", "return window.__denReader && window.__denReader.voices(o)", ["o": o])
  }

  func voiceMessage(_ w: String, _ action: String, _ v: Value) {
    switch action {
    case "voices": openVoices(w)
    case "pickVoice": if let r = VoiceRef.from(v) { pickVoice(w, r, langName: v.s("langName")) }
    case "previewVoice":
      guard let r = VoiceRef.from(v) else { return }
      if speaking != nil, speechState == "playing" { env.call("speech", "pause") }
      env.call("speech", "preview", ["voice": .string(r.id), "provider": .string(r.provider), "lang": .string(r.lang), "text": .string(Self.sample(r.lang, name: r.name))])
    case "systemVoice":
      pageVoice[w] = nil
      let l = pageLang(w)
      if l.isEmpty { voiceLast = nil } else { voiceLangs[l] = nil }
      saveVoices()
      applyVoice(w)
    case "pinVoice":
      let l = pageLang(w)
      guard !l.isEmpty else { return }
      if v.b("on") {
        let cur = chosenVoice(w) ?? VoiceRef.from(env.call("speech", "voice", ["lang": .string(probes[w]?.lang ?? "")]))
        guard let cur else { return }
        voiceLangs[l] = cur
        pageVoice[w] = nil
        if !v.s("langName").isEmpty { voiceLangNames[l] = v.s("langName") }
        toast("Pages in " + (voiceLangNames[l] ?? l) + " will use " + cur.name, icon: "sf:speaker.wave.2")
      } else {
        // The page keeps its voice for now; other pages go back to the Mac's voice.
        pageVoice[w] = chosenVoice(w)
        voiceLangs[l] = nil
      }
      saveVoices()
    case "moreVoices": env.call("speech", "openSettings")
    case "personalVoice":
      let s = env.call("speech", "personalVoice", ["request": true])
      if !s.b("pending") { openVoices(w) }
    default: break
    }
  }

  func pickVoice(_ w: String, _ r: VoiceRef, langName: String) {
    let l = pageLang(w)
    let rl = Self.baseLang(r.lang)
    voiceLast = r
    if !rl.isEmpty { voiceLangs[rl] = r }
    if !langName.isEmpty, !rl.isEmpty, rl == l { voiceLangNames[rl] = langName }
    if l.isEmpty || l == rl || r.same(voiceLangs[l]) {
      pageVoice[w] = nil
    } else if voiceLangs[l] != nil {
      voiceLangs[l] = r  // "Use for all L pages" is on: it now means this voice
    } else {
      pageVoice[w] = r  // another language's voice: this page only
    }
    saveVoices()
    applyVoice(w)
  }

  /// The toolbar and, when reading, the queue switch to `w`'s voice.
  func applyVoice(_ w: String) {
    script(w, "state", "return window.__denReader && window.__denReader.state(s)", ["s": ["voice": .string(voiceLabel(w))]])
    guard speaking == w else { return }
    var a: Value = ["lang": .string(probes[w]?.lang ?? "")]
    voiceArgs(w, into: &a)
    if a["voice"].isNull { a.put("voice", ""); a.put("provider", "system") }
    env.call("speech", "setVoice", a)
  }

  /// Within a language: premium, enhanced, then default; the user's own (Personal) voices first,
  /// novelty voices (Bells, Bubbles…) last; then by name. The picker groups by language itself.
  static func rank(_ voices: [Value]) -> [Value] {
    func score(_ v: Value) -> Int {
      var s = 0
      switch v.s("quality") {
      case "premium": s = 0
      case "enhanced": s = 1
      default: s = 2
      }
      if v.b("personal") { s -= 10 }
      if v.b("novelty") { s += 10 }
      return s
    }
    return voices.sorted { a, b in
      let sa = score(a), sb = score(b)
      if sa != sb { return sa < sb }
      return Array(Text.lower(a.s("name")).utf8).lexicographicallyPrecedes(Array(Text.lower(b.s("name")).utf8))
    }
  }

  /// Settings > Reading: the voices kept per language, each with Forget.
  func voiceSettingsItems() -> [Value] {
    var items: [Value] = []
    for (k, r) in voiceLangs {
      items.append(["id": .string(k), "title": .string(voiceLangNames[k] ?? k), "subtitle": .string(r.name), "icon": "sf:speaker.wave.2",
                    "buttons": [["id": "forget", "title": "Use System Voice"]]])
    }
    return items
  }
}
