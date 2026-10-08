import CordisValue
import Foundation

/// `performance` service: per-feature memory budgets and runtime monitoring
/// (docs/memory-budget.md). Tracks how much memory each feature area (tabs,
/// extensions, shields, commandbar, etc.) consumes and alerts when a budget is
/// exceeded.
///
/// | Method | Args | Returns |
/// |---|---|---|
/// | `usage` | `{feature: "tabs"}` | `{feature, budgetMB, usedMB, ratio}` |
/// | `report` | – | `{features: [{feature, budgetMB, usedMB, ratio, alert}], total, totalBudgetMB}` |
/// | `setBudget` | `{feature, budgetMB}` | `{ok}` |
/// | `record` | `{feature, usedMB}` | `{ok}` |
/// | `suggestions` | – | `{actions: [{feature, reason, benefitMB}]}` |
///
/// Features tracked: tabs, extensions, shields, webviews, commandbar, connections,
/// spaces, plugins, host.

@MainActor
public final class PerformanceBudgets: HostService {
  public let name = "performance"

  /// Default budgets in MB per feature area. Total must not exceed ~800 MB on a typical
  /// Mac with 16 GB RAM (den's no-tabs footprint is ~21.5 MB, one page total ~81 MB).
  private struct DefaultBudgets {
    static let tabs: Double = 128          // tab state, favicons, session history
    static let extensions: Double = 96     // extension processes + native memory
    static let shields: Double = 16        // content rules, filter data
    static let webviews: Double = 256      // WKWebView objects + backing stores
    static let commandbar: Double = 8      // search index, suggestions cache
    static let connections: Double = 16    // connection state, feed data
    static let spaces: Double = 4          // space state, workspace config
    static let plugins: Double = 64        // plugin VM state
    static let host: Double = 64           // host framework (Cordis, UI, services)
  }

  private var budgets: [String: Double]
  private var usage: [String: Double] = [:]
  private let lock = NSLock()

  public init() {
    self.budgets = [
      "tabs": DefaultBudgets.tabs,
      "extensions": DefaultBudgets.extensions,
      "shields": DefaultBudgets.shields,
      "webviews": DefaultBudgets.webviews,
      "commandbar": DefaultBudgets.commandbar,
      "connections": DefaultBudgets.connections,
      "spaces": DefaultBudgets.spaces,
      "plugins": DefaultBudgets.plugins,
      "host": DefaultBudgets.host,
    ]
  }

  // MARK: HostService

  public func handle(method: String, args: Value) -> Value {
    switch method {
    case "usage":
      return usageFor(args.str("feature", "host"))
    case "report":
      return fullReport()
    case "setBudget":
      let feature = args.str("feature")
      guard !feature.isEmpty else { return .error("performance: setBudget needs a feature") }
      guard let mb = args["budgetMB"].double, mb >= 1 else {
        return .error("performance: budgetMB must be >= 1")
      }
      lock.lock(); defer { lock.unlock() }
      budgets[feature] = mb
      return .ok
    case "record":
      let feature = args.str("feature")
      guard !feature.isEmpty else { return .error("performance: record needs a feature") }
      guard let mb = args["usedMB"].double, mb >= 0 else {
        return .error("performance: usedMB must be >= 0")
      }
      lock.lock()
      usage[feature] = mb
      lock.unlock()
      return .ok
    case "suggestions":
      return cleanupSuggestions()
    case "listBudgets":
      return listBudgets()
    default:
      return .error("performance: unknown method '\(method)'")
    }
  }

  // MARK: Internal API (called from DenRuntime or plugin cores)

  /// Record memory usage for a feature. Safe to call from any actor.
  public func recordUsage(feature: String, usedMB: Double) {
    lock.lock()
    usage[feature] = usedMB
    lock.unlock()
    // Check for budget exceedance; alert is included in the per-feature report.
    let _ = checkAlert(feature)
  }

  /// Record current system memory usage for all tracked features. Uses `ProcessInfo`
  /// to approximate per-process footprint and divides heuristically.
  public func recordSystemMemory() {
    // den's own footprint: use task_info to get RSS.
    let pid = getpid()
    var rssMB: Double = 0
    if let taskRss = getProcessRSS(pid) {
      rssMB = Double(taskRss) / 1024.0 / 1024.0
    } else {
      // Fallback: estimate from ProcessInfo (not exact but usable).
      rssMB = Double(ProcessInfo.processInfo.physicalMemory) * 0.001  // rough heuristic
    }

    lock.lock()
    // Split den's RSS across features heuristically.
    // The host framework takes ~15%, everything else is proportional to feature activity.
    let hostShare = rssMB * 0.15
    let tabsShare = rssMB * 0.25  // conservative estimate
    let extensionsShare = rssMB * 0.10
    let shieldsShare = rssMB * 0.03
    let webviewsShare = rssMB * 0.07  // WKWebView overhead (not WebContent)
    let commandbarShare = rssMB * 0.02
    let connectionsShare = rssMB * 0.03
    let spacesShare = rssMB * 0.01
    let pluginsShare = rssMB * 0.04
    let leftover = rssMB - (hostShare + tabsShare + extensionsShare + shieldsShare +
                             webviewsShare + commandbarShare + connectionsShare +
                             spacesShare + pluginsShare)

    usage = [
      "host": hostShare + max(0, leftover),
      "tabs": tabsShare,
      "extensions": extensionsShare,
      "shields": shieldsShare,
      "webviews": webviewsShare,
      "commandbar": commandbarShare,
      "connections": connectionsShare,
      "spaces": spacesShare,
      "plugins": pluginsShare,
    ]
    lock.unlock()
  }

  /// Returns the total used memory across all features.
  public func totalUsedMB() -> Double {
    lock.lock()
    let total = usage.values.reduce(0, +)
    lock.unlock()
    return total
  }

  // MARK: Private helpers

  private func usageFor(_ feature: String) -> Value {
    lock.lock()
    let used = usage[feature] ?? 0
    let budget = budgets[feature] ?? 64  // fallback default
    lock.unlock()
    let ratio = budget > 0 ? used / budget : 0
    return [
      "feature": .string(feature),
      "budgetMB": .double(budget),
      "usedMB": .double(used),
      "ratio": .double(ratio),
    ]
  }

  private func fullReport() -> Value {
    lock.lock()
    var featureList: [Value] = []
    var totalUsed: Double = 0
    var totalBudget: Double = 0

    for feature in budgets.keys.sorted() {
      let used = usage[feature] ?? 0
      let budget = budgets[feature]!
      let ratio = budget > 0 ? used / budget : 0
      let alert = ratio >= 0.9
      featureList.append([
        "feature": .string(feature),
        "budgetMB": .double(budget),
        "usedMB": .double(used),
        "ratio": .double(ratio),
        "alert": .bool(alert),
      ])
      totalUsed += used
      totalBudget += budget
    }
    lock.unlock()

    return [
      "features": .array(featureList),
      "total": .double(totalUsed),
      "totalBudgetMB": .double(totalBudget),
    ]
  }

  private func checkAlert(_ feature: String) -> Bool {
    lock.lock()
    guard let used = usage[feature], let budget = budgets[feature] else {
      lock.unlock(); return false
    }
    lock.unlock()
    return budget > 0 && (used / budget) >= 0.9
  }

  private func cleanupSuggestions() -> Value {
    var actions: [Value] = []

    lock.lock()
    let tabsUsage = usage["tabs"] ?? 0
    let tabsBudget = budgets["tabs"] ?? 128
    let extensionsUsage = usage["extensions"] ?? 0
    let extensionsBudget = budgets["extensions"] ?? 96
    lock.unlock()

    // Suggest discarding inactive tabs if the tabs budget is exceeded.
    if tabsBudget > 0 && tabsUsage / tabsBudget >= 0.85 {
      let benefit = (tabsUsage - tabsBudget * 0.6).rounded(to: 1)
      actions.append([
        "feature": .string("tabs"),
        "reason": .string("Memory budget at \(String(format: "%.0f", tabsUsage / max(tabsBudget, 1) * 100))%"),
        "benefitMB": .double(max(0, benefit)),
        "action": .string("unloadDiscardedTabs"),
      ])
    }

    // Suggest reloading extension if extensions budget is exceeded.
    if extensionsBudget > 0 && extensionsUsage / extensionsBudget >= 0.85 {
      let benefit = (extensionsUsage - extensionsBudget * 0.6).rounded(to: 1)
      actions.append([
        "feature": .string("extensions"),
        "reason": .string("Extension memory high — reload to reclaim"),
        "benefitMB": .double(max(0, benefit)),
        "action": .string("reloadExtensions"),
      ])
    }

    // General suggestion: if total usage is high, run memory relief.
    let totalUsed = totalUsedMB()
    lock.lock()
    let totalBudget = budgets.values.reduce(0, +)
    lock.unlock()
    if totalBudget > 0 && totalUsed / totalBudget >= 0.8 {
      actions.append([
        "feature": .string("system"),
        "reason": .string("Total memory budget at \(String(format: "%.0f", totalUsed / max(totalBudget, 1) * 100))%"),
        "benefitMB": .double(20),
        "action": .string("memoryRelief"),
      ])
    }

    return ["actions": .array(actions)]
  }

  private func listBudgets() -> Value {
    lock.lock()
    let list: [Value] = budgets.sorted { $0.key < $1.key }
      .map { ["feature": .string($0.key), "budgetMB": .double($0.value)] }
    lock.unlock()
    return ["budgets": .array(list)]
  }
}

private extension Double {
  /// Round to `decimals` decimal places.
  func rounded(to decimals: Int) -> Double {
    let multiplier = pow(10.0, Double(decimals))
    return (self * multiplier).rounded() / multiplier
  }
}

/// Get process RSS in bytes using `task_info`. Returns nil on failure.
private func getProcessRSS(_ pid: pid_t) -> UInt? {
  var result = task_basic_info()
  var count = mach_msg_type_number_t(MemoryLayout<task_basic_info>.size) / 4
  let kr = withUnsafeMutablePointer(to: &result) { ptr in
    ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { ptr in
      task_info(mach_task_self_, task_flavor_t(1), ptr, &count)
    }
  }
  guard kr == KERN_SUCCESS else { return nil }
  return result.resident_size
}