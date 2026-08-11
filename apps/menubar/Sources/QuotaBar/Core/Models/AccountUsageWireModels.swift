import Foundation

private let jsonSafeIntegerMaximum = 9_007_199_254_740_991

enum BillingAgent: String, Codable, Sendable {
  case codex
  case claudeCode = "claude_code"
  case grok
  case opencode
  case pi
}

enum BillingChannel: String, Codable, Sendable {
  case openaiDirect = "openai_direct"
  case azureOpenAI = "azure_openai"
  case anthropicDirect = "anthropic_direct"
  case awsBedrock = "aws_bedrock"
  case googleVertex = "google_vertex"
  case openrouter
  case xaiDirect = "xai_direct"
  case unknown
}

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

enum CoverageStatus: String, Codable, Sendable {
  case complete
  case partial
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
      isUsageDate(usageDate),
      (0...23).contains(usageHour),
      isUsageModel(model),
      isUsageBillingDimension(serviceTier), isUsageBillingDimension(speed),
      isUsageBillingDimension(inferenceGeo),
      counts.allSatisfy({ (0...jsonSafeIntegerMaximum).contains($0) }),
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
      && (sourceCostMicrousd.map(isNonnegativeInteger) ?? true)
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

struct UsageSubmissionV2: Decodable, Equatable, Sendable {
  let protocolVersion: Int
  let submissionID: String
  let deviceID: String
  let generation: Int
  let sequence: Int
  let parserRevision: String
  let aggregationTimezone: String
  let coverage: UsageCoverage
  let rows: [UsageHourlyFact]

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
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "protocolVersion", "submissionId", "deviceId", "generation", "sequence", "parserRevision",
      "aggregationTimezone", "coverage", "rows",
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

    let start = UsageCoverage.utcHour(coverage.startAt)
    let end = UsageCoverage.utcHour(coverage.endAt)
    guard protocolVersion == 2,
      isUsageOpaqueID(submissionID), isUsageOpaqueID(deviceID), isUsageOpaqueID(parserRevision),
      (1...jsonSafeIntegerMaximum).contains(generation),
      (0...jsonSafeIntegerMaximum).contains(sequence),
      isUsageTimezone(aggregationTimezone), TimeZone(identifier: aggregationTimezone) != nil,
      coverage.isValid,
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
      Set(rows.map(usageHourlyFactIdentity)).count == rows.count,
      Set(rows.map(\.model)).count <= 64
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .rows,
        in: container,
        debugDescription: "Invalid Usage v2 submission."
      )
    }
  }
}

enum UsageCostMode: String, Codable, Sendable {
  case calculate
  case auto
  case reported
}

enum UsageCostBasis: String, Codable, Sendable {
  case calculated
  case reported
  case mixed
  case none
}

enum UsageCostStatus: String, Codable, Sendable {
  case complete
  case partial
  case unavailable
}

enum UsageCostAssumption: String, Codable, Sendable {
  case agentDefaultChannel = "agent_default_channel"
  case modelAlias = "model_alias"
  case wildcardServiceTier = "wildcard_service_tier"
  case wildcardSpeed = "wildcard_speed"
  case wildcardInferenceGeo = "wildcard_inference_geo"
  case wildcardContextBucket = "wildcard_context_bucket"
  case cacheWriteInferredRate = "cache_write_inferred_rate"
  case sourceReported = "source_reported"
}

enum UsageUnpricedReason: String, Codable, Sendable {
  case unknownChannel = "unknown_channel"
  case unknownModel = "unknown_model"
  case outsideEffectiveRange = "outside_effective_range"
  case unsupportedDimensions = "unsupported_dimensions"
  case ambiguousPrice = "ambiguous_price"
  case missingRate = "missing_rate"
  case incompleteSourceCost = "incomplete_source_cost"
  case invalidCatalog = "invalid_catalog"
}

struct UsageUnpricedItem: Codable, Equatable, Sendable {
  let billingChannel: BillingChannel
  let model: String
  let reason: UsageUnpricedReason
  let rows: Int

  private enum CodingKeys: String, CodingKey {
    case billingChannel
    case model
    case reason
    case rows
  }

  var isValid: Bool {
    isUsageModel(model)
      && (1...jsonSafeIntegerMaximum).contains(rows)
  }
}

extension UsageUnpricedItem {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["billingChannel", "model", "reason", "rows"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    billingChannel = try container.decode(BillingChannel.self, forKey: .billingChannel)
    model = try container.decode(String.self, forKey: .model)
    reason = try container.decode(UsageUnpricedReason.self, forKey: .reason)
    rows = try container.decode(Int.self, forKey: .rows)
  }
}

struct UsageCostOutcome: Codable, Equatable, Sendable {
  let mode: UsageCostMode
  let basis: UsageCostBasis
  let status: UsageCostStatus
  let amountMicrousd: String?
  let catalogRevision: String?
  let calculatedRows: Int
  let reportedRows: Int
  let unpricedRows: Int
  let assumptions: [UsageCostAssumption]
  let unpriced: [UsageUnpricedItem]

  private enum CodingKeys: String, CodingKey {
    case mode
    case basis
    case status
    case amountMicrousd
    case catalogRevision
    case calculatedRows
    case reportedRows
    case unpricedRows
    case assumptions
    case unpriced
  }

  var isValid: Bool {
    let rowCounts = [calculatedRows, reportedRows, unpricedRows]
    guard rowCounts.allSatisfy({ (0...jsonSafeIntegerMaximum).contains($0) }),
      assumptions.count <= 16,
      Set(assumptions.map(\.rawValue)).count == assumptions.count,
      unpriced.count <= 100,
      unpriced.allSatisfy(\.isValid),
      amountMicrousd.map(isNonnegativeInteger) ?? true,
      catalogRevision.map(isUsageOpaqueID) ?? true,
      let pricedRows = safeSum([calculatedRows, reportedRows]),
      let itemRows = safeSum(unpriced.map(\.rows))
    else { return false }

    let expectedBasis: UsageCostBasis =
      if calculatedRows > 0 && reportedRows > 0 {
        .mixed
      } else if calculatedRows > 0 {
        .calculated
      } else if reportedRows > 0 {
        .reported
      } else {
        .none
      }
    let expectedStatus: UsageCostStatus =
      if unpricedRows == 0 {
        .complete
      } else if pricedRows > 0 {
        .partial
      } else {
        .unavailable
      }
    return basis == expectedBasis
      && status == expectedStatus
      && (amountMicrousd != nil) == (pricedRows > 0)
      && itemRows == unpricedRows
  }
}

extension UsageCostOutcome {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "mode", "basis", "status", "amountMicrousd", "catalogRevision", "calculatedRows",
      "reportedRows",
      "unpricedRows", "assumptions", "unpriced",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    mode = try container.decode(UsageCostMode.self, forKey: .mode)
    basis = try container.decode(UsageCostBasis.self, forKey: .basis)
    status = try container.decode(UsageCostStatus.self, forKey: .status)
    amountMicrousd = try container.decode(String?.self, forKey: .amountMicrousd)
    catalogRevision = try container.decode(String?.self, forKey: .catalogRevision)
    calculatedRows = try container.decode(Int.self, forKey: .calculatedRows)
    reportedRows = try container.decode(Int.self, forKey: .reportedRows)
    unpricedRows = try container.decode(Int.self, forKey: .unpricedRows)
    assumptions = try container.decode([UsageCostAssumption].self, forKey: .assumptions)
    unpriced = try container.decode([UsageUnpricedItem].self, forKey: .unpriced)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .status,
        in: container,
        debugDescription: "Invalid Usage cost outcome."
      )
    }
  }
}

struct UsageTokenTotals: Codable, Equatable, Sendable {
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
    guard counts.allSatisfy({ (0...jsonSafeIntegerMaximum).contains($0) }),
      let classifiedInput = safeSum([
        cacheReadTokens, cacheWrite5mTokens, cacheWrite1hTokens, cacheWriteInferredTokens,
      ])
    else { return false }
    let hasSourceCost = sourceCostMicrousd != nil
    return classifiedInput <= inputTokens
      && reasoningTokens <= outputTokens
      && sourceCostCoveredRequests <= requests
      && (requests > 0 || (webSearchRequests == 0 && webFetchRequests == 0))
      && hasSourceCost == (sourceCostCoveredRequests > 0)
      && (sourceCostMicrousd.map(isNonnegativeInteger) ?? true)
  }

  var cachedInputTokens: Int {
    safeSum([
      cacheReadTokens, cacheWrite5mTokens, cacheWrite1hTokens, cacheWriteInferredTokens,
    ]) ?? 0
  }
}

extension UsageTokenTotals {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "inputTokens", "cacheReadTokens", "cacheWrite5MTokens", "cacheWrite1HTokens",
      "cacheWriteInferredTokens", "outputTokens", "reasoningTokens", "requests",
      "webSearchRequests",
      "webFetchRequests", "sourceCostMicrousd", "sourceCostCoveredRequests",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
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
    sourceCostMicrousd = try container.decode(String?.self, forKey: .sourceCostMicrousd)
    sourceCostCoveredRequests = try container.decode(Int.self, forKey: .sourceCostCoveredRequests)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .inputTokens,
        in: container,
        debugDescription: "Invalid Usage token totals."
      )
    }
  }
}

enum UsageBreakdownDimension: String, Codable, Sendable {
  case device
  case agent
  case model
  case billingChannel = "billing_channel"
  case usageDate = "usage_date"
  case bucketStartUTC = "bucket_start_utc"
}

struct UsageBreakdown: Codable, Equatable, Sendable {
  let dimension: UsageBreakdownDimension
  let key: String
  let totals: UsageTokenTotals
  let cost: UsageCostOutcome

  private enum CodingKeys: String, CodingKey {
    case dimension
    case key
    case totals
    case cost
  }

  var isValid: Bool {
    !key.isEmpty && key.count <= 128 && totals.isValid && cost.isValid
  }
}

extension UsageBreakdown {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["dimension", "key", "totals", "cost"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    dimension = try container.decode(UsageBreakdownDimension.self, forKey: .dimension)
    key = try container.decode(String.self, forKey: .key)
    totals = try container.decode(UsageTokenTotals.self, forKey: .totals)
    cost = try container.decode(UsageCostOutcome.self, forKey: .cost)
  }
}

struct UsageCoverageSummaryItem: Codable, Equatable, Sendable {
  let deviceID: String
  let agent: BillingAgent
  let startAt: String
  let endAt: String
  let status: CoverageStatus

  private enum CodingKeys: String, CodingKey {
    case deviceID = "deviceId"
    case agent
    case startAt
    case endAt
    case status
  }

  var isValid: Bool {
    isUsageOpaqueID(deviceID)
      && UsageCoverage(agent: agent, startAt: startAt, endAt: endAt, status: status).isValid
  }
}

extension UsageCoverageSummaryItem {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["deviceId", "agent", "startAt", "endAt", "status"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    deviceID = try container.decode(String.self, forKey: .deviceID)
    agent = try container.decode(BillingAgent.self, forKey: .agent)
    startAt = try container.decode(String.self, forKey: .startAt)
    endAt = try container.decode(String.self, forKey: .endAt)
    status = try container.decode(CoverageStatus.self, forKey: .status)
  }
}

struct UsageDateRange: Codable, Equatable, Sendable {
  let from: String
  let to: String

  private enum CodingKeys: String, CodingKey {
    case from
    case to
  }

  var isValid: Bool {
    isUsageDate(from) && isUsageDate(to) && from <= to
  }
}

extension UsageDateRange {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["from", "to"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    from = try container.decode(String.self, forKey: .from)
    to = try container.decode(String.self, forKey: .to)
  }
}

struct AccountUsageSummary: Codable, Equatable, Sendable {
  let range: UsageDateRange
  let totals: UsageTokenTotals
  let cost: UsageCostOutcome
  let coverage: [UsageCoverageSummaryItem]
  let breakdowns: [UsageBreakdown]

  private enum CodingKeys: String, CodingKey {
    case range
    case totals
    case cost
    case coverage
    case breakdowns
  }

  var isValid: Bool {
    range.isValid
      && totals.isValid
      && cost.isValid
      && coverage.count <= 2_048
      && coverage.allSatisfy(\.isValid)
      && breakdowns.count <= 1_000
      && breakdowns.allSatisfy(\.isValid)
  }
}

extension AccountUsageSummary {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["range", "totals", "cost", "coverage", "breakdowns"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    range = try container.decode(UsageDateRange.self, forKey: .range)
    totals = try container.decode(UsageTokenTotals.self, forKey: .totals)
    cost = try container.decode(UsageCostOutcome.self, forKey: .cost)
    coverage = try container.decode([UsageCoverageSummaryItem].self, forKey: .coverage)
    breakdowns = try container.decode([UsageBreakdown].self, forKey: .breakdowns)
  }
}

enum LocalUsageReportStatus: String, Codable, Sendable {
  case complete
  case partial
  case unavailable
}

struct LocalUsageReport: Codable, Equatable, Sendable {
  let protocolVersion: Int
  let generatedAt: Date
  let aggregationTimezone: String?
  let range: UsageDateRange
  let status: LocalUsageReportStatus
  let totals: UsageTokenTotals?
  let cost: UsageCostOutcome?
  let coverage: [UsageCoverage]
  let breakdowns: [UsageBreakdown]

  init(
    protocolVersion: Int = 2,
    generatedAt: Date,
    aggregationTimezone: String?,
    range: UsageDateRange,
    status: LocalUsageReportStatus,
    totals: UsageTokenTotals?,
    cost: UsageCostOutcome?,
    coverage: [UsageCoverage],
    breakdowns: [UsageBreakdown]
  ) {
    self.protocolVersion = protocolVersion
    self.generatedAt = generatedAt
    self.aggregationTimezone = aggregationTimezone
    self.range = range
    self.status = status
    self.totals = totals
    self.cost = cost
    self.coverage = coverage
    self.breakdowns = breakdowns
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "protocolVersion", "generatedAt", "aggregationTimezone", "range", "status", "totals", "cost",
      "coverage", "breakdowns",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    generatedAt = try container.decode(Date.self, forKey: .generatedAt)
    aggregationTimezone = try container.decode(String?.self, forKey: .aggregationTimezone)
    range = try container.decode(UsageDateRange.self, forKey: .range)
    status = try container.decode(LocalUsageReportStatus.self, forKey: .status)
    totals = try container.decode(UsageTokenTotals?.self, forKey: .totals)
    cost = try container.decode(UsageCostOutcome?.self, forKey: .cost)
    coverage = try container.decode([UsageCoverage].self, forKey: .coverage)
    breakdowns = try container.decode([UsageBreakdown].self, forKey: .breakdowns)

    let unavailable = status == .unavailable
    let expectedStatus: LocalUsageReportStatus =
      coverage.allSatisfy { $0.status == .complete } ? .complete : .partial
    let validAvailable =
      !unavailable
      && aggregationTimezone.flatMap(TimeZone.init(identifier:)) != nil
      && totals?.isValid == true
      && cost?.isValid == true
      && status == expectedStatus
    let validUnavailable =
      unavailable
      && aggregationTimezone == nil
      && totals == nil
      && cost == nil
      && coverage.isEmpty
      && breakdowns.isEmpty
    guard protocolVersion == 2,
      range.isValid,
      coverage.count <= 2_048,
      coverage.allSatisfy(\.isOrdered),
      breakdowns.count <= 1_000,
      breakdowns.allSatisfy(\.isValid),
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
    try container.encode(totals, forKey: .totals)
    try container.encode(cost, forKey: .cost)
    try container.encode(coverage, forKey: .coverage)
    try container.encode(breakdowns, forKey: .breakdowns)
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case generatedAt
    case aggregationTimezone
    case range
    case status
    case totals
    case cost
    case coverage
    case breakdowns
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
    guard protocolVersion == 2, usage.isValid else {
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

struct QuotaUserAccount: Codable, Equatable, Sendable {
  let accountID: String
  let displayLabel: String?
  let createdAt: Date

  private enum CodingKeys: String, CodingKey {
    case accountID = "accountId"
    case displayLabel
    case createdAt
  }

  var isValid: Bool {
    isUsageOpaqueID(accountID)
      && (displayLabel.map {
        let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= 128 && trimmed == $0
      } ?? true)
  }
}

extension QuotaUserAccount {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["accountId", "displayLabel", "createdAt"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accountID = try container.decode(String.self, forKey: .accountID)
    displayLabel = try container.decode(String?.self, forKey: .displayLabel)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .accountID,
        in: container,
        debugDescription: "Invalid account metadata."
      )
    }
  }
}

enum AccountDeviceStatus: String, Codable, Sendable {
  case active
  case offline
  case signedOut = "signed_out"
}

enum AccountDevicePlatform: String, Codable, Sendable {
  case macos
  case linux
  case windows
}

struct AccountDevice: Codable, Equatable, Identifiable, Sendable {
  let deviceID: String
  let displayName: String
  let platform: AccountDevicePlatform
  let deviceGeneration: Int
  let status: AccountDeviceStatus
  let createdAt: Date
  let lastLoginAt: Date
  let lastSeenAt: Date?
  let signedOutAt: Date?

  var id: String { deviceID }

  private enum CodingKeys: String, CodingKey {
    case deviceID = "deviceId"
    case displayName
    case platform
    case deviceGeneration
    case status
    case createdAt
    case lastLoginAt
    case lastSeenAt
    case signedOutAt
  }

  var isValid: Bool {
    isUsageOpaqueID(deviceID)
      && !displayName.isEmpty && displayName.count <= 128
      && displayName == displayName.trimmingCharacters(in: .whitespacesAndNewlines)
      && (1...jsonSafeIntegerMaximum).contains(deviceGeneration)
      && (status == .signedOut) == (signedOutAt != nil)
  }
}

extension AccountDevice {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "deviceId", "displayName", "platform", "deviceGeneration", "status", "createdAt",
      "lastLoginAt",
      "lastSeenAt", "signedOutAt",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    deviceID = try container.decode(String.self, forKey: .deviceID)
    displayName = try container.decode(String.self, forKey: .displayName)
    platform = try container.decode(AccountDevicePlatform.self, forKey: .platform)
    deviceGeneration = try container.decode(Int.self, forKey: .deviceGeneration)
    status = try container.decode(AccountDeviceStatus.self, forKey: .status)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    lastLoginAt = try container.decode(Date.self, forKey: .lastLoginAt)
    lastSeenAt = try container.decode(Date?.self, forKey: .lastSeenAt)
    signedOutAt = try container.decode(Date?.self, forKey: .signedOutAt)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .deviceID,
        in: container,
        debugDescription: "Invalid account device."
      )
    }
  }
}

struct AccountQuotaObservation: Codable, Equatable, Sendable {
  let deviceID: String
  let sequence: Int
  let capturedAt: Date
  let snapshot: QuotaSnapshot
  let updatedAt: Date

  private enum CodingKeys: String, CodingKey {
    case deviceID = "deviceId"
    case sequence
    case capturedAt
    case snapshot
    case updatedAt
  }

  var isValid: Bool {
    isUsageOpaqueID(deviceID) && (0...jsonSafeIntegerMaximum).contains(sequence)
  }

}

extension AccountQuotaObservation {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "deviceId", "sequence", "capturedAt", "snapshot", "updatedAt",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    deviceID = try container.decode(String.self, forKey: .deviceID)
    sequence = try container.decode(Int.self, forKey: .sequence)
    capturedAt = try container.decode(Date.self, forKey: .capturedAt)
    snapshot = try container.decode(QuotaSnapshot.self, forKey: .snapshot)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
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
    guard protocolVersion == 2, quota.count <= 8_192, quota.allSatisfy(\.isValid) else {
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
    guard isUsageOpaqueID(deviceID), isUsageTimezone(aggregationTimezone),
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
  let coverage: [UsageCoverageSummaryItem]
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
    coverage = try container.decode([UsageCoverageSummaryItem].self, forKey: .coverage)
    cost = try container.decode(UsageCostOutcome.self, forKey: .cost)
    let decodedStart = UsageCoverage.utcHour(startAt)
    let decodedEnd = UsageCoverage.utcHour(endAt)
    let costRows = safeSum([cost.calculatedRows, cost.reportedRows, cost.unpricedRows])
    guard protocolVersion == 2,
      let start = decodedStart, let end = decodedEnd,
      end > start, end.timeIntervalSince(start) <= 744 * 3_600,
      facts.count <= 1_000,
      facts.allSatisfy({ item in
        guard let bucket = UsageCoverage.utcHour(item.fact.bucketStartUTC) else { return false }
        return bucket >= start && bucket < end
      }),
      coverage.count <= 2_048,
      coverage.allSatisfy(\.isValid),
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

struct AccountSummary: Codable, Equatable, Sendable {
  let protocolVersion: Int
  let generatedAt: Date
  let account: QuotaUserAccount
  let devices: [AccountDevice]
  let quota: [AccountQuotaObservation]
  let usage: AccountUsageSummary

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case generatedAt
    case account
    case devices
    case quota
    case usage
  }

  init(
    protocolVersion: Int = 2,
    generatedAt: Date,
    account: QuotaUserAccount,
    devices: [AccountDevice],
    quota: [AccountQuotaObservation],
    usage: AccountUsageSummary
  ) {
    self.protocolVersion = protocolVersion
    self.generatedAt = generatedAt
    self.account = account
    self.devices = devices
    self.quota = quota
    self.usage = usage
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "protocolVersion", "generatedAt", "account", "devices", "quota", "usage",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    generatedAt = try container.decode(Date.self, forKey: .generatedAt)
    account = try container.decode(QuotaUserAccount.self, forKey: .account)
    devices = try container.decode([AccountDevice].self, forKey: .devices)
    quota = try container.decode([AccountQuotaObservation].self, forKey: .quota)
    usage = try container.decode(AccountUsageSummary.self, forKey: .usage)
    guard protocolVersion == 2,
      account.isValid,
      devices.count <= 256,
      devices.allSatisfy(\.isValid),
      quota.count <= 8_192,
      quota.allSatisfy(\.isValid),
      usage.isValid
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .protocolVersion,
        in: container,
        debugDescription: "Invalid account summary."
      )
    }
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
    guard protocolVersion == 2,
      isUsageOpaqueID(deviceID),
      (1...jsonSafeIntegerMaximum).contains(deviceGeneration),
      (0...jsonSafeIntegerMaximum).contains(acceptedSequence),
      (0...jsonSafeIntegerMaximum).contains(nextSnapshotSequence)
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
    guard protocolVersion == 2,
      isUsageOpaqueID(accountID), isUsageOpaqueID(deviceID),
      (1...jsonSafeIntegerMaximum).contains(deviceGeneration),
      (0...jsonSafeIntegerMaximum).contains(nextSnapshotSequence),
      (0...jsonSafeIntegerMaximum).contains(nextUsageSequence),
      (0...jsonSafeIntegerMaximum).contains(usageSyncRevision)
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
    return isUsageOpaqueID(entryID)
      && billingChannel != .unknown
      && isUsageModel(model)
      && aliases.count <= 16
      && aliases.allSatisfy(isUsageModel)
      && Set(names).count == names.count
      && isUsageDate(effectiveFrom)
      && (effectiveTo.map({ isUsageDate($0) && $0 > effectiveFrom }) ?? true)
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
    guard protocolVersion == 2,
      isUsageOpaqueID(revision),
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

private func isUsageDate(_ value: String) -> Bool {
  guard value.count == 10 else { return false }
  let formatter = DateFormatter()
  formatter.calendar = Calendar(identifier: .iso8601)
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  formatter.dateFormat = "yyyy-MM-dd"
  formatter.isLenient = false
  return formatter.date(from: value).map({ formatter.string(from: $0) == value }) ?? false
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

private func isNonnegativeInteger(_ value: String) -> Bool {
  guard !value.isEmpty, value.count <= 32,
    value.utf8.allSatisfy({ (48...57).contains($0) })
  else { return false }
  return value == "0" || value.first != "0"
}

private func isDecimalAmount(_ value: String) -> Bool {
  guard !value.isEmpty, value.count <= 32 else { return false }
  let parts = value.split(separator: ".", omittingEmptySubsequences: false)
  guard (1...2).contains(parts.count), isNonnegativeInteger(String(parts[0])) else { return false }
  return parts.count == 1
    || (!parts[1].isEmpty && parts[1].count <= 12
      && parts[1].utf8.allSatisfy({ (48...57).contains($0) }))
}

private func safeSum(_ values: [Int]) -> Int? {
  var total = 0
  for value in values {
    let (next, overflow) = total.addingReportingOverflow(value)
    guard !overflow, next <= jsonSafeIntegerMaximum else { return nil }
    total = next
  }
  return total
}

private func isUsageOpaqueID(_ value: String) -> Bool {
  guard let first = value.utf8.first, !value.isEmpty, value.count <= 128,
    isUsageASCIIAlphaNumeric(first)
  else { return false }
  return value.utf8.allSatisfy { byte in
    isUsageASCIIAlphaNumeric(byte) || byte == 46 || byte == 58 || byte == 95 || byte == 45
  }
}

private func isUsageASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
  (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
}

private func isUsageBillingDimension(_ value: String) -> Bool {
  guard let first = value.utf8.first, !value.isEmpty, value.count <= 64,
    isUsageASCIIAlphaNumeric(first)
  else { return false }
  return value.utf8.allSatisfy { byte in
    isUsageASCIIAlphaNumeric(byte) || byte == 46 || byte == 58 || byte == 95 || byte == 43
      || byte == 45
  }
}

private func isUsagePricingDimension(_ value: String) -> Bool {
  value == "*" || isUsageBillingDimension(value)
}

private func isUsageModel(_ value: String) -> Bool {
  guard let first = value.utf8.first, !value.isEmpty, value.count <= 128,
    isUsageASCIIAlphaNumeric(first)
  else { return false }
  return value.utf8.allSatisfy { byte in
    isUsageASCIIAlphaNumeric(byte) || byte == 46 || byte == 58 || byte == 95 || byte == 47
      || byte == 43 || byte == 45
  }
}

private func isUsageTimezone(_ value: String) -> Bool {
  guard !value.isEmpty, value.count <= 64 else { return false }
  return value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
    !component.isEmpty
      && component.utf8.allSatisfy { byte in
        isUsageASCIIAlphaNumeric(byte) || byte == 46 || byte == 95 || byte == 43 || byte == 45
      }
  }
}
