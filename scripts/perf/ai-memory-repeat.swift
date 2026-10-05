// Den-process residue across repeated requests (one session per request, dropped after).
import Darwin
import Foundation
import FoundationModels

func selfMB() -> Double {
  var info = task_vm_info_data_t()
  var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
  _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
  return Double(info.phys_footprint) / 1_048_576
}

@Generable struct Groups {
  @Guide(description: "Groups of related items") var groups: [G]
}
@Generable struct G {
  var name: String
  var items: [Int]
}

print(String(format: "start %.1fMB", selfMB()))
for i in 1...4 {
  let t0 = Date()
  do {
    let s = LanguageModelSession(instructions: "Sort numbered items into groups.")
    if i % 2 == 0 {
      let r = try await s.respond(to: "1. Lisbon trip\n2. Swift docs\n3. Lisbon hotels\n4. Swift forums", generating: Groups.self)
      _ = r.content.groups.count
    } else {
      _ = try await s.respond(to: "Summarize: Alice asked you to review PR #\(i).").content
    }
  } catch { print("error \(error)") }
  print(String(format: "request %d (%@) %.0f ms -> %.1fMB", i, i % 2 == 0 ? "guided" : "text", Date().timeIntervalSince(t0) * 1000, selfMB()))
}
try? await Task.sleep(for: .seconds(30))
print(String(format: "after+30s %.1fMB", selfMB()))
