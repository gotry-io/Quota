import Foundation

private func isSafeDiagnosticText(_ value: String, maximum: Int) -> Bool {
  value.unicodeScalars.count <= maximum
    && value.unicodeScalars.allSatisfy { scalar in
      !((0 ... 31).contains(scalar.value) || (127 ... 159).contains(scalar.value))
    }
}

/// `provider:<id>`, `agent:<id>`, or one of the service's own fixed names. Nothing else may
/// name a source, which is what keeps paths, models, and identifiers out of the report.
private func isSafeSubject(_ value: String) -> Bool {
  isSafeDiagnosticText(value, maximum: 64)
    && !value.isEmpty
    && value.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_" || $0 == ":") }
    && !value.hasPrefix(":") && !value.hasSuffix(":")
}

enum LocalServiceDiagnosticOperation: String, Codable, Equatable, Sendable {
  case healthy
  case degraded
  case blocked
}

enum LocalServiceDiagnosticAttention: String, Codable, Equatable, Sendable {
  case none
  case automatic
  case required
}

enum LocalServiceDiagnosticStatus: String, Codable, Equatable, Sendable {
  case ok
  case degraded
  case blocked
  case inactive
}

enum LocalServiceDiagnosticDataState: String, Codable, Equatable, Sendable {
  case current
  case stale
  case partial
  case empty
}

enum LocalServiceDiagnosticRecovery: String, Codable, Equatable, Sendable {
  case none
  case automatic
  case retry
  case login
  case configureProvider = "configure_provider"
  case updateSource = "update_source"
  case checkAccess = "check_access"
  case upgrade
  case reinstall
}

enum LocalServiceDiagnosticAttemptKind: String, Codable, Equatable, Sendable {
  case refresh
  case quotaCollection = "quota_collection"
  case usageScan = "usage_scan"
  case usageUpload = "usage_upload"
  case accountSync = "account_sync"
  case pricingRefresh = "pricing_refresh"
}

enum LocalServiceDiagnosticAttemptOutcome: String, Codable, Equatable, Sendable {
  case running, success, partial
  case noWork = "no_work"
  case failed, interrupted, cancelled
}

struct LocalServiceDiagnosticClient: Decodable, Equatable, Sendable {
  let name: String
  let version: String

  init(name: String, version: String) { (self.name, self.version) = (name, version) }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["name", "version"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    version = try container.decode(String.self, forKey: .version)
    guard !name.isEmpty, isSafeDiagnosticText(name, maximum: 64), !version.isEmpty,
      isSafeDiagnosticText(version, maximum: 64)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .name, in: container, debugDescription: "Invalid diagnostic client.")
    }
  }

  private enum CodingKeys: String, CodingKey { case name, version }
}

struct LocalServiceDiagnosticSummary: Decodable, Equatable, Sendable {
  let operation: LocalServiceDiagnosticOperation
  let attention: LocalServiceDiagnosticAttention

  init(
    operation: LocalServiceDiagnosticOperation, attention: LocalServiceDiagnosticAttention
  ) {
    (self.operation, self.attention) = (operation, attention)
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["operation", "attention"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    operation = try container.decode(LocalServiceDiagnosticOperation.self, forKey: .operation)
    attention = try container.decode(LocalServiceDiagnosticAttention.self, forKey: .attention)
  }

  private enum CodingKeys: String, CodingKey { case operation, attention }
}

struct LocalServiceDiagnosticSurface: Decodable, Equatable, Sendable, Identifiable {
  let id: String
  let status: LocalServiceDiagnosticStatus
  let data: LocalServiceDiagnosticDataState
  let lastSuccessAt: Date?
  let message: String
  let recovery: LocalServiceDiagnosticRecovery

  init(
    id: String, status: LocalServiceDiagnosticStatus, data: LocalServiceDiagnosticDataState,
    lastSuccessAt: Date?, message: String, recovery: LocalServiceDiagnosticRecovery
  ) {
    (self.id, self.status, self.data) = (id, status, data)
    (self.lastSuccessAt, self.message, self.recovery) = (lastSuccessAt, message, recovery)
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["id", "status", "data", "lastSuccessAt", "message", "recovery"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    status = try container.decode(LocalServiceDiagnosticStatus.self, forKey: .status)
    data = try container.decode(LocalServiceDiagnosticDataState.self, forKey: .data)
    lastSuccessAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
    message = try container.decode(String.self, forKey: .message)
    recovery = try container.decode(LocalServiceDiagnosticRecovery.self, forKey: .recovery)
    guard isSafeSubject(id), !message.isEmpty, isSafeDiagnosticText(message, maximum: 512) else {
      throw DecodingError.dataCorruptedError(
        forKey: .id, in: container, debugDescription: "Invalid diagnostic surface.")
    }
  }

  private enum CodingKeys: String, CodingKey {
    case id, status, data, lastSuccessAt, message, recovery
  }
}

struct LocalServiceDiagnosticSource: Decodable, Equatable, Sendable {
  let subject: String
  let sourceID: String?
  let status: LocalServiceDiagnosticStatus
  let lastAttemptAt: Date?
  let lastSuccessAt: Date?
  let code: String?
  let message: String
  let recovery: LocalServiceDiagnosticRecovery

  init(
    subject: String, sourceID: String? = nil, status: LocalServiceDiagnosticStatus,
    lastAttemptAt: Date? = nil, lastSuccessAt: Date? = nil, code: String? = nil,
    message: String, recovery: LocalServiceDiagnosticRecovery
  ) {
    (self.subject, self.sourceID, self.status) = (subject, sourceID, status)
    (self.lastAttemptAt, self.lastSuccessAt, self.code) = (lastAttemptAt, lastSuccessAt, code)
    (self.message, self.recovery) = (message, recovery)
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "subject", "sourceId", "status", "lastAttemptAt", "lastSuccessAt", "code", "message",
      "recovery",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    subject = try container.decode(String.self, forKey: .subject)
    sourceID = try container.decodeIfPresent(String.self, forKey: .sourceID)
    status = try container.decode(LocalServiceDiagnosticStatus.self, forKey: .status)
    lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
    lastSuccessAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
    code = try container.decodeIfPresent(String.self, forKey: .code)
    message = try container.decode(String.self, forKey: .message)
    recovery = try container.decode(LocalServiceDiagnosticRecovery.self, forKey: .recovery)
    guard isSafeSubject(subject), sourceID.map({ isSafeSubject($0) }) ?? true,
      code.map({ isSafeSubject($0) }) ?? true, !message.isEmpty,
      isSafeDiagnosticText(message, maximum: 512)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .subject, in: container, debugDescription: "Invalid diagnostic source.")
    }
  }

  private enum CodingKeys: String, CodingKey {
    case subject
    case sourceID = "sourceId"
    case status, lastAttemptAt, lastSuccessAt, code, message, recovery
  }
}

struct LocalServiceDiagnosticAttempt: Decodable, Equatable, Sendable {
  let kind: LocalServiceDiagnosticAttemptKind
  let subject: String?
  let startedAt: Date
  let durationMs: UInt64?
  let outcome: LocalServiceDiagnosticAttemptOutcome
  let code: String?

  init(
    kind: LocalServiceDiagnosticAttemptKind, subject: String?, startedAt: Date,
    durationMs: UInt64?, outcome: LocalServiceDiagnosticAttemptOutcome, code: String?
  ) {
    (self.kind, self.subject, self.startedAt) = (kind, subject, startedAt)
    (self.durationMs, self.outcome, self.code) = (durationMs, outcome, code)
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "kind", "subject", "startedAt", "durationMs", "outcome", "code",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kind = try container.decode(LocalServiceDiagnosticAttemptKind.self, forKey: .kind)
    subject = try container.decode(String?.self, forKey: .subject)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    durationMs = try container.decode(UInt64?.self, forKey: .durationMs)
    outcome = try container.decode(LocalServiceDiagnosticAttemptOutcome.self, forKey: .outcome)
    code = try container.decode(String?.self, forKey: .code)
    guard subject.map(isSafeSubject) ?? true, code.map(isSafeSubject) ?? true,
      durationMs.map({ $0 <= 86_400_000 }) ?? true,
      (outcome == .running) == (durationMs == nil)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .outcome, in: container, debugDescription: "Invalid diagnostic attempt.")
    }
  }

  private enum CodingKeys: String, CodingKey {
    case kind, subject, startedAt, durationMs, outcome, code
  }
}

struct LocalServiceDiagnosticReport: Decodable, Equatable, Sendable {
  let schemaVersion: Int
  let generatedAt: Date
  let client: LocalServiceDiagnosticClient
  let summary: LocalServiceDiagnosticSummary
  let surfaces: [LocalServiceDiagnosticSurface]
  let sources: [LocalServiceDiagnosticSource]
  let recent: [LocalServiceDiagnosticAttempt]

  init(
    schemaVersion: Int = 3, generatedAt: Date, client: LocalServiceDiagnosticClient,
    summary: LocalServiceDiagnosticSummary, surfaces: [LocalServiceDiagnosticSurface],
    sources: [LocalServiceDiagnosticSource] = [],
    recent: [LocalServiceDiagnosticAttempt] = []
  ) {
    self.schemaVersion = schemaVersion
    self.generatedAt = generatedAt
    self.client = client
    self.summary = summary
    self.surfaces = surfaces
    self.sources = sources
    self.recent = recent
  }

  var isValid: Bool {
    schemaVersion == 3 && sources.count <= 64 && recent.count <= 100
      && surfaces.map(\.id)
        == ["quota_overview", "usage_this_device", "usage_account", "account"]
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "schemaVersion", "generatedAt", "client", "summary", "surfaces", "sources", "recent",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    generatedAt = try container.decode(Date.self, forKey: .generatedAt)
    client = try container.decode(LocalServiceDiagnosticClient.self, forKey: .client)
    summary = try container.decode(LocalServiceDiagnosticSummary.self, forKey: .summary)
    surfaces = try container.decode([LocalServiceDiagnosticSurface].self, forKey: .surfaces)
    sources = try container.decode([LocalServiceDiagnosticSource].self, forKey: .sources)
    recent = try container.decode([LocalServiceDiagnosticAttempt].self, forKey: .recent)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .surfaces, in: container, debugDescription: "Invalid diagnostic report.")
    }
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, generatedAt, client, summary, surfaces, sources, recent
  }
}

extension LocalServiceDiagnosticReport {
  /// The whole report as plain text, including the recent work the page does not show. This is
  /// what Copy report puts on the pasteboard, so anything the service redacted stays redacted.
  var textReport: String {
    var lines = [
      "Quota support report",
      "Client: \(client.name) \(client.version)",
      "Generated at: \(Self.isoString(generatedAt))",
      "Status: \(summary.operation.rawValue) · attention \(summary.attention.rawValue)",
      "",
      "Surfaces:",
    ]
    lines += surfaces.map { surface in
      let lastSuccess = surface.lastSuccessAt.map { " · last worked \(Self.isoString($0))" } ?? ""
      return "  \(surface.id)\t\(surface.status.rawValue)\tdata=\(surface.data.rawValue)"
        + "\(lastSuccess)\t\(surface.message)"
    }
    lines.append("")
    lines.append("Sources:")
    if sources.isEmpty {
      lines.append("  none")
    } else {
      lines += sources.map { source in
        let sourceID = source.sourceID.map { "/\($0)" } ?? ""
        let code = source.code.map { "\tcode=\($0)" } ?? ""
        let attempt = source.lastAttemptAt.map { "\tlast_attempt=\(Self.isoString($0))" } ?? ""
        let success = source.lastSuccessAt.map { "\tlast_success=\(Self.isoString($0))" } ?? ""
        return "  \(source.subject)\(sourceID)\t\(source.status.rawValue)\(code)\(attempt)"
          + "\(success)\trecovery=\(source.recovery.rawValue)\t\(source.message)"
      }
    }
    lines.append("")
    lines.append("Recent:")
    if recent.isEmpty {
      lines.append("  none")
    } else {
      lines += recent.map { attempt in
        let subject = attempt.subject.map { "/\($0)" } ?? ""
        let duration = attempt.durationMs.map { "\t\($0)ms" } ?? ""
        let code = attempt.code.map { "\tcode=\($0)" } ?? ""
        return "  \(Self.isoString(attempt.startedAt))\t\(attempt.kind.rawValue)\(subject)"
          + "\t\(attempt.outcome.rawValue)\(duration)\(code)"
      }
    }
    return lines.joined(separator: "\n")
  }

  private static func isoString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }
}
