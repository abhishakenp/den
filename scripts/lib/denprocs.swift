// Prints the processes macOS holds `pid` responsible for (den's WebKit WebContent, Networking
// and GPU processes), one "pid name" per line. WebKit's XPC services are children of launchd, so
// ppid can't find them, and diffing pgrep before/after picks up other browsers' processes.
// usage: swiftc -O scripts/lib/denprocs.swift -o build/denprocs && build/denprocs <pid>
import Darwin

@_silgen_name("responsibility_get_pid_responsible_for_pid") func responsiblePid(_ pid: pid_t) -> pid_t

guard CommandLine.arguments.count > 1, let target = pid_t(CommandLine.arguments[1]) else {
  print("usage: denprocs <pid>")
  exit(2)
}
var count = proc_listallpids(nil, 0)
var pids = [pid_t](repeating: 0, count: Int(count) + 64)
count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
for p in pids.prefix(Int(max(0, count))) where p > 0 && p != target && responsiblePid(p) == target {
  var buf = [CChar](repeating: 0, count: 4096)
  proc_pidpath(p, &buf, 4096)
  let path = String(cString: buf)
  print(p, path.split(separator: "/").last.map(String.init) ?? path)
}
