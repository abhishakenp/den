// Memory before / during / after one on-device generation, the way den's AIService makes it
// (a fresh LanguageModelSession per request, dropped when the request ends).
// Own process: phys_footprint (TASK_VM_INFO). Model processes: top's MEM column (phys footprint).
// Run: xcrun swiftc -O scripts/perf/ai-memory.swift -o /tmp/ai-memory && /tmp/ai-memory (needs Apple Intelligence).
import Darwin
import Foundation
import FoundationModels

func selfMB() -> Double {
  var info = task_vm_info_data_t()
  var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
  _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
  return Double(info.phys_footprint) / 1_048_576
}

let names = ["TGOnDeviceInferenceProviderService", "modelmanagerd", "generativeexperiencesd", "GenerativeExperiencesSafetyInferenceProvider"]

func sh(_ cmd: String) -> String {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/bin/zsh")
  p.arguments = ["-c", cmd]
  let out = Pipe()
  p.standardOutput = out
  try? p.run()
  p.waitUntilExit()
  return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

func daemons() -> String {
  var parts: [String] = []
  for n in names {
    let pids = sh("pgrep -x \(n)").split(separator: "\n").joined(separator: " -pid ")
    if pids.isEmpty { parts.append("\(n)=none"); continue }
    let mem = sh("top -l 1 -pid \(pids) -stats pid,mem | tail -n +13 | awk '{print $2}' | tr '\\n' ' '")
    parts.append("\(n)=[\(mem.trimmingCharacters(in: .whitespaces))]")
  }
  return parts.joined(separator: " ")
}

func report(_ label: String) {
  print(String(format: "%-14@ self=%.1fMB  %@", label as NSString, selfMB(), daemons()))
  fflush(stdout)
}

let waitBefore = Double(CommandLine.arguments.dropFirst().first ?? "0") ?? 0
if waitBefore > 0 { Thread.sleep(forTimeInterval: waitBefore) }
report("start")
_ = SystemLanguageModel.default.availability
report("availability")
let sampler = Task.detached {
  var n = 0
  while !Task.isCancelled {
    try? await Task.sleep(for: .milliseconds(700))
    n += 1
    report("during#\(n)")
  }
}
let t0 = Date()
do {
  let session = LanguageModelSession(instructions: "You summarize a person's work notifications.")
  let r = try await session.respond(to: (1...30).map { "- Alice asked you to review PR #\($0) in den by Friday" }.joined(separator: "\n"))
  print("generated \(r.content.count) chars in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
} catch { print("error \(error)") }
sampler.cancel()
report("done")
for s in [5.0, 30, 60, 120, 180] {
  let target = t0.addingTimeInterval(s)
  Thread.sleep(until: target)
  report("after+\(Int(s))s")
}
