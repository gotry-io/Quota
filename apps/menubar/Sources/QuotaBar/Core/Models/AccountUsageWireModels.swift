import Foundation
import QuotaPresentation
import QuotaWire

enum ChannelSource: String, Codable, Sendable {
  case explicit
  case agentDefault = "agent_default"
  case unknown
}

enum ContextBucket: String, Codable, Sendable {
  case le128k = "le_128k"
  case gt128kLe200k = "gt_128k_le_200k"
  case gt200kLe256k = "gt_200k_le_256k"
  case gt256kLe272k = "gt_256k_le_272k"
  case gt272k = "gt_272k"
}

struct UsageCoverage: Codable, Equatable, Sendable {
  let agent: BillingAgent
  let startAt: String
  let endAt: String
  let status: CoverageStatus

  private enum CodingKeys: String, CodingKey {
    case agent
    case startAt
    case endAt
    case status
  }

  var isValid: Bool {
    guard let start = Self.utcHour(startAt), let end = Self.utcHour(endAt), end > start else {
      return false
    }
    return end.timeIntervalSince(start) <= 744 * 3_600
  }

  var isOrdered: Bool {
    guard let start = Self.utcHour(startAt), let end = Self.utcHour(endAt) else { return false }
    return end > start
  }

  static func utcHour(_ value: String) -> Date? {
    guard value.count == 20, value.hasSuffix(":00:00Z") else { return nil }
    let formatter = ISO8601DateFormatter()
    guard let instant = formatter.date(from: value), formatter.string(from: instant) == value else {
      return nil
    }
    return instant
  }
}

extension UsageCoverage {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["agent", "startAt", "endAt", "status"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    agent = try container.decode(BillingAgent.self, forKey: .agent)
    startAt = try container.decode(String.self, forKey: .startAt)
    endAt = try container.decode(String.self, forKey: .endAt)
    status = try container.decode(CoverageStatus.self, forKey: .status)
  }
}

struct UsageHourlyFact: Codable, Equatable, Sendable {
  let bucketStartUTC: String
  let usageDate: String
  let usageHour: Int
  let agent: BillingAgent
  let billingChannel: BillingChannel
  let channelSource: ChannelSource
  let model: String
  let contextBucket: ContextBucket
  let serviceTier: String
  let speed: String
  let inferenceGeo: String
  let inputTokens: Int
  let cacheReadTokens: Int
  let cacheWrite5mTokens: Int
  let cacheWrite1hTokens: Int
  let cacheWriteInferredTokens: Int
  let outputTokens: Int
  let reasoningTokens: Int
  let requests: Int
  let webSearchRequests: Int
  let webFetchRequests: Int
  let sourceCostMicrousd: String?
  let sourceCostCoveredRequests: Int

  private enum CodingKeys: String, CodingKey {
    case bucketStartUTC = "bucketStartUtc"
    case usageDate
    case usageHour
    case agent
    case billingChannel
    case channelSource
    case model
    case contextBucket
    case serviceTier
    case speed
    case inferenceGeo
    case inputTokens
    case cacheReadTokens
    case cacheWrite5mTokens = "cacheWrite5MTokens"
    case cacheWrite1hTokens = "cacheWrite1HTokens"
    case cacheWriteInferredTokens
    case outputTokens
    case reasoningTokens
    case requests
    case webSearchRequests
    case webFetchRequests
    case sourceCostMicrousd
    case sourceCostCoveredRequests
  }

  var isValid: Bool {
    let counts = [
      inputTokens, cacheReadTokens, cacheWrite5mTokens, cacheWrite1hTokens,
      cacheWriteInferredTokens, outputTokens, reasoningTokens, requests, webSearchRequests,
      webFetchRequests, sourceCostCoveredRequests,
    ]
    guard UsageCoverage.utcHour(bucketStartUTC) != nil,
      WireValidation.isCalendarDate(usageDate),
      (0...23).contains(usageHour),
      WireValidation.isModel(model),
      WireValidation.isBillingDimension(serviceTier), WireValidation.isBillingDimension(speed),
      WireValidation.isBillingDimension(inferenceGeo),
      counts.allSatisfy({ (0...WireCodec.jsonSafeIntegerMaximum).contains($0) }),
      requests > 0,
      reasoningTokens <= outputTokens,
      sourceCostCoveredRequests <= requests,
      (billingChannel == .unknown) == (channelSource == .unknown)
    else { return false }

    let cacheCounts = [
      cacheReadTokens, cacheWrite5mTokens, cacheWrite1hTokens, cacheWriteInferredTokens,
    ]
    let cacheTotal = cacheCounts.reduce(0) { partial, value in
      let (sum, overflow) = partial.addingReportingOverflow(value)
      return overflow ? Int.max : sum
    }
    let hasSourceCost = sourceCostMicrousd != nil
    return cacheTotal <= inputTokens
      && hasSourceCost == (sourceCostCoveredRequests > 0)
      && (sourceCostMicrousd.map(WireValidation.isNonnegativeInteger) ?? true)
  }
}

extension UsageHourlyFact {
  init(from decoder: Decoder) throws {
    try self.init(from: decoder, allowingUnknownKeys: [])
  }

  init(from decoder: Decoder, allowingUnknownKeys allowedKeys: Set<String>) throws {
    try decoder.rejectUnknownWireKeys(
      Set([
        "bucketStartUtc", "usageDate", "usageHour", "agent", "billingChannel", "channelSource",
        "model",
        "contextBucket", "serviceTier", "speed", "inferenceGeo", "inputTokens", "cacheReadTokens",
        "cacheWrite5MTokens", "cacheWrite1HTokens", "cacheWriteInferredTokens", "outputTokens",
        "reasoningTokens", "requests", "webSearchRequests", "webFetchRequests",
        "sourceCostMicrousd",
        "sourceCostCoveredRequests",
      ]).union(allowedKeys))
    let container = try decoder.container(keyedBy: CodingKeys.self)
    bucketStartUTC = try container.decode(String.self, forKey: .bucketStartUTC)
    usageDate = try container.decode(String.self, forKey: .usageDate)
    usageHour = try container.decode(Int.self, forKey: .usageHour)
    agent = try container.decode(BillingAgent.self, forKey: .agent)
    billingChannel = try container.decode(BillingChannel.self, forKey: .billingChannel)
    channelSource = try container.decode(ChannelSource.self, forKey: .channelSource)
    model = try container.decode(String.self, forKey: .model)
    contextBucket = try container.decode(ContextBucket.self, forKey: .contextBucket)
    serviceTier = try container.decode(String.self, forKey: .serviceTier)
    speed = try container.decode(String.self, forKey: .speed)
    inferenceGeo = try container.decode(String.self, forKey: .inferenceGeo)
    inputTokens = try container.decode(Int.self, forKey: .inputTokens)
    cacheReadTokens = try container.decode(Int.self, forKey: .cacheReadTokens)
    cacheWrite5mTokens = try container.decode(Int.self, forKey: .cacheWrite5mTokens)
    cacheWrite1hTokens = try container.decode(Int.self, forKey: .cacheWrite1hTokens)
    cacheWriteInferredTokens = try container.decode(Int.self, forKey: .cacheWriteInferredTokens)
    outputTokens = try container.decode(Int.self, forKey: .outputTokens)
    reasoningTokens = try container.decode(Int.self, forKey: .reasoningTokens)
    requests = try container.decode(Int.self, forKey: .requests)
    webSearchRequests = try container.decode(Int.self, forKey: .webSearchRequests)
    webFetchRequests = try container.decode(Int.self, forKey: .webFetchRequests)
    sourceCostMicrousd = try container.decodeIfPresent(String.self, forKey: .sourceCostMicrousd)
    sourceCostCoveredRequests = try container.decode(Int.self, forKey: .sourceCostCoveredRequests)
  }
}

struct UsageSubmission: Decodable, Equatable, Sendable {
  let protocolVersion: Int
  let submissionID: String
  let deviceID: String
  let generation: Int
  let sequence: Int
  let parserRevision: String
  let aggregationTimezone: String
  let coverage: UsageCoverage
  let rows: [UsageHourlyFact]
  let writeMode: UsageSubmissionWriteMode?
  let multipart: UsageSubmissionMultipart?

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case submissionID = "submissionId"
    case deviceID = "deviceId"
    case generation
    case sequence
    case parserRevision
    case aggregationTimezone
    case coverage
    case rows
    case writeMode
    case multipart
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "protocolVersion", "submissionId", "deviceId", "generation", "sequence", "parserRevision",
      "aggregationTimezone", "coverage", "rows", "writeMode", "multipart",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    submissionID = try container.decode(String.self, forKey: .submissionID)
    deviceID = try container.decode(String.self, forKey: .deviceID)
    generation = try container.decode(Int.self, forKey: .generation)
    sequence = try container.decode(Int.self, forKey: .sequence)
    parserRevision = try container.decode(String.self, forKey: .parserRevision)
    aggregationTimezone = try container.decode(String.self, forKey: .aggregationTimezone)
    coverage = try container.decode(UsageCoverage.self, forKey: .coverage)
    rows = try container.decode([UsageHourlyFact].self, forKey: .rows)
    writeMode =
      container.contains(.writeMode)
      ? try container.decode(UsageSubmissionWriteMode.self, forKey: .writeMode)
      : nil
    multipart =
      container.contains(.multipart)
      ? try container.decode(UsageSubmissionMultipart.self, forKey: .multipart)
      : nil

    let start = UsageCoverage.utcHour(coverage.startAt)
    let end = UsageCoverage.utcHour(coverage.endAt)
    guard protocolVersion == WireCodec.managedDataProtocolVersion,
      WireValidation.isOpaqueID(submissionID), WireValidation.isOpaqueID(deviceID), WireValidation.isOpaqueID(parserRevision),
      (1...WireCodec.jsonSafeIntegerMaximum).contains(generation),
      (0...WireCodec.jsonSafeIntegerMaximum).contains(sequence),
      WireValidation.isTimezone(aggregationTimezone), TimeZone(identifier: aggregationTimezone) != nil,
      coverage.isValid,
      writeMode == nil || coverage.status == .partial,
      rows.count <= 2_048,
      rows.allSatisfy({ row in
        guard let bucket = UsageCoverage.utcHour(row.bucketStartUTC) else { return false }
        return row.isValid && row.agent == coverage.agent
          && start.map({ bucket >= $0 }) == true
          && end.map({ bucket < $0 }) == true
          && localProjectionMatches(
            bucketStart: bucket,
            timezone: aggregationTimezone,
            usageDate: row.usageDate,
            usageHour: row.usageHour
          )
      }),
      Set(rows.map(usageHourlyFactIdentity)).count == rows.count
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .rows,
        in: container,
        debugDescription: "Invalid Usage submission."
      )
    }
  }
}

enum UsageSubmissionWriteMode: String, Decodable, Equatable, Sendable {
  case mergePartial = "merge_partial"
}

struct UsageSubmissionMultipart: Decodable, Equatable, Sendable {
  let batchID: String
  let partIndex: Int
  let partCount: Int

  private enum CodingKeys: String, CodingKey {
    case batchID = "batchId"
    case partIndex
    case partCount
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["batchId", "partIndex", "partCount"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    batchID = try container.decode(String.self, forKey: .batchID)
    partIndex = try container.decode(Int.self, forKey: .partIndex)
    partCount = try container.decode(Int.self, forKey: .partCount)
    guard WireValidation.isOpaqueID(batchID), (2...64).contains(partCount),
      (0..<partCount).contains(partIndex)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .partCount,
        in: container,
        debugDescription: "Invalid Usage multipart metadata."
      )
    }
  }
}

enum LocalUsageReportStatus: String, Codable, Sendable {
  case complete
  case partial
  case unavailable
}

struct LocalUsagePeriodSummary: Codable, Equatable, Sendable {
  let totals: UsageSummaryTotals
  let cost: UsageCostOutcome
  let agents: [LocalUsageAgentSummary]
  let modelsTruncated: Bool?

  private enum CodingKeys: String, CodingKey {
    case totals
    case cost
    case agents
    case modelsTruncated
  }

  var isValid: Bool {
    totals.isValid && cost.isValid && agents.count <= 6 && agents.allSatisfy(\.isValid)
      && modelsTruncated != false
  }

  init(
    totals: UsageSummaryTotals,
    cost: UsageCostOutcome,
    agents: [LocalUsageAgentSummary],
    modelsTruncated: Bool? = nil
  ) {
    self.totals = totals
    self.cost = cost
    self.agents = agents
    self.modelsTruncated = modelsTruncated
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["totals", "cost", "agents", "modelsTruncated"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    totals = try container.decode(UsageSummaryTotals.self, forKey: .totals)
    cost = try container.decode(UsageCostOutcome.self, forKey: .cost)
    agents = try container.decode([LocalUsageAgentSummary].self, forKey: .agents)
    modelsTruncated = try decodeTrueMarker(.modelsTruncated, from: container)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .agents, in: container, debugDescription: "Invalid local Usage period summary.")
    }
  }
}

struct LocalUsageCoverage: Codable, Equatable, Sendable {
  let agent: BillingAgent
  let startAt: String
  let endAt: String
  let status: CoverageStatus

  private enum CodingKeys: String, CodingKey {
    case agent
    case startAt
    case endAt
    case status
  }

  var isOrdered: Bool {
    guard let start = UsageCoverage.utcHour(startAt), let end = UsageCoverage.utcHour(endAt) else {
      return false
    }
    return end > start
  }

  init(
    agent: BillingAgent,
    startAt: String,
    endAt: String,
    status: CoverageStatus
  ) {
    self.agent = agent
    self.startAt = startAt
    self.endAt = endAt
    self.status = status
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["agent", "startAt", "endAt", "status"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    agent = try container.decode(BillingAgent.self, forKey: .agent)
    startAt = try container.decode(String.self, forKey: .startAt)
    endAt = try container.decode(String.self, forKey: .endAt)
    status = try container.decode(CoverageStatus.self, forKey: .status)
    guard isOrdered else {
      throw DecodingError.dataCorruptedError(
        forKey: .startAt, in: container, debugDescription: "Invalid local Usage coverage range.")
    }
  }
}

struct LocalUsageReport: Codable, Equatable, Sendable {
  let protocolVersion: Int
  let generatedAt: Date
  let aggregationTimezone: String?
  let range: UsageDateRange
  let status: LocalUsageReportStatus
  let modelCatalogRevision: String?
  let coverage: [LocalUsageCoverage]
  let coverageTruncated: Bool?

  init(
    protocolVersion: Int = 3,
    generatedAt: Date,
    aggregationTimezone: String?,
    range: UsageDateRange,
    status: LocalUsageReportStatus,
    modelCatalogRevision: String? = nil,
    coverage: [LocalUsageCoverage],
    coverageTruncated: Bool? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.generatedAt = generatedAt
    self.aggregationTimezone = aggregationTimezone
    self.range = range
    self.status = status
    self.modelCatalogRevision = modelCatalogRevision
    self.coverage = coverage
    self.coverageTruncated = coverageTruncated
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "protocolVersion", "generatedAt", "aggregationTimezone", "range", "status",
      "modelCatalogRevision", "coverage", "coverageTruncated",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    generatedAt = try container.decode(Date.self, forKey: .generatedAt)
    aggregationTimezone = try container.decode(String?.self, forKey: .aggregationTimezone)
    range = try container.decode(UsageDateRange.self, forKey: .range)
    status = try container.decode(LocalUsageReportStatus.self, forKey: .status)
    modelCatalogRevision = try container.decode(String?.self, forKey: .modelCatalogRevision)
    coverage = try container.decode([LocalUsageCoverage].self, forKey: .coverage)
    coverageTruncated = try decodeTrueMarker(.coverageTruncated, from: container)

    let unavailable = status == .unavailable
    let expectedStatus: LocalUsageReportStatus =
      coverage.allSatisfy { $0.status == .complete } ? .complete : .partial
    let validAvailable =
      !unavailable
      && aggregationTimezone.flatMap(TimeZone.init(identifier:)) != nil
      && modelCatalogRevision.map(WireValidation.isOpaqueID) != false
      && status == expectedStatus
    let validUnavailable =
      unavailable
      && aggregationTimezone == nil
      && modelCatalogRevision == nil
      && coverage.isEmpty
    guard protocolVersion == QuotaProtocol.localUsage,
      range.isValid,
      coverage.count <= 2_048,
      coverage.allSatisfy(\.isOrdered),
      validAvailable || validUnavailable
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .status,
        in: container,
        debugDescription: "Invalid local Usage report."
      )
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(protocolVersion, forKey: .protocolVersion)
    try container.encode(generatedAt, forKey: .generatedAt)
    try container.encode(aggregationTimezone, forKey: .aggregationTimezone)
    try container.encode(range, forKey: .range)
    try container.encode(status, forKey: .status)
    try container.encode(modelCatalogRevision, forKey: .modelCatalogRevision)
    try container.encode(coverage, forKey: .coverage)
    try container.encodeIfPresent(coverageTruncated, forKey: .coverageTruncated)
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case generatedAt
    case aggregationTimezone
    case range
    case status
    case modelCatalogRevision
    case coverage
    case coverageTruncated
  }
}

struct AccountUsageResponse: Decodable, Equatable, Sendable {
  let protocolVersion: Int
  let usage: AccountUsageSummary

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["protocolVersion", "usage"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    usage = try container.decode(AccountUsageSummary.self, forKey: .usage)
    guard protocolVersion == WireCodec.managedDataProtocolVersion, usage.isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .protocolVersion,
        in: container,
        debugDescription: "Invalid account Usage response."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case usage
  }
}

struct AccountQuotaResponse: Decodable, Equatable, Sendable {
  let protocolVersion: Int
  let quota: [AccountQuotaObservation]

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["protocolVersion", "quota"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    quota = try container.decode([AccountQuotaObservation].self, forKey: .quota)
    guard protocolVersion == WireCodec.managedDataProtocolVersion, quota.count <= 8_192, quota.allSatisfy(\.isValid) else {
      throw DecodingError.dataCorruptedError(
        forKey: .protocolVersion,
        in: container,
        debugDescription: "Invalid account quota response."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case quota
  }
}

struct AccountUsageHourlyFact: Decodable, Equatable, Sendable {
  let deviceID: String
  let aggregationTimezone: String
  let fact: UsageHourlyFact

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "deviceId", "aggregationTimezone", "bucketStartUtc", "usageDate", "usageHour", "agent",
      "billingChannel",
      "channelSource", "model", "contextBucket", "serviceTier", "speed", "inferenceGeo",
      "inputTokens",
      "cacheReadTokens", "cacheWrite5MTokens", "cacheWrite1HTokens", "cacheWriteInferredTokens",
      "outputTokens",
      "reasoningTokens", "requests", "webSearchRequests", "webFetchRequests", "sourceCostMicrousd",
      "sourceCostCoveredRequests",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    deviceID = try container.decode(String.self, forKey: .deviceID)
    aggregationTimezone = try container.decode(String.self, forKey: .aggregationTimezone)
    fact = try UsageHourlyFact(
      from: decoder,
      allowingUnknownKeys: ["deviceId", "aggregationTimezone"]
    )
    let bucket = UsageCoverage.utcHour(fact.bucketStartUTC)
    guard WireValidation.isOpaqueID(deviceID), WireValidation.isTimezone(aggregationTimezone),
      TimeZone(identifier: aggregationTimezone) != nil,
      fact.isValid,
      bucket.map({
        localProjectionMatches(
          bucketStart: $0,
          timezone: aggregationTimezone,
          usageDate: fact.usageDate,
          usageHour: fact.usageHour
        )
      }) == true
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .aggregationTimezone,
        in: container,
        debugDescription: "Invalid account hourly Usage fact."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case deviceID = "deviceId"
    case aggregationTimezone
  }
}

struct AccountUsageHourlyResponse: Decodable, Equatable, Sendable {
  let protocolVersion: Int
  let startAt: String
  let endAt: String
  let facts: [AccountUsageHourlyFact]
  let coverage: UsageCoverageVerdict
  let cost: UsageCostOutcome

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "protocolVersion", "startAt", "endAt", "facts", "coverage", "cost",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    startAt = try container.decode(String.self, forKey: .startAt)
    endAt = try container.decode(String.self, forKey: .endAt)
    facts = try container.decode([AccountUsageHourlyFact].self, forKey: .facts)
    coverage = try container.decode(UsageCoverageVerdict.self, forKey: .coverage)
    cost = try container.decode(UsageCostOutcome.self, forKey: .cost)
    let decodedStart = UsageCoverage.utcHour(startAt)
    let decodedEnd = UsageCoverage.utcHour(endAt)
    let costRows = WireValidation.safeSum([cost.calculatedRows, cost.reportedRows, cost.unpricedRows])
    guard protocolVersion == WireCodec.managedDataProtocolVersion,
      let start = decodedStart, let end = decodedEnd,
      end > start, end.timeIntervalSince(start) <= 744 * 3_600,
      facts.count <= 1_000,
      facts.allSatisfy({ item in
        guard let bucket = UsageCoverage.utcHour(item.fact.bucketStartUTC) else { return false }
        return bucket >= start && bucket < end
      }),
      cost.isValid,
      costRows == facts.count
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .protocolVersion,
        in: container,
        debugDescription: "Invalid account hourly Usage response."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case startAt
    case endAt
    case facts
    case coverage
    case cost
  }
}

enum QuotaSnapshotUploadOutcome: String, Codable, Sendable {
  case accepted
  case duplicate
}

struct QuotaSnapshotUploadResponse: Codable, Equatable, Sendable {
  let protocolVersion: Int
  let outcome: QuotaSnapshotUploadOutcome
  let deviceID: String
  let deviceGeneration: Int
  let acceptedSequence: Int
  let nextSnapshotSequence: Int

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case outcome
    case deviceID = "deviceId"
    case deviceGeneration
    case acceptedSequence
    case nextSnapshotSequence
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "protocolVersion", "outcome", "deviceId", "deviceGeneration", "acceptedSequence",
      "nextSnapshotSequence",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    outcome = try container.decode(QuotaSnapshotUploadOutcome.self, forKey: .outcome)
    deviceID = try container.decode(String.self, forKey: .deviceID)
    deviceGeneration = try container.decode(Int.self, forKey: .deviceGeneration)
    acceptedSequence = try container.decode(Int.self, forKey: .acceptedSequence)
    nextSnapshotSequence = try container.decode(Int.self, forKey: .nextSnapshotSequence)
    guard protocolVersion == WireCodec.managedDataProtocolVersion,
      WireValidation.isOpaqueID(deviceID),
      (1...WireCodec.jsonSafeIntegerMaximum).contains(deviceGeneration),
      (0...WireCodec.jsonSafeIntegerMaximum).contains(acceptedSequence),
      (0...WireCodec.jsonSafeIntegerMaximum).contains(nextSnapshotSequence)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .protocolVersion,
        in: container,
        debugDescription: "Invalid quota upload response."
      )
    }
  }
}

struct DeviceSyncResponse: Codable, Equatable, Sendable {
  let protocolVersion: Int
  let accountID: String
  let deviceID: String
  let deviceGeneration: Int
  let nextSnapshotSequence: Int
  let nextUsageSequence: Int
  let usageDeletedBefore: Date?
  let usageSyncRevision: Int

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case accountID = "accountId"
    case deviceID = "deviceId"
    case deviceGeneration
    case nextSnapshotSequence
    case nextUsageSequence
    case usageDeletedBefore
    case usageSyncRevision
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "protocolVersion", "accountId", "deviceId", "deviceGeneration", "nextSnapshotSequence",
      "nextUsageSequence", "usageDeletedBefore", "usageSyncRevision",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    accountID = try container.decode(String.self, forKey: .accountID)
    deviceID = try container.decode(String.self, forKey: .deviceID)
    deviceGeneration = try container.decode(Int.self, forKey: .deviceGeneration)
    nextSnapshotSequence = try container.decode(Int.self, forKey: .nextSnapshotSequence)
    nextUsageSequence = try container.decode(Int.self, forKey: .nextUsageSequence)
    usageDeletedBefore = try container.decode(Date?.self, forKey: .usageDeletedBefore)
    usageSyncRevision = try container.decode(Int.self, forKey: .usageSyncRevision)
    guard protocolVersion == QuotaProtocol.control,
      WireValidation.isOpaqueID(accountID), WireValidation.isOpaqueID(deviceID),
      (1...WireCodec.jsonSafeIntegerMaximum).contains(deviceGeneration),
      (0...WireCodec.jsonSafeIntegerMaximum).contains(nextSnapshotSequence),
      (0...WireCodec.jsonSafeIntegerMaximum).contains(nextUsageSequence),
      (0...WireCodec.jsonSafeIntegerMaximum).contains(usageSyncRevision)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .protocolVersion,
        in: container,
        debugDescription: "Invalid device sync response."
      )
    }
  }
}

struct PricingRates: Codable, Equatable, Sendable {
  let uncachedInputPerMillion: String?
  let cacheReadPerMillion: String?
  let cacheWrite5mPerMillion: String?
  let cacheWrite1hPerMillion: String?
  let cacheWriteInferredPerMillion: String?
  let outputPerMillion: String?
  let webSearchPerRequest: String?
  let webFetchPerRequest: String?

  private enum CodingKeys: String, CodingKey {
    case uncachedInputPerMillion
    case cacheReadPerMillion
    case cacheWrite5mPerMillion = "cacheWrite5MPerMillion"
    case cacheWrite1hPerMillion = "cacheWrite1HPerMillion"
    case cacheWriteInferredPerMillion
    case outputPerMillion
    case webSearchPerRequest
    case webFetchPerRequest
  }

  var isValid: Bool {
    let values = [
      uncachedInputPerMillion, cacheReadPerMillion, cacheWrite5mPerMillion,
      cacheWrite1hPerMillion, cacheWriteInferredPerMillion, outputPerMillion,
      webSearchPerRequest, webFetchPerRequest,
    ]
    return values.contains(where: { $0 != nil })
      && values.compactMap({ $0 }).allSatisfy(isDecimalAmount)
  }
}

extension PricingRates {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "uncachedInputPerMillion", "cacheReadPerMillion", "cacheWrite5MPerMillion",
      "cacheWrite1HPerMillion", "cacheWriteInferredPerMillion", "outputPerMillion",
      "webSearchPerRequest",
      "webFetchPerRequest",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    uncachedInputPerMillion = try container.decode(String?.self, forKey: .uncachedInputPerMillion)
    cacheReadPerMillion = try container.decode(String?.self, forKey: .cacheReadPerMillion)
    cacheWrite5mPerMillion = try container.decode(String?.self, forKey: .cacheWrite5mPerMillion)
    cacheWrite1hPerMillion = try container.decode(String?.self, forKey: .cacheWrite1hPerMillion)
    cacheWriteInferredPerMillion = try container.decode(
      String?.self,
      forKey: .cacheWriteInferredPerMillion
    )
    outputPerMillion = try container.decode(String?.self, forKey: .outputPerMillion)
    webSearchPerRequest = try container.decode(String?.self, forKey: .webSearchPerRequest)
    webFetchPerRequest = try container.decode(String?.self, forKey: .webFetchPerRequest)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .uncachedInputPerMillion,
        in: container,
        debugDescription: "Invalid pricing rates."
      )
    }
  }
}

struct PricingCatalogEntry: Codable, Equatable, Sendable {
  let entryID: String
  let billingChannel: BillingChannel
  let model: String
  let aliases: [String]
  let effectiveFrom: String
  let effectiveTo: String?
  let serviceTier: String
  let speed: String
  let inferenceGeo: String
  let contextBucket: String
  let currency: String
  let rates: PricingRates
  let sourceURL: URL
  let verifiedAt: Date

  private enum CodingKeys: String, CodingKey {
    case entryID = "entryId"
    case billingChannel
    case model
    case aliases
    case effectiveFrom
    case effectiveTo
    case serviceTier
    case speed
    case inferenceGeo
    case contextBucket
    case currency
    case rates
    case sourceURL = "sourceUrl"
    case verifiedAt
  }

  var isValid: Bool {
    let names = [model] + aliases
    return WireValidation.isOpaqueID(entryID)
      && billingChannel != .unknown
      && WireValidation.isModel(model)
      && aliases.count <= 16
      && aliases.allSatisfy(WireValidation.isModel)
      && Set(names).count == names.count
      && WireValidation.isCalendarDate(effectiveFrom)
      && (effectiveTo.map({ WireValidation.isCalendarDate($0) && $0 > effectiveFrom }) ?? true)
      && isUsagePricingDimension(serviceTier) && isUsagePricingDimension(speed)
      && isUsagePricingDimension(inferenceGeo)
      && (["le_128k", "gt_128k_le_200k", "gt_200k_le_256k", "gt_256k_le_272k", "gt_272k", "*"]
        .contains(contextBucket))
      && currency == "USD"
      && rates.isValid
      && sourceURL.scheme == "https"
  }
}

extension PricingCatalogEntry {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "entryId", "billingChannel", "model", "aliases", "effectiveFrom", "effectiveTo",
      "serviceTier", "speed",
      "inferenceGeo", "contextBucket", "currency", "rates", "sourceUrl", "verifiedAt",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    entryID = try container.decode(String.self, forKey: .entryID)
    billingChannel = try container.decode(BillingChannel.self, forKey: .billingChannel)
    model = try container.decode(String.self, forKey: .model)
    aliases = try container.decode([String].self, forKey: .aliases)
    effectiveFrom = try container.decode(String.self, forKey: .effectiveFrom)
    effectiveTo = try container.decode(String?.self, forKey: .effectiveTo)
    serviceTier = try container.decode(String.self, forKey: .serviceTier)
    speed = try container.decode(String.self, forKey: .speed)
    inferenceGeo = try container.decode(String.self, forKey: .inferenceGeo)
    contextBucket = try container.decode(String.self, forKey: .contextBucket)
    currency = try container.decode(String.self, forKey: .currency)
    rates = try container.decode(PricingRates.self, forKey: .rates)
    sourceURL = try container.decode(URL.self, forKey: .sourceURL)
    verifiedAt = try container.decode(Date.self, forKey: .verifiedAt)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .entryID,
        in: container,
        debugDescription: "Invalid pricing catalog entry."
      )
    }
  }
}

struct PricingCatalog: Decodable, Equatable, Sendable {
  let protocolVersion: Int
  let revision: String
  let publishedAt: Date
  let entries: [PricingCatalogEntry]

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case revision
    case publishedAt
    case entries
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["protocolVersion", "revision", "publishedAt", "entries"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    revision = try container.decode(String.self, forKey: .revision)
    publishedAt = try container.decode(Date.self, forKey: .publishedAt)
    entries = try container.decode([PricingCatalogEntry].self, forKey: .entries)
    guard protocolVersion == QuotaProtocol.control,
      WireValidation.isOpaqueID(revision),
      entries.count <= 4_096,
      entries.allSatisfy(\.isValid),
      Set(entries.map(\.entryID)).count == entries.count
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .entries,
        in: container,
        debugDescription: "Invalid pricing catalog."
      )
    }
  }
}

private func localProjectionMatches(
  bucketStart: Date,
  timezone: String,
  usageDate: String,
  usageHour: Int
) -> Bool {
  guard let timeZone = TimeZone(identifier: timezone) else { return false }
  var calendar = Calendar(identifier: .gregorian)
  calendar.locale = Locale(identifier: "en_US_POSIX")
  calendar.timeZone = timeZone
  return [bucketStart, bucketStart.addingTimeInterval(3_600 - 0.001)].contains { instant in
    let components = calendar.dateComponents([.year, .month, .day, .hour], from: instant)
    guard let year = components.year, let month = components.month, let day = components.day,
      let hour = components.hour
    else { return false }
    return String(format: "%04d-%02d-%02d", year, month, day) == usageDate && hour == usageHour
  }
}

private func usageHourlyFactIdentity(_ fact: UsageHourlyFact) -> String {
  [
    fact.bucketStartUTC,
    fact.usageDate,
    String(fact.usageHour),
    fact.agent.rawValue,
    fact.billingChannel.rawValue,
    fact.channelSource.rawValue,
    fact.model,
    fact.contextBucket.rawValue,
    fact.serviceTier,
    fact.speed,
    fact.inferenceGeo,
  ].joined(separator: "\u{0}")
}

private func isDecimalAmount(_ value: String) -> Bool {
  guard !value.isEmpty, value.count <= 32 else { return false }
  let parts = value.split(separator: ".", omittingEmptySubsequences: false)
  guard (1...2).contains(parts.count), WireValidation.isNonnegativeInteger(String(parts[0])) else { return false }
  return parts.count == 1
    || (!parts[1].isEmpty && parts[1].count <= 12
      && parts[1].utf8.allSatisfy({ (48...57).contains($0) }))
}

private func isUsagePricingDimension(_ value: String) -> Bool {
  value == "*" || WireValidation.isBillingDimension(value)
}

extension UsageSummaryTotals {
  /// The local v3 summary shape, projected from the managed token totals. Which counts fold
  /// into which is QuotaBar's Usage presentation, not part of either wire object.
  init(_ totals: UsageTokenTotals) {
    self.init(
      totalTokens: totals.inputTokens + totals.outputTokens,
      inputTokens: totals.inputTokens,
      outputTokens: totals.outputTokens,
      cacheReadInputTokens: totals.cacheReadTokens,
      cacheWriteInputTokens: totals.cacheWrite5mTokens + totals.cacheWrite1hTokens
        + totals.cacheWriteInferredTokens,
      reasoningTokens: totals.reasoningTokens,
      messages: totals.requests
    )
  }
}
