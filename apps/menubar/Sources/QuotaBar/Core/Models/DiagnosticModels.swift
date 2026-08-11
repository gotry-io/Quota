import Foundation

private func isSafeDiagnosticText(_ value: String, maximum: Int) -> Bool {
  value.unicodeScalars.count <= maximum
    && value.unicodeScalars.allSatisfy { scalar in
      !((0 ... 31).contains(scalar.value) || (127 ... 159).contains(scalar.value))
    }
}

enum LocalServiceDiagnosticStatus: String, Decodable, Sendable {
  case healthy
  case degraded
  case blocked
}

enum LocalServiceDiagnosticSeverity: String, Decodable, Sendable {
  case info
  case warning
  case error
}

enum LocalServiceDiagnosticComponentStatus: String, Decodable, Sendable {
  case ready
  case degraded
  case blocked
}

struct LocalServiceDiagnosticClient: Decodable, Sendable {
  let name: String
  let version: String

  private enum CodingKeys: String, CodingKey {
    case name
    case version
  }
}

extension LocalServiceDiagnosticClient {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["name", "version"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    version = try container.decode(String.self, forKey: .version)
    guard !name.isEmpty, isSafeDiagnosticText(name, maximum: 64), !version.isEmpty,
          isSafeDiagnosticText(version, maximum: 64)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .name,
        in: container,
        debugDescription: "Diagnostic client labels are out of bounds."
      )
    }
  }
}

struct LocalServiceDiagnosticComponent: Decodable, Sendable {
  let name: String
  let status: LocalServiceDiagnosticComponentStatus
  let message: String?
  let metrics: [String: Int]

  private enum CodingKeys: String, CodingKey {
    case name
    case status
    case message
    case metrics
  }
}

extension LocalServiceDiagnosticComponent {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["name", "status", "message", "metrics"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    status = try container.decode(LocalServiceDiagnosticComponentStatus.self, forKey: .status)
    message = try container.decodeIfPresent(String.self, forKey: .message)
    metrics = try container.decodeIfPresent([String: Int].self, forKey: .metrics) ?? [:]
    guard !name.isEmpty, isSafeDiagnosticText(name, maximum: 32), metrics.count <= 64,
          metrics.keys.allSatisfy({ !$0.isEmpty && isSafeDiagnosticText($0, maximum: 64) }),
          metrics.values.allSatisfy({ (0 ... 1_000_000).contains($0) }),
          message.map({ isSafeDiagnosticText($0, maximum: 512) }) ?? true
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .name,
        in: container,
        debugDescription: "Diagnostic component is out of bounds."
      )
    }
  }
}

struct LocalServiceDiagnosticIssue: Decodable, Sendable {
  let component: String
  let code: String
  let severity: LocalServiceDiagnosticSeverity
  let count: Int
  let message: String

  private enum CodingKeys: String, CodingKey {
    case component
    case code
    case severity
    case count
    case message
  }
}

extension LocalServiceDiagnosticIssue {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["component", "code", "severity", "count", "message"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    component = try container.decode(String.self, forKey: .component)
    code = try container.decode(String.self, forKey: .code)
    severity = try container.decode(LocalServiceDiagnosticSeverity.self, forKey: .severity)
    count = try container.decode(Int.self, forKey: .count)
    message = try container.decode(String.self, forKey: .message)
    guard !component.isEmpty, isSafeDiagnosticText(component, maximum: 32), !code.isEmpty,
          isSafeDiagnosticText(code, maximum: 64), (1 ... 1_000_000).contains(count),
          !message.isEmpty, isSafeDiagnosticText(message, maximum: 512)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .component,
        in: container,
        debugDescription: "Diagnostic issue is out of bounds."
      )
    }
  }
}

struct LocalServiceDiagnosticReport: Decodable, Sendable {
  let schemaVersion: Int
  let status: LocalServiceDiagnosticStatus
  let generatedAt: Date
  let client: LocalServiceDiagnosticClient
  let components: [LocalServiceDiagnosticComponent]
  let issues: [LocalServiceDiagnosticIssue]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case status
    case generatedAt
    case client
    case components
    case issues
  }

  var isValid: Bool {
    guard schemaVersion == 1, components.count == 6, issues.count <= 256 else { return false }
    let names = Set(components.map(\.name))
    let allowedNames = Set(["providers", "quota", "usage", "pricing", "account", "sync"])
    return names == allowedNames && issues.allSatisfy { allowedNames.contains($0.component) }
  }
}

extension LocalServiceDiagnosticReport {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "schemaVersion", "status", "generatedAt", "client", "components", "issues",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    status = try container.decode(LocalServiceDiagnosticStatus.self, forKey: .status)
    generatedAt = try container.decode(Date.self, forKey: .generatedAt)
    client = try container.decode(LocalServiceDiagnosticClient.self, forKey: .client)
    components = try container.decode([LocalServiceDiagnosticComponent].self, forKey: .components)
    issues = try container.decode([LocalServiceDiagnosticIssue].self, forKey: .issues)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .components,
        in: container,
        debugDescription: "Diagnostic report is invalid or incomplete."
      )
    }
  }
}

extension LocalServiceDiagnosticReport {
  var textReport: String {
    var lines = [
      "Diagnostics: \(status.rawValue)",
      "Client: \(client.name) \(client.version)",
      "Generated at: \(Self.isoString(generatedAt))",
      "Components:",
    ]
    lines += components.map { component in
      var line = "  \(component.name)\t\(component.status.rawValue)"
      if let message = component.message {
        line += "\t\(message)"
      }
      if !component.metrics.isEmpty {
        line += "\t\(Self.metricsString(component.metrics))"
      }
      return line
    }
    if issues.isEmpty {
      lines.append("Issues: none")
    } else {
      lines.append("Issues:")
      lines += issues.map {
        "  [\($0.severity.rawValue)] \($0.component)/\($0.code) (\($0.count))\t\($0.message)"
      }
    }
    return lines.joined(separator: "\n")
  }

  var jsonReport: String {
    let object: [String: Any] = [
      "schema_version": schemaVersion,
      "status": status.rawValue,
      "generated_at": Self.isoString(generatedAt),
      "client": ["name": client.name, "version": client.version],
      "components": components.map { component in
        [
          "name": component.name,
          "status": component.status.rawValue,
          "message": component.message.map { $0 as Any } ?? (NSNull() as Any),
          "metrics": component.metrics,
        ]
      },
      "issues": issues.map { issue in
        [
          "component": issue.component,
          "code": issue.code,
          "severity": issue.severity.rawValue,
          "count": issue.count,
          "message": issue.message,
        ]
      },
    ]
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let result = String(data: data, encoding: .utf8)
    else { return "{\"error\":\"serialization_failed\"}" }
    return result
  }

  private static func isoString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private static func metricsString(_ metrics: [String: Int]) -> String {
    metrics.keys.sorted().compactMap { key in
      guard let value = metrics[key] else { return nil }
      return "\(key)=\(value)"
    }.joined(separator: ",")
  }
}
