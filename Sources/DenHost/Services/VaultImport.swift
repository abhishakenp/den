import AppKit
import CordisValue
import Foundation
import UniformTypeIdentifiers

/// RFC 4180 CSV: quoted fields, "" escapes, CRLF or LF, newlines inside quotes, a UTF-8 BOM.
/// Blank lines are dropped.
enum CSV {
  static func parse(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field: [UInt8] = []
    var quoted = false
    var bytes = Array(text.utf8)
    if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
    func endField() {
      row.append(String(decoding: field, as: UTF8.self))
      field = []
    }
    func endRow() {
      endField()
      if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
      row = []
    }
    var i = 0
    while i < bytes.count {
      let c = bytes[i]
      if quoted {
        if c == 34 {  // "
          if i + 1 < bytes.count, bytes[i + 1] == 34 { field.append(34); i += 1 } else { quoted = false }
        } else {
          field.append(c)
        }
      } else {
        switch c {
        case 34 where field.isEmpty: quoted = true
        case 44: endField()  // ,
        case 13: if i + 1 < bytes.count, bytes[i + 1] == 10 { i += 1 }; endRow()
        case 10: endRow()
        default: field.append(c)
        }
      }
      i += 1
    }
    if !field.isEmpty || !row.isEmpty { endRow() }
    return rows
  }
}

/// `vault.importFile`: logins from another password manager's CSV export into den's vault, after
/// Touch ID. The plugin names the columns (Chrome, Safari, 1Password, Bitwarden, Firefox headers);
/// the passwords never leave the host, the file is only read.
extension VaultService {
  static let defaultPickFile: (String, String, @escaping @MainActor (URL?) -> Void) -> Void = { message, prompt, done in
    MainActor.assumeIsolated {
      let panel = NSOpenPanel()
      panel.canChooseFiles = true
      panel.canChooseDirectories = false
      panel.allowsMultipleSelection = false
      panel.allowedContentTypes = [.commaSeparatedText, .plainText]
      if !message.isEmpty { panel.message = message }
      panel.prompt = prompt.isEmpty ? "Choose" : prompt
      if let w = NSApp.keyWindow ?? NSApp.mainWindow {
        panel.beginSheetModal(for: w) { r in MainActor.assumeIsolated { done(r == .OK ? panel.url : nil) } }
      } else {
        done(panel.runModal() == .OK ? panel.url : nil)
      }
    }
  }

  func importFile(_ args: Value) -> Value {
    let request = requestId(args)
    let cols = args["columns"]
    let names: (String) -> [String] = { k in cols.list(k).compactMap { $0.string?.lowercased() } }
    let originNames = names("origin"), userNames = names("username"), passNames = names("password")
    func finish(_ ok: Bool, _ error: String?, added: Int = 0, existing: Int = 0, skipped: Int = 0) {
      var v: Value = ["request": .string(request), "method": "importFile", "ok": .bool(ok), "added": .int(Int64(added)),
                      "existing": .int(Int64(existing)), "skipped": .int(Int64(skipped))]
      if let error { v = v.with("error", .string(error)) }
      host.emit("vault.result", v)
    }
    pickFile(args.str("message"), args.str("prompt", "Choose")) { [weak self] url in
      guard let self else { return }
      guard let url else { return finish(false, "cancelled") }
      self.auth.authenticate(reason: "import passwords") { [weak self] ok, _ in
        guard let self else { return }
        guard ok else { return finish(false, self.refusal) }
        guard let data = try? Data(contentsOf: url) else { return finish(false, "unreadable") }
        let rows = CSV.parse(String(decoding: data, as: UTF8.self))
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) else { return finish(false, "no columns") }
        func index(_ wanted: [String]) -> Int? {
          for n in wanted { if let i = header.firstIndex(of: n) { return i } }
          return nil
        }
        guard let oi = index(originNames), let pi = index(passNames) else { return finish(false, "no columns") }
        let ui = index(userNames)
        var added = 0, existing = 0, skipped = 0
        var saved = Set(self.store.accounts().map { $0.origin + "\n" + $0.username })
        for row in rows.dropFirst() {
          func at(_ i: Int?) -> String { i.flatMap { $0 < row.count ? row[$0] : nil } ?? "" }
          var raw = at(oi).trimmingCharacters(in: .whitespaces)
          if !raw.isEmpty, !raw.contains("://") { raw = "https://" + raw }
          let origin = Self.origin(of: URL(string: raw))
          let user = at(ui), pass = at(pi)
          guard !origin.isEmpty, !pass.isEmpty else { skipped += 1; continue }
          let key = origin + "\n" + user
          guard !saved.contains(key) else { existing += 1; continue }
          if self.store.save(origin: origin, username: user, password: Data(pass.utf8)) == errSecSuccess {
            saved.insert(key)
            added += 1
          } else {
            skipped += 1
          }
        }
        finish(true, nil, added: added, existing: existing, skipped: skipped)
      }
    }
    return ["request": .string(request)]
  }
}
