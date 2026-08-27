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

/// One row of Usage, identified by what it measures rather than by when.
///
/// The hour is carried by the upload that replaces it, so a row names no instant, no local
/// date, and no aggregation timezone: those made the same measurement look like two rows
/// whenever a device moved.
struct UsageRow: Codable, Equatable, Sendable {
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

  /// What makes two measurements the same row inside one hour.
  var identity: String {
    [
      agent.rawValue,
      billingChannel.rawValue,
      channelSource.rawValue,
      model,
      contextBucket.rawValue,
      serviceTier,
      speed,
      inferenceGeo,
    ].joined(separator: "\u{0}")
  }

  var isValid: Bool {
    let counts = [
      inputTokens, cacheReadTokens, cacheWrite5mTokens, cacheWrite1hTokens,
      cacheWriteInferredTokens, outputTokens, reasoningTokens, requests, webSearchRequests,
      webFetchRequests, sourceCostCoveredRequests,
    ]
    guard WireValidation.isModel(model),
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

extension UsageRow {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "agent", "billingChannel", "channelSource", "model", "contextBucket", "serviceTier",
      "speed", "inferenceGeo", "inputTokens", "cacheReadTokens", "cacheWrite5MTokens",
      "cacheWrite1HTokens", "cacheWriteInferredTokens", "outputTokens", "reasoningTokens",
      "requests", "webSearchRequests", "webFetchRequests", "sourceCostMicrousd",
      "sourceCostCoveredRequests",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
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
    sourceCostCoveredRequests = try container.decode(
      Int.self, forKey: .sourceCostCoveredRequests)
  }
}

/// One scanned UTC hour and every row the scan found in it.
///
/// `scanVersion` orders the scans of one hour, so an upload replaces an hour only when it
/// carries a strictly newer reading of it. `partial` says the scan behind this hour came up
/// short, which the reads report.
struct UsageHour: Decodable, Equatable, Sendable {
  let bucketStartUTC: String
  let scanVersion: Int
  let partial: Bool
  let rows: [UsageRow]

  private enum CodingKeys: String, CodingKey {
    case bucketStartUTC = "bucketStartUtc"
    case scanVersion
    case partial
    case rows
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["bucketStartUtc", "scanVersion", "partial", "rows"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    bucketStartUTC = try container.decode(String.self, forKey: .bucketStartUTC)
    scanVersion = try container.decode(Int.self, forKey: .scanVersion)
    partial = try container.decode(Bool.self, forKey: .partial)
    rows = try container.decode([UsageRow].self, forKey: .rows)
    guard let bucket = Self.utcHour(bucketStartUTC),
      let earliest = Self.utcHour(QuotaProtocol.earliestUsageInstant),
      bucket >= earliest,
      (0...WireCodec.jsonSafeIntegerMaximum).contains(scanVersion),
      rows.count <= 512,
      rows.allSatisfy(\.isValid),
      Set(rows.map(\.identity)).count == rows.count
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .rows,
        in: container,
        debugDescription: "Invalid Usage hour."
      )
    }
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

/// One agent's rescanned hours. The device token names the device and its generation.
struct UsageUpload: Decodable, Equatable, Sendable {
  let protocolVersion: Int
  let generation: Int
  let agent: BillingAgent
  let hours: [UsageHour]

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case generation
    case agent
    case hours
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["protocolVersion", "generation", "agent", "hours"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    generation = try container.decode(Int.self, forKey: .generation)
    agent = try container.decode(BillingAgent.self, forKey: .agent)
    hours = try container.decode([UsageHour].self, forKey: .hours)

    guard protocolVersion == WireCodec.managedDataProtocolVersion,
      (1...WireCodec.jsonSafeIntegerMaximum).contains(generation),
      agent != .unknown,
      hours.count <= 256,
      Set(hours.map(\.bucketStartUTC)).count == hours.count,
      hours.allSatisfy({ hour in hour.rows.allSatisfy { $0.agent == agent } })
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .hours,
        in: container,
        debugDescription: "Invalid Usage upload."
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
    totals.isValid && cost.isValid && agents.count <= BillingAgent.allCases.count
      && agents.allSatisfy(\.isValid)
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
    guard let start = UsageHour.utcHour(startAt), let end = UsageHour.utcHour(endAt) else {
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
  let generatedAt: Date
  let aggregationTimezone: String?
  let range: UsageDateRange
  let status: LocalUsageReportStatus
  let modelCatalogRevision: String?
  let coverage: [LocalUsageCoverage]

  init(
    generatedAt: Date,
    aggregationTimezone: String?,
    range: UsageDateRange,
    status: LocalUsageReportStatus,
    modelCatalogRevision: String? = nil,
    coverage: [LocalUsageCoverage]
  ) {
    self.generatedAt = generatedAt
    self.aggregationTimezone = aggregationTimezone
    self.range = range
    self.status = status
    self.modelCatalogRevision = modelCatalogRevision
    self.coverage = coverage
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "generatedAt", "aggregationTimezone", "range", "status", "modelCatalogRevision", "coverage",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    generatedAt = try container.decode(Date.self, forKey: .generatedAt)
    aggregationTimezone = try container.decode(String?.self, forKey: .aggregationTimezone)
    range = try container.decode(UsageDateRange.self, forKey: .range)
    status = try container.decode(LocalUsageReportStatus.self, forKey: .status)
    modelCatalogRevision = try container.decode(String?.self, forKey: .modelCatalogRevision)
    coverage = try container.decode([LocalUsageCoverage].self, forKey: .coverage)

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
    guard range.isValid,
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
    try container.encode(generatedAt, forKey: .generatedAt)
    try container.encode(aggregationTimezone, forKey: .aggregationTimezone)
    try container.encode(range, forKey: .range)
    try container.encode(status, forKey: .status)
    try container.encode(modelCatalogRevision, forKey: .modelCatalogRevision)
    try container.encode(coverage, forKey: .coverage)
  }

  private enum CodingKeys: String, CodingKey {
    case generatedAt
    case aggregationTimezone
    case range
    case status
    case modelCatalogRevision
    case coverage
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

