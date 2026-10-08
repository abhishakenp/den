// Routing settings UI: a custom panel for managing link routing rules with test-ping.

import AppKit
import CordisValue

/// Settings integration for link routing. Registers a rules list and test-ping in den's Settings window.
@MainActor
public final class RoutingSettingsPanel: FlippedView {
  private let routingService: LinkRoutingService
  private let host: ServiceHost

  // Test-ping controls
  private let testPatternField = NSTextField(string: "")
  private let testUrlField = NSTextField(string: "")
  private let testResult = NSTextField(wrappingLabelWithString: "")
  private let testButton = NSButton(title: "Test", target: nil, action: nil)

  init(routing: LinkRoutingService, host: ServiceHost) {
    self.routingService = routing
    self.host = host
    super.init(frame: .zero)
    testPatternField.placeholderString = "Regex pattern"
    testPatternField.bezelStyle = .roundedBezel
    testPatternField.controlSize = .small
    testPatternField.font = .systemFont(ofSize: 12)

    testUrlField.placeholderString = "URL to test against"
    testUrlField.bezelStyle = .roundedBezel
    testUrlField.controlSize = .small
    testUrlField.font = .systemFont(ofSize: 12)

    testResult.font = .systemFont(ofSize: 11)
    testResult.isEditable = false
    testResult.isSelectable = true
    testResult.textColor = NSColor.systemBlue

    testButton.title = "Ping"
    testButton.bezelStyle = .push
    testButton.controlSize = .small
    testButton.font = .systemFont(ofSize: 12)

    build()
  }

  required init?(coder: NSCoder) { fatalError() }

  private func build() {
    // Header
    let header = makeLabel("Link Routing Rules", size: 13, weight: .semibold)
    let subtitle = makeLabel("Match URL patterns with regex and control how links open. Rules fire in priority order (lowest first).", size: 11)
    subtitle.textColor = NSColor.secondaryLabelColor

    // Test-ping area
    let testStack = NSStackView()
    testStack.orientation = .vertical
    testStack.spacing = 4

    let testFields = NSStackView(views: [
      testPatternField,
      testUrlField,
    ])
    testFields.orientation = .horizontal
    testFields.spacing = 4

    let testActions = NSStackView(views: [testButton, testResult])
    testActions.orientation = .horizontal
    testActions.alignment = .bottom
    testActions.spacing = 4

    testStack.addArrangedSubview(testFields)
    testStack.addArrangedSubview(testActions)
    testStack.translatesAutoresizingMaskIntoConstraints = false

    let content = NSStackView(views: [header, subtitle, testStack])
    content.orientation = .vertical
    content.spacing = 8
    content.translatesAutoresizingMaskIntoConstraints = false

    addSubview(content)
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: topAnchor, constant: 12),
      content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
    ])

    // Wire test button
    testButton.target = self
    testButton.action = #selector(testPing)
  }

  @objc private func testPing(_ sender: NSButton) {
    let pattern = testPatternField.stringValue.trimmingCharacters(in: .whitespaces)
    let url = testUrlField.stringValue.trimmingCharacters(in: .whitespaces)
    if pattern.isEmpty {
      testResult.stringValue = "Enter a regex pattern."
      testResult.textColor = NSColor.systemRed
      return
    }
    if url.isEmpty {
      testResult.stringValue = "Enter a URL to test against."
      testResult.textColor = NSColor.systemRed
      return
    }
    do {
      _ = try NSRegularExpression(pattern: pattern, options: [])
    } catch {
      testResult.stringValue = "Invalid regex: \(error.localizedDescription)"
      testResult.textColor = NSColor.systemRed
      return
    }
    let result = host.call("routing", "test", [
      "url": .string(url),
      "source": .null,
      "modifiers": .array([]),
    ])
    if result.flag("matched", false) {
      let rule = result["rule"]
      let action = rule.str("action")
      let ruleId = rule.str("id")
      let hostsArr = rule.list("hosts")
      let hosts = hostsArr.compactMap(\.string).joined(separator: ", ")
      let patternMatch = rule.str("urlPattern")
      testResult.stringValue = "Matched! Rule #\(ruleId) (\(action), hosts: \(hosts.isEmpty ? "all" : hosts))"
      testResult.textColor = NSColor.systemGreen
    } else {
      testResult.stringValue = "No rule matched this URL."
      testResult.textColor = NSColor.secondaryLabelColor
    }
  }

  public override func layout() {
    super.layout()
    testPatternField.frame = NSRect(x: 0, y: bounds.height - 28, width: 160, height: 22)
    testUrlField.frame = NSRect(x: 164, y: bounds.height - 28, width: 200, height: 22)
    testButton.frame = NSRect(x: 368, y: bounds.height - 28, width: 50, height: 22)
    testResult.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 16)
  }
}