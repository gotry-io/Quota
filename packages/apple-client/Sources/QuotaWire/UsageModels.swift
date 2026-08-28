import Foundation
import QuotaPresentation

public enum BillingAgent: String, CaseIterable, Codable, Sendable, TolerantWireEnum {
  case codex
  case claudeCode = "claude_code"
  case grok
  case opencode
  case pi
  case cursor
  case unknown
}

public enum BillingChannel: String, Codable, Sendable, TolerantWireEnum {
  case openaiDirect = "openai_direct"
  case azureOpenAI = "azure_openai"
  case anthropicDirect = "anthropic_direct"
  case awsBedrock = "aws_bedrock"
  case googleVertex = "google_vertex"
  case openrouter
  case xaiDirect = "xai_direct"
  case moonshotDirect = "moonshot_direct"
  case deepseekDirect = "deepseek_direct"
  case unknown
}

/// The company whose model answered, which is what a Usage summary groups by.
///
/// The service resolves it from the model's name; a gateway that merely billed the request is
/// never a group of its own.
public enum InferenceProvider: String, CaseIterable, Codable, Sendable, TolerantWireEnum {
  case openai
  case anthropic
  case google
  case xai
  case moonshot
  case deepseek
  case cursor
  case unknown

  public var displayName: String {
    switch self {
    case .openai: "OpenAI"
    case .anthropic: "Anthropic"
    case .google: "Google"
    case .xai: "xAI"
    case .moonshot: "Moonshot AI"
    case .deepseek: "DeepSeek"
    case .cursor: "Cursor"
    case .unknown: "Unknown Provider"
    }
  }
}

public enum UsageCostMode: String, Codable, Sendable {
  case calculate
  case auto
  case reported
}

public enum UsageCostBasis: String, Codable, Sendable {
  case calculated
  case reported
  case mixed
  case none
}

public enum UsageCostStatus: String, Codable, Sendable {
  case complete
  case partial
  case unavailable
}

extension UsageCostCoverage {
  /// How the presentation layer reads a cost outcome's status. Every Apple surface formats the
  /// same cost the same way, so the wire member is translated once, beside the type it belongs to.
  public init(_ status: UsageCostStatus) {
    switch status {
    case .complete: self = .complete
    case .partial: self = .partial
    case .unavailable: self = .unavailable
    }
  }
}

public enum UsageCostAssumption: String, Codable, Sendable, TolerantWireEnum {
  case agentDefaultChannel = "agent_default_channel"
  case modelAlias = "model_alias"
  case wildcardServiceTier = "wildcard_service_tier"
  case wildcardSpeed = "wildcard_speed"
  case wildcardInferenceGeo = "wildcard_inference_geo"
  case wildcardContextBucket = "wildcard_context_bucket"
  case cacheWriteInferredRate = "cache_write_inferred_rate"
  case sourceReported = "source_reported"
  case unknown
}

public enum UsageUnpricedReason: String, Codable, Sendable, TolerantWireEnum {
  case unknownChannel = "unknown_channel"
  case unknownModel = "unknown_model"
  case outsideEffectiveRange = "outside_effective_range"
  case unsupportedDimensions = "unsupported_dimensions"
  case ambiguousPrice = "ambiguous_price"
  case missingRate = "missing_rate"
  case incompleteSourceCost = "incomplete_source_cost"
  case invalidCatalog = "invalid_catalog"
  case unknown
}

public enum CoverageStatus: String, Codable, Sendable {
  case complete
  case partial
}

public struct UsageUnpricedItem: Codable, Equatable, Sendable {
  public let billingChannel: BillingChannel
  public let model: String
  public let reason: UsageUnpricedReason
  public let rows: Int

  public init(billingChannel: BillingChannel, model: String, reason: UsageUnpricedReason, rows: Int)
  {
    self.billingChannel = billingChannel
    self.model = model
    self.reason = reason
    self.rows = rows
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    billingChannel = try container.decode(BillingChannel.self, forKey: .billingChannel)
    model = try container.decode(String.self, forKey: .model)
    reason = try container.decode(UsageUnpricedReason.self, forKey: .reason)
    rows = try container.decode(Int.self, forKey: .rows)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .model,
        in: container,
        debugDescription: "Invalid unpriced item."
      )
    }
  }

  public var isValid: Bool {
    WireValidation.isModel(model) && WireValidation.isSafePositive(rows)
  }

  private enum CodingKeys: String, CodingKey {
    case billingChannel
    case model
    case reason
    case rows
  }
}

public struct UsageCostOutcome: Codable, Equatable, Sendable {
  public let mode: UsageCostMode
  public let basis: UsageCostBasis
  public let status: UsageCostStatus
  public let amountMicrousd: String?
  public let catalogRevision: String?
  public let calculatedRows: Int
  public let reportedRows: Int
  public let unpricedRows: Int
  public let assumptions: [UsageCostAssumption]
  public let unpriced: [UsageUnpricedItem]
  public let unpricedTruncated: Bool?

  public init(
    mode: UsageCostMode,
    basis: UsageCostBasis,
    status: UsageCostStatus,
    amountMicrousd: String?,
    catalogRevision: String?,
    calculatedRows: Int,
    reportedRows: Int,
    unpricedRows: Int,
    assumptions: [UsageCostAssumption],
    unpriced: [UsageUnpricedItem],
    unpricedTruncated: Bool? = nil
  ) {
    self.mode = mode
    self.basis = basis
    self.status = status
    self.amountMicrousd = amountMicrousd
    self.catalogRevision = catalogRevision
    self.calculatedRows = calculatedRows
    self.reportedRows = reportedRows
    self.unpricedRows = unpricedRows
    self.assumptions = assumptions
    self.unpriced = unpriced
    self.unpricedTruncated = unpricedTruncated
  }

  public init(from decoder: Decoder) throws {
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
    unpricedTruncated = try decodeTrueMarker(.unpricedTruncated, from: container)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .status,
        in: container,
        debugDescription: "Invalid Usage cost outcome."
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(mode, forKey: .mode)
    try container.encode(basis, forKey: .basis)
    try container.encode(status, forKey: .status)
    try container.encode(amountMicrousd, forKey: .amountMicrousd)
    try container.encode(catalogRevision, forKey: .catalogRevision)
    try container.encode(calculatedRows, forKey: .calculatedRows)
    try container.encode(reportedRows, forKey: .reportedRows)
    try container.encode(unpricedRows, forKey: .unpricedRows)
    try container.encode(assumptions, forKey: .assumptions)
    try container.encode(unpriced, forKey: .unpriced)
    try container.encodeIfPresent(unpricedTruncated, forKey: .unpricedTruncated)
  }

  public var hasUnpricedTruncatedDetails: Bool { unpricedTruncated == true }

  public var isValid: Bool {
    let rowCounts = [calculatedRows, reportedRows, unpricedRows]
    guard rowCounts.allSatisfy(WireValidation.isSafeNonnegative),
      assumptions.count <= 16,
      Set(assumptions.map(\.rawValue)).count == assumptions.count,
      unpriced.count <= 100,
      unpriced.allSatisfy(\.isValid),
      amountMicrousd.map(WireValidation.isNonnegativeInteger) ?? true,
      catalogRevision.map(WireValidation.isOpaqueID) ?? true,
      let pricedRows = WireValidation.safeSum([calculatedRows, reportedRows]),
      let itemRows = WireValidation.safeSum(unpriced.map(\.rows)),
      unpricedTruncated != false,
      itemRows <= unpricedRows,
      unpricedTruncated == true || itemRows == unpricedRows
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
  }

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
    case unpricedTruncated
  }
}

public struct UsageSummaryTotals: Codable, Equatable, Sendable {
  public let totalTokens: Int
  public let inputTokens: Int
  public let outputTokens: Int
  public let cacheReadInputTokens: Int
  public let cacheWriteInputTokens: Int
  public let reasoningTokens: Int
  public let messages: Int

  public init(
    totalTokens: Int,
    inputTokens: Int,
    outputTokens: Int,
    cacheReadInputTokens: Int,
    cacheWriteInputTokens: Int,
    reasoningTokens: Int,
    messages: Int
  ) {
    self.totalTokens = totalTokens
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cacheReadInputTokens = cacheReadInputTokens
    self.cacheWriteInputTokens = cacheWriteInputTokens
    self.reasoningTokens = reasoningTokens
    self.messages = messages
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    totalTokens = try container.decode(Int.self, forKey: .totalTokens)
    inputTokens = try container.decode(Int.self, forKey: .inputTokens)
    outputTokens = try container.decode(Int.self, forKey: .outputTokens)
    cacheReadInputTokens = try container.decode(Int.self, forKey: .cacheReadInputTokens)
    cacheWriteInputTokens = try container.decode(Int.self, forKey: .cacheWriteInputTokens)
    reasoningTokens = try container.decode(Int.self, forKey: .reasoningTokens)
    messages = try container.decode(Int.self, forKey: .messages)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .totalTokens,
        in: container,
        debugDescription: "Invalid Usage summary totals."
      )
    }
  }

  public var isValid: Bool {
    let counts = [
      totalTokens, inputTokens, outputTokens, cacheReadInputTokens, cacheWriteInputTokens,
      reasoningTokens, messages,
    ]
    return counts.allSatisfy(WireValidation.isSafeNonnegative)
      && WireValidation.safeSum([inputTokens, outputTokens]) == totalTokens
      && WireValidation.safeSum([cacheReadInputTokens, cacheWriteInputTokens]).map {
        $0 <= inputTokens
      } == true
      && reasoningTokens <= outputTokens
  }
}

public struct LocalUsageModelSummary: Codable, Equatable, Sendable {
  public let model: String
  public let totals: UsageSummaryTotals
  public let cost: UsageCostOutcome

  public init(model: String, totals: UsageSummaryTotals, cost: UsageCostOutcome) {
    self.model = model
    self.totals = totals
    self.cost = cost
  }

  public var isValid: Bool {
    WireValidation.isModel(model) && totals.isValid && cost.isValid
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    model = try container.decode(String.self, forKey: .model)
    totals = try container.decode(UsageSummaryTotals.self, forKey: .totals)
    cost = try container.decode(UsageCostOutcome.self, forKey: .cost)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .model,
        in: container,
        debugDescription: "Invalid local Usage model summary."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case model
    case totals
    case cost
  }
}

public struct LocalUsageProviderSummary: Codable, Equatable, Sendable {
  public let provider: InferenceProvider
  public let totals: UsageSummaryTotals
  public let cost: UsageCostOutcome
  public let models: [LocalUsageModelSummary]

  public init(
    provider: InferenceProvider,
    totals: UsageSummaryTotals,
    cost: UsageCostOutcome,
    models: [LocalUsageModelSummary]
  ) {
    self.provider = provider
    self.totals = totals
    self.cost = cost
    self.models = models
  }

  public var isValid: Bool {
    totals.isValid && cost.isValid && models.count <= 1_000 && models.allSatisfy(\.isValid)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(InferenceProvider.self, forKey: .provider)
    totals = try container.decode(UsageSummaryTotals.self, forKey: .totals)
    cost = try container.decode(UsageCostOutcome.self, forKey: .cost)
    models = try container.decode([LocalUsageModelSummary].self, forKey: .models)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .provider,
        in: container,
        debugDescription: "Invalid local Usage provider summary."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case provider
    case totals
    case cost
    case models
  }
}

public struct LocalUsageAgentSummary: Codable, Equatable, Sendable {
  public let agent: BillingAgent
  public let totals: UsageSummaryTotals
  public let cost: UsageCostOutcome
  public let providers: [LocalUsageProviderSummary]

  public init(
    agent: BillingAgent,
    totals: UsageSummaryTotals,
    cost: UsageCostOutcome,
    providers: [LocalUsageProviderSummary]
  ) {
    self.agent = agent
    self.totals = totals
    self.cost = cost
    self.providers = providers
  }

  public var isValid: Bool {
    totals.isValid && cost.isValid && providers.count <= InferenceProvider.allCases.count
      && providers.allSatisfy(\.isValid)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    agent = try container.decode(BillingAgent.self, forKey: .agent)
    totals = try container.decode(UsageSummaryTotals.self, forKey: .totals)
    cost = try container.decode(UsageCostOutcome.self, forKey: .cost)
    providers = try container.decode([LocalUsageProviderSummary].self, forKey: .providers)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .agent,
        in: container,
        debugDescription: "Invalid local Usage client summary."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case agent
    case totals
    case cost
    case providers
  }
}

/// A range of calendar dates. `to` names the last day it covers, inclusive.
public struct UsageDateRange: Codable, Equatable, Sendable {
  public let from: String
  public let to: String

  public init(from: String, to: String) {
    self.from = from
    self.to = to
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    from = try container.decode(String.self, forKey: .from)
    to = try container.decode(String.self, forKey: .to)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .to,
        in: container,
        debugDescription: "Invalid usage date range."
      )
    }
  }

  public var isValid: Bool {
    WireValidation.isCalendarDate(from) && WireValidation.isCalendarDate(to) && from <= to
  }

  private enum CodingKeys: String, CodingKey {
    case from
    case to
  }
}

/// One model's share of a period. Totals and cost live at the leaf and at the period.
public struct UsageModelUsage: Codable, Equatable, Sendable {
  public let model: String
  public let totals: UsageSummaryTotals
  public let cost: UsageCostOutcome

  public init(model: String, totals: UsageSummaryTotals, cost: UsageCostOutcome) {
    self.model = model
    self.totals = totals
    self.cost = cost
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    model = try container.decode(String.self, forKey: .model)
    totals = try container.decode(UsageSummaryTotals.self, forKey: .totals)
    cost = try container.decode(UsageCostOutcome.self, forKey: .cost)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .model,
        in: container,
        debugDescription: "Invalid Usage model."
      )
    }
  }

  public var isValid: Bool {
    WireValidation.isModel(model) && totals.isValid && cost.isValid
  }

  private enum CodingKeys: String, CodingKey {
    case model
    case totals
    case cost
  }
}

public struct UsageProviderUsage: Codable, Equatable, Sendable {
  public let provider: InferenceProvider
  public let models: [UsageModelUsage]

  public init(provider: InferenceProvider, models: [UsageModelUsage]) {
    self.provider = provider
    self.models = models
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(InferenceProvider.self, forKey: .provider)
    models = try container.decode([UsageModelUsage].self, forKey: .models)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .provider,
        in: container,
        debugDescription: "Invalid Usage provider."
      )
    }
  }

  public var isValid: Bool { models.count <= 200 && models.allSatisfy(\.isValid) }

  private enum CodingKeys: String, CodingKey {
    case provider
    case models
  }
}

public struct UsageAgentUsage: Codable, Equatable, Sendable {
  public let agent: BillingAgent
  public let providers: [UsageProviderUsage]

  public init(agent: BillingAgent, providers: [UsageProviderUsage]) {
    self.agent = agent
    self.providers = providers
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    agent = try container.decode(BillingAgent.self, forKey: .agent)
    providers = try container.decode([UsageProviderUsage].self, forKey: .providers)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .agent,
        in: container,
        debugDescription: "Invalid Usage agent."
      )
    }
  }

  /// Bounded by the wire's leaf cap, not by the vocabulary this build knows: a vendor a newer
  /// Relay names is read as `.unknown`, not refused along with the whole summary.
  public var isValid: Bool {
    providers.count <= 200 && providers.allSatisfy(\.isValid)
  }

  private enum CodingKeys: String, CodingKey {
    case agent
    case providers
  }
}

/// One period of Usage: its totals, its cost, whether any hour behind it was scanned
/// incompletely, and the agent tree that makes up the difference.
public struct UsagePeriod: Codable, Equatable, Sendable {
  public let totals: UsageSummaryTotals
  public let cost: UsageCostOutcome
  public let partial: Bool
  public let agents: [UsageAgentUsage]

  public init(
    totals: UsageSummaryTotals,
    cost: UsageCostOutcome,
    partial: Bool,
    agents: [UsageAgentUsage]
  ) {
    self.totals = totals
    self.cost = cost
    self.partial = partial
    self.agents = agents
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    totals = try container.decode(UsageSummaryTotals.self, forKey: .totals)
    cost = try container.decode(UsageCostOutcome.self, forKey: .cost)
    partial = try container.decode(Bool.self, forKey: .partial)
    agents = try container.decode([UsageAgentUsage].self, forKey: .agents)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .totals,
        in: container,
        debugDescription: "Invalid Usage period."
      )
    }
  }

  public var isValid: Bool {
    totals.isValid && cost.isValid && agents.count <= BillingAgent.allCases.count
      && agents.allSatisfy(\.isValid)
  }

  public var hasTruncatedDetails: Bool { cost.hasUnpricedTruncatedDetails }

  private enum CodingKeys: String, CodingKey {
    case totals
    case cost
    case partial
    case agents
  }
}

/// The four periods an Account read answers.
///
/// `all` is every retained UTC day. The three trailing periods are exact in the timezone a caller
/// names: a local day begins at local midnight, so they are bounded by instants rather than by
/// UTC dates.
public struct AccountUsage: Codable, Equatable, Sendable {
  public let today: UsagePeriod
  public let last7Days: UsagePeriod
  public let last30Days: UsagePeriod
  public let all: UsagePeriod

  public init(
    today: UsagePeriod,
    last7Days: UsagePeriod,
    last30Days: UsagePeriod,
    all: UsagePeriod
  ) {
    self.today = today
    self.last7Days = last7Days
    self.last30Days = last30Days
    self.all = all
  }

  public var isValid: Bool {
    [today, last7Days, last30Days, all].allSatisfy(\.isValid)
  }

  private enum CodingKeys: String, CodingKey {
    case today
    case last7Days
    case last30Days
    case all
  }
}
