import Foundation

private func isSafeDiagnosticText(_ value: String, maximum: Int) -> Bool {
  value.unicodeScalars.count <= maximum
    && value.unicodeScalars.allSatisfy { scalar in
      !((0 ... 31).contains(scalar.value) || (127 ... 159).contains(scalar.value))
    }
}

enum LocalServiceDiagnosticOperation: String, Codable, Equatable, Sendable {
  case healthy
  case degraded
  case blocked
}

enum LocalServiceDiagnosticDataState: String, Codable, Equatable, Sendable {
  case current
  case stale
  case partial
  case empty
  case unknown
}

enum LocalServiceDiagnosticAttention: String, Codable, Equatable, Sendable {
  case none
  case automatic
  case optional
  case required
}

enum LocalServiceDiagnosticSeverity: String, Codable, Equatable, Sendable {
  case info
  case warning
  case error
}

enum LocalServiceDiagnosticSource: String, Codable, Equatable, Sendable {
  case thisDevice = "this_device"
  case account
  case system
}

enum LocalServiceDiagnosticMode: String, Codable, Equatable, Sendable {
  case inactive
  case opportunistic
  case required
}

enum LocalServiceDiagnosticImpact: String, Codable, Equatable, Sendable {
  case none
  case source
  case surface
  case system
}

enum LocalServiceDiagnosticRecovery: String, Codable, Equatable, Sendable {
  case none
  case automatic
  case login
  case configureProvider = "configure_provider"
  case retry
  case updateSource = "update_source"
  case checkAccess = "check_access"
  case upgrade
  case reinstall
  case feedback
}

enum LocalServiceDiagnosticRefreshPhase: String, Codable, Equatable, Sendable {
  case idle
  case running
}

enum LocalServiceDiagnosticAttemptKind: String, Codable, Equatable, Sendable {
  case refresh
  case quotaCollection = "quota_collection"
  case usageScan = "usage_scan"
  case usageUpload = "usage_upload"
  case accountSync = "account_sync"
  case pricingRefresh = "pricing_refresh"
  case deviceHealthUpload = "device_health_upload"
}

enum LocalServiceDiagnosticAttemptTrigger: String, Codable, Equatable, Sendable {
  case manual, scheduled, startup, recheck
  case settingsChange = "settings_change"
  case accountChange = "account_change"
}

enum LocalServiceDiagnosticAttemptOutcome: String, Codable, Equatable, Sendable {
  case running, success, partial
  case noWork = "no_work"
  case failed, interrupted, cancelled
}

enum LocalServiceDiagnosticAttemptCode: String, Codable, Equatable, Sendable {
  case processInterrupted = "process_interrupted"
  case cancelled
  case noWork = "no_work"
  case authenticationRequired = "authentication_required"
  case networkError = "network_error"
  case unavailable
  case invalidResponse = "invalid_response"
  case invalidState = "invalid_state"
  case providerError = "provider_error"
  case partialSource = "partial_source"
  case malformedData = "malformed_data"
  case truncatedActiveSource = "truncated_active_source"
  case invalidUsageBatch = "invalid_usage_batch"
  case unrepresentableHour = "unrepresentable_hour"
  case deviceDeleted = "device_deleted"
  case uploadDisabled = "upload_disabled"
  case signedOut = "signed_out"
}

struct LocalServiceDiagnosticAttempt: Decodable, Equatable, Sendable {
  let kind: LocalServiceDiagnosticAttemptKind
  let trigger: LocalServiceDiagnosticAttemptTrigger
  let source: LocalServiceDiagnosticSource
  let subject: String?
  let mode: LocalServiceDiagnosticMode
  let startedAt: Date
  let completedAt: Date?
  let durationMs: UInt64?
  let outcome: LocalServiceDiagnosticAttemptOutcome
  let code: LocalServiceDiagnosticAttemptCode?
  let recovery: LocalServiceDiagnosticRecovery
  let metrics: [String: Int]
  let startRevision: UInt64
  let endRevision: UInt64?
  let parentRefreshStartedAt: Date?

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "kind", "trigger", "source", "subject", "mode", "startedAt", "completedAt", "durationMs",
      "outcome", "code", "recovery", "metrics", "startRevision", "endRevision",
      "parentRefreshStartedAt",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kind = try container.decode(LocalServiceDiagnosticAttemptKind.self, forKey: .kind)
    trigger = try container.decode(LocalServiceDiagnosticAttemptTrigger.self, forKey: .trigger)
    source = try container.decode(LocalServiceDiagnosticSource.self, forKey: .source)
    subject = try container.decode(String?.self, forKey: .subject)
    mode = try container.decode(LocalServiceDiagnosticMode.self, forKey: .mode)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    completedAt = try container.decode(Date?.self, forKey: .completedAt)
    durationMs = try container.decode(UInt64?.self, forKey: .durationMs)
    outcome = try container.decode(LocalServiceDiagnosticAttemptOutcome.self, forKey: .outcome)
    code = try container.decode(LocalServiceDiagnosticAttemptCode?.self, forKey: .code)
    recovery = try container.decode(LocalServiceDiagnosticRecovery.self, forKey: .recovery)
    metrics = try container.decode([String: Int].self, forKey: .metrics)
    startRevision = try container.decode(UInt64.self, forKey: .startRevision)
    endRevision = try container.decode(UInt64?.self, forKey: .endRevision)
    parentRefreshStartedAt = try container.decode(Date?.self, forKey: .parentRefreshStartedAt)
    let running = outcome == .running
    guard subject.map(isSafeSubject) ?? true,
      metrics.count <= 16,
      metrics.keys.allSatisfy({ !$0.isEmpty && isSafeDiagnosticText($0, maximum: 32) }),
      metrics.values.allSatisfy({ (0 ... 9_007_199_254_740_991).contains($0) }),
      durationMs.map({ $0 <= 86_400_000 }) ?? true,
      running == (completedAt == nil && durationMs == nil && endRevision == nil),
      completedAt.map({ $0 >= startedAt }) ?? true
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .outcome, in: container, debugDescription: "Invalid diagnostic attempt.")
    }
  }

  private enum CodingKeys: String, CodingKey {
    case kind, trigger, source, subject, mode, startedAt, completedAt, durationMs, outcome, code
    case recovery, metrics, startRevision, endRevision, parentRefreshStartedAt
  }
}

struct LocalServiceDiagnosticRecentActivity: Decodable, Equatable, Sendable {
  let attempts: [LocalServiceDiagnosticAttempt]
  let historyTruncated: Bool

  static let empty = Self(attempts: [], historyTruncated: false)

  init(attempts: [LocalServiceDiagnosticAttempt], historyTruncated: Bool) {
    self.attempts = attempts
    self.historyTruncated = historyTruncated
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["attempts", "historyTruncated"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    attempts = try container.decode([LocalServiceDiagnosticAttempt].self, forKey: .attempts)
    historyTruncated = try container.decode(Bool.self, forKey: .historyTruncated)
    guard attempts.count <= 512 else {
      throw DecodingError.dataCorruptedError(
        forKey: .attempts, in: container, debugDescription: "Too many diagnostic attempts.")
    }
  }

  private enum CodingKeys: String, CodingKey { case attempts, historyTruncated }
}

struct LocalServiceDiagnosticSummary: Codable, Equatable, Sendable {
  let operation: LocalServiceDiagnosticOperation
  let data: LocalServiceDiagnosticDataState
  let attention: LocalServiceDiagnosticAttention

  init(operation: LocalServiceDiagnosticOperation, data: LocalServiceDiagnosticDataState, attention: LocalServiceDiagnosticAttention) {
    (self.operation, self.data, self.attention) = (operation, data, attention)
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["operation", "data", "attention"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    operation = try container.decode(LocalServiceDiagnosticOperation.self, forKey: .operation)
    data = try container.decode(LocalServiceDiagnosticDataState.self, forKey: .data)
    attention = try container.decode(LocalServiceDiagnosticAttention.self, forKey: .attention)
  }

  private enum CodingKeys: String, CodingKey { case operation, data, attention }
}

struct LocalServiceDiagnosticRefresh: Decodable, Equatable, Sendable {
  let phase: LocalServiceDiagnosticRefreshPhase
  let revision: UInt64
  let asOf: Date
  let startedAt: Date?
  let nextDueAt: Date?

  init(phase: LocalServiceDiagnosticRefreshPhase, revision: UInt64 = 0, asOf: Date, startedAt: Date?, nextDueAt: Date?) {
    (self.phase, self.revision, self.asOf, self.startedAt, self.nextDueAt) = (phase, revision, asOf, startedAt, nextDueAt)
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["phase", "revision", "asOf", "startedAt", "nextDueAt"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    phase = try container.decode(LocalServiceDiagnosticRefreshPhase.self, forKey: .phase)
    revision = try container.decode(UInt64.self, forKey: .revision)
    asOf = try container.decode(Date.self, forKey: .asOf)
    startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
    nextDueAt = try container.decodeIfPresent(Date.self, forKey: .nextDueAt)
  }

  private enum CodingKeys: String, CodingKey { case phase, revision, asOf, startedAt, nextDueAt }
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
    else { throw DecodingError.dataCorruptedError(forKey: .name, in: container, debugDescription: "Invalid diagnostic client.") }
  }

  private enum CodingKeys: String, CodingKey { case name, version }
}

struct LocalServiceDiagnosticSurface: Decodable, Equatable, Sendable {
  let name: String
  let operation: LocalServiceDiagnosticOperation
  let data: LocalServiceDiagnosticDataState
  let source: LocalServiceDiagnosticSource?
  let metrics: [String: Int]

  init(name: String, operation: LocalServiceDiagnosticOperation, data: LocalServiceDiagnosticDataState, source: LocalServiceDiagnosticSource?, metrics: [String: Int]) {
    (self.name, self.operation, self.data, self.source, self.metrics) = (name, operation, data, source, metrics)
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["name", "operation", "data", "source", "metrics"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    operation = try container.decode(LocalServiceDiagnosticOperation.self, forKey: .operation)
    data = try container.decode(LocalServiceDiagnosticDataState.self, forKey: .data)
    source = try container.decodeIfPresent(LocalServiceDiagnosticSource.self, forKey: .source)
    metrics = try container.decode([String: Int].self, forKey: .metrics)
    guard !name.isEmpty, isSafeDiagnosticText(name, maximum: 32), metrics.count <= 64,
          metrics.keys.allSatisfy({ !$0.isEmpty && isSafeDiagnosticText($0, maximum: 64) }),
          metrics.values.allSatisfy({ (0 ... 1_000_000).contains($0) })
    else { throw DecodingError.dataCorruptedError(forKey: .name, in: container, debugDescription: "Invalid diagnostic surface.") }
  }

  private enum CodingKeys: String, CodingKey { case name, operation, data, source, metrics }
}

struct LocalServiceDiagnosticCheck: Decodable, Equatable, Sendable {
  let name: String
  let source: LocalServiceDiagnosticSource
  let subject: String?
  let mode: LocalServiceDiagnosticMode
  let operation: LocalServiceDiagnosticOperation
  let data: LocalServiceDiagnosticDataState
  let lastAttemptAt: Date?
  let lastSuccessAt: Date?
  let metrics: [String: Int]

  init(name: String, source: LocalServiceDiagnosticSource, subject: String?, mode: LocalServiceDiagnosticMode, operation: LocalServiceDiagnosticOperation, data: LocalServiceDiagnosticDataState, lastAttemptAt: Date?, lastSuccessAt: Date?, metrics: [String: Int]) {
    (self.name, self.source, self.subject, self.mode, self.operation, self.data, self.lastAttemptAt, self.lastSuccessAt, self.metrics) = (name, source, subject, mode, operation, data, lastAttemptAt, lastSuccessAt, metrics)
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "name", "source", "subject", "mode", "operation", "data", "lastAttemptAt",
      "lastSuccessAt", "metrics",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    source = try container.decode(LocalServiceDiagnosticSource.self, forKey: .source)
    subject = try container.decodeIfPresent(String.self, forKey: .subject)
    mode = try container.decode(LocalServiceDiagnosticMode.self, forKey: .mode)
    operation = try container.decode(LocalServiceDiagnosticOperation.self, forKey: .operation)
    data = try container.decode(LocalServiceDiagnosticDataState.self, forKey: .data)
    lastAttemptAt = try container.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
    lastSuccessAt = try container.decodeIfPresent(Date.self, forKey: .lastSuccessAt)
    metrics = try container.decode([String: Int].self, forKey: .metrics)
    guard !name.isEmpty, isSafeDiagnosticText(name, maximum: 32), metrics.count <= 64,
          subject.map({ isSafeSubject($0) }) ?? true,
          metrics.keys.allSatisfy({ !$0.isEmpty && isSafeDiagnosticText($0, maximum: 64) }),
          metrics.values.allSatisfy({ (0 ... 1_000_000).contains($0) })
    else { throw DecodingError.dataCorruptedError(forKey: .name, in: container, debugDescription: "Invalid diagnostic check.") }
  }

  private enum CodingKeys: String, CodingKey {
    case name, source, subject, mode, operation, data, lastAttemptAt, lastSuccessAt, metrics
  }
}

struct LocalServiceDiagnosticFinding: Decodable, Equatable, Sendable {
  let component: String
  let source: LocalServiceDiagnosticSource
  let subject: String?
  let code: String
  let severity: LocalServiceDiagnosticSeverity
  let impact: LocalServiceDiagnosticImpact
  let recovery: LocalServiceDiagnosticRecovery
  let count: Int
  let observedAt: Date
  let message: String

  init(component: String, source: LocalServiceDiagnosticSource, subject: String?, code: String, severity: LocalServiceDiagnosticSeverity, impact: LocalServiceDiagnosticImpact, recovery: LocalServiceDiagnosticRecovery, count: Int, observedAt: Date, message: String) {
    (self.component, self.source, self.subject, self.code, self.severity, self.impact, self.recovery, self.count, self.observedAt, self.message) = (component, source, subject, code, severity, impact, recovery, count, observedAt, message)
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "component", "source", "subject", "code", "severity", "impact", "recovery", "count",
      "observedAt", "message",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    component = try container.decode(String.self, forKey: .component)
    source = try container.decode(LocalServiceDiagnosticSource.self, forKey: .source)
    subject = try container.decodeIfPresent(String.self, forKey: .subject)
    code = try container.decode(String.self, forKey: .code)
    severity = try container.decode(LocalServiceDiagnosticSeverity.self, forKey: .severity)
    impact = try container.decode(LocalServiceDiagnosticImpact.self, forKey: .impact)
    recovery = try container.decode(LocalServiceDiagnosticRecovery.self, forKey: .recovery)
    count = try container.decode(Int.self, forKey: .count)
    observedAt = try container.decode(Date.self, forKey: .observedAt)
    message = try container.decode(String.self, forKey: .message)
    guard !component.isEmpty, isSafeDiagnosticText(component, maximum: 32), !code.isEmpty,
          isSafeDiagnosticText(code, maximum: 64), subject.map({ isSafeSubject($0) }) ?? true,
          (1 ... 1_000_000).contains(count), !message.isEmpty,
          isSafeDiagnosticText(message, maximum: 512)
    else { throw DecodingError.dataCorruptedError(forKey: .component, in: container, debugDescription: "Invalid diagnostic finding.") }
  }

  private enum CodingKeys: String, CodingKey {
    case component, source, subject, code, severity, impact, recovery, count, observedAt, message
  }
}

private func isSafeSubject(_ value: String) -> Bool {
  let identity = value.drop(while: { $0 != ":" }).dropFirst()
  return isSafeDiagnosticText(value, maximum: 80)
    && (value.hasPrefix("provider:") || value.hasPrefix("agent:"))
    && !identity.isEmpty
    && identity.allSatisfy {
      $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "_")
    }
}

struct LocalServiceDiagnosticReport: Decodable, Equatable, Sendable {
  let schemaVersion: Int
  let summary: LocalServiceDiagnosticSummary
  let refresh: LocalServiceDiagnosticRefresh
  let generatedAt: Date
  let client: LocalServiceDiagnosticClient
  let surfaces: [LocalServiceDiagnosticSurface]
  let checks: [LocalServiceDiagnosticCheck]
  let findings: [LocalServiceDiagnosticFinding]
  let recentActivity: LocalServiceDiagnosticRecentActivity

  init(schemaVersion: Int, summary: LocalServiceDiagnosticSummary, refresh: LocalServiceDiagnosticRefresh, generatedAt: Date, client: LocalServiceDiagnosticClient, surfaces: [LocalServiceDiagnosticSurface], checks: [LocalServiceDiagnosticCheck], findings: [LocalServiceDiagnosticFinding], recentActivity: LocalServiceDiagnosticRecentActivity = .empty) {
    (self.schemaVersion, self.summary, self.refresh, self.generatedAt, self.client, self.surfaces, self.checks, self.findings, self.recentActivity) = (schemaVersion, summary, refresh, generatedAt, client, surfaces, checks, findings, recentActivity)
  }

  var isValid: Bool {
    guard schemaVersion == 2, surfaces.count == 4, checks.count <= 128, findings.count <= 256 else {
      return false
    }
    return Set(surfaces.map(\.name))
      == Set(["quota_overview", "usage_this_device", "usage_account", "account"])
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "schemaVersion", "summary", "refresh", "generatedAt", "client", "surfaces", "checks",
      "findings",
      "recentActivity",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    summary = try container.decode(LocalServiceDiagnosticSummary.self, forKey: .summary)
    refresh = try container.decode(LocalServiceDiagnosticRefresh.self, forKey: .refresh)
    generatedAt = try container.decode(Date.self, forKey: .generatedAt)
    client = try container.decode(LocalServiceDiagnosticClient.self, forKey: .client)
    surfaces = try container.decode([LocalServiceDiagnosticSurface].self, forKey: .surfaces)
    checks = try container.decode([LocalServiceDiagnosticCheck].self, forKey: .checks)
    findings = try container.decode([LocalServiceDiagnosticFinding].self, forKey: .findings)
    recentActivity = try container.decode(LocalServiceDiagnosticRecentActivity.self, forKey: .recentActivity)
    guard isValid else { throw DecodingError.dataCorruptedError(forKey: .surfaces, in: container, debugDescription: "Invalid diagnostic report.") }
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, summary, refresh, generatedAt, client, surfaces, checks, findings, recentActivity
  }
}

extension LocalServiceDiagnosticReport {
  var textReport: String {
    var lines = [
      "Diagnostics: \(summary.operation.rawValue)",
      "Data: \(summary.data.rawValue)",
      "Attention: \(summary.attention.rawValue)",
      "Client: \(client.name) \(client.version)",
      "Generated at: \(Self.isoString(generatedAt))",
      "Refresh: \(refresh.phase.rawValue) · as of \(Self.isoString(refresh.asOf))",
      "Surfaces:",
    ]
    lines += surfaces.map {
      let source = $0.source.map { "\tsource=\($0.rawValue)" } ?? ""
      return "  \($0.name)\t\($0.operation.rawValue)\tdata=\($0.data.rawValue)\(source)\(Self.metricsSuffix($0.metrics))"
    }
    lines.append("Checks:")
    lines += checks.map {
      let subject = $0.subject.map { "/\($0)" } ?? ""
      return "  \($0.name)\(subject)\t\($0.source.rawValue)\t\($0.mode.rawValue)\t\($0.operation.rawValue)\tdata=\($0.data.rawValue)\(Self.metricsSuffix($0.metrics))"
    }
    if findings.isEmpty {
      lines.append("Findings: none")
    } else {
      lines.append("Findings:")
      lines += findings.map {
        let subject = $0.subject.map { "/\($0)" } ?? ""
        return "  [\($0.severity.rawValue)] \($0.component)\(subject)/\($0.code) (\($0.count))\t\($0.message)\tsource=\($0.source.rawValue)\timpact=\($0.impact.rawValue)\tobserved_at=\(Self.isoString($0.observedAt))\trecovery=\($0.recovery.rawValue)"
      }
    }
    lines.append("Recent activity:")
    if recentActivity.attempts.isEmpty {
      lines.append("  none")
    } else {
      lines += recentActivity.attempts.map {
        let subject = $0.subject.map { "/\($0)" } ?? ""
        let code = $0.code.map { "\tcode=\($0.rawValue)" } ?? ""
        let completed = $0.completedAt.map { "\tcompleted_at=\(Self.isoString($0))" } ?? ""
        return "  \($0.kind.rawValue)\(subject)\t\($0.trigger.rawValue)\t\($0.outcome.rawValue)\tstarted_at=\(Self.isoString($0.startedAt))\(completed)\(code)\(Self.metricsSuffix($0.metrics))"
      }
    }
    if recentActivity.historyTruncated {
      lines.append("  history_truncated=true")
    }
    return lines.joined(separator: "\n")
  }

  var jsonReport: String {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(CopyReport(report: self)),
          let result = String(data: data, encoding: .utf8)
    else { return "{\"error\":\"serialization_failed\"}" }
    return result
  }

  private struct CopyReport: Encodable {
    let schemaVersion: Int
    let summary: CopySummary
    let refresh: CopyRefresh
    let generatedAt: Date
    let client: CopyClient
    let surfaces: [CopySurface]
    let checks: [CopyCheck]
    let findings: [CopyFinding]
    let recentActivity: CopyRecentActivity

    init(report: LocalServiceDiagnosticReport) {
      schemaVersion = report.schemaVersion
      summary = .init(report.summary)
      refresh = .init(report.refresh)
      generatedAt = report.generatedAt
      client = .init(report.client)
      surfaces = report.surfaces.map(CopySurface.init)
      checks = report.checks.map(CopyCheck.init)
      findings = report.findings.map(CopyFinding.init)
      recentActivity = .init(report.recentActivity)
    }
  }

  private struct CopySummary: Encodable {
    let operation: LocalServiceDiagnosticOperation
    let data: LocalServiceDiagnosticDataState
    let attention: LocalServiceDiagnosticAttention
    init(_ value: LocalServiceDiagnosticSummary) { (operation, data, attention) = (value.operation, value.data, value.attention) }
  }
  private struct CopyRefresh: Encodable {
    let phase: LocalServiceDiagnosticRefreshPhase
    let revision: UInt64
    let asOf: Date
    let startedAt: Date?
    let nextDueAt: Date?
    init(_ value: LocalServiceDiagnosticRefresh) { (phase, revision, asOf, startedAt, nextDueAt) = (value.phase, value.revision, value.asOf, value.startedAt, value.nextDueAt) }
  }
  private struct CopyClient: Encodable {
    let name: String; let version: String
    init(_ value: LocalServiceDiagnosticClient) { (name, version) = (value.name, value.version) }
  }
  private struct CopySurface: Encodable {
    let name: String; let operation: LocalServiceDiagnosticOperation; let data: LocalServiceDiagnosticDataState
    let source: LocalServiceDiagnosticSource?; let metrics: [String: Int]
    init(_ value: LocalServiceDiagnosticSurface) { (name, operation, data, source, metrics) = (value.name, value.operation, value.data, value.source, value.metrics) }
  }
  private struct CopyCheck: Encodable {
    let name: String; let source: LocalServiceDiagnosticSource; let subject: String?
    let mode: LocalServiceDiagnosticMode; let operation: LocalServiceDiagnosticOperation
    let data: LocalServiceDiagnosticDataState; let lastAttemptAt: Date?; let lastSuccessAt: Date?
    let metrics: [String: Int]
    init(_ value: LocalServiceDiagnosticCheck) { (name, source, subject, mode, operation, data, lastAttemptAt, lastSuccessAt, metrics) = (value.name, value.source, value.subject, value.mode, value.operation, value.data, value.lastAttemptAt, value.lastSuccessAt, value.metrics) }
  }
  private struct CopyFinding: Encodable {
    let component: String; let source: LocalServiceDiagnosticSource; let subject: String?; let code: String
    let severity: LocalServiceDiagnosticSeverity; let impact: LocalServiceDiagnosticImpact
    let recovery: LocalServiceDiagnosticRecovery; let count: Int; let observedAt: Date; let message: String
    init(_ value: LocalServiceDiagnosticFinding) { (component, source, subject, code, severity, impact, recovery, count, observedAt, message) = (value.component, value.source, value.subject, value.code, value.severity, value.impact, value.recovery, value.count, value.observedAt, value.message) }
  }
  private struct CopyRecentActivity: Encodable {
    let attempts: [CopyAttempt]
    let historyTruncated: Bool
    init(_ value: LocalServiceDiagnosticRecentActivity) {
      attempts = value.attempts.map(CopyAttempt.init)
      historyTruncated = value.historyTruncated
    }
  }
  private struct CopyAttempt: Encodable {
    let kind: LocalServiceDiagnosticAttemptKind
    let trigger: LocalServiceDiagnosticAttemptTrigger
    let source: LocalServiceDiagnosticSource
    let subject: String?
    let mode: LocalServiceDiagnosticMode
    let startedAt: Date
    let completedAt: Date?
    let durationMs: UInt64?
    let outcome: LocalServiceDiagnosticAttemptOutcome
    let code: LocalServiceDiagnosticAttemptCode?
    let recovery: LocalServiceDiagnosticRecovery
    let metrics: [String: Int]
    let startRevision: UInt64
    let endRevision: UInt64?
    let parentRefreshStartedAt: Date?
    init(_ value: LocalServiceDiagnosticAttempt) {
      (kind, trigger, source, subject, mode) = (
        value.kind, value.trigger, value.source, value.subject, value.mode
      )
      (startedAt, completedAt, durationMs, outcome, code, recovery, metrics) = (
        value.startedAt, value.completedAt, value.durationMs, value.outcome, value.code,
        value.recovery, value.metrics
      )
      (startRevision, endRevision, parentRefreshStartedAt) = (
        value.startRevision, value.endRevision, value.parentRefreshStartedAt
      )
    }
  }

  private static func isoString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  private static func metricsSuffix(_ metrics: [String: Int]) -> String {
    guard !metrics.isEmpty else { return "" }
    return "\t" + metrics.keys.sorted().compactMap { key in
      metrics[key].map { "\(key)=\($0)" }
    }.joined(separator: ",")
  }
}
