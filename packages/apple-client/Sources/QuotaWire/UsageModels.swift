import Foundation

public enum BillingAgent: String, CaseIterable, Codable, Sendable {
  case codex
  case claudeCode = "claude_code"
  case grok
  case opencode
  case pi
  case cursor
}

public enum BillingChannel: String, Codable, Sendable {
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

public enum InferenceProvider: String, CaseIterable, Codable, Sendable {
  case openai
  case azureOpenAI = "azure_openai"
  case anthropic
  case awsBedrock = "aws_bedrock"
  case googleVertex = "google_vertex"
  case openrouter
  case xai
  case moonshot
  case deepseek
  case unknown

  public var displayName: String {
    switch self {
    case .openai: "OpenAI"
    case .azureOpenAI: "Azure OpenAI"
    case .anthropic: "Anthropic"
    case .awsBedrock: "AWS Bedrock"
    case .googleVertex: "Google Vertex AI"
    case .openrouter: "OpenRouter"
    case .xai: "xAI"
    case .moonshot: "Moonshot AI"
    case .deepseek: "DeepSeek"
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

public enum UsageCostAssumption: String, Codable, Sendable {
  case agentDefaultChannel = "agent_default_channel"
  case modelAlias = "model_alias"
  case wildcardServiceTier = "wildcard_service_tier"
  case wildcardSpeed = "wildcard_speed"
  case wildcardInferenceGeo = "wildcard_inference_geo"
  case wildcardContextBucket = "wildcard_context_bucket"
  case cacheWriteInferredRate = "cache_write_inferred_rate"
  case sourceReported = "source_reported"
}

public enum UsageUnpricedReason: String, Codable, Sendable {
  case unknownChannel = "unknown_channel"
  case unknownModel = "unknown_model"
  case outsideEffectiveRange = "outside_effective_range"
  case unsupportedDimensions = "unsupported_dimensions"
  case ambiguousPrice = "ambiguous_price"
  case missingRate = "missing_rate"
  case incompleteSourceCost = "incomplete_source_cost"
  case invalidCatalog = "invalid_catalog"
}

public enum CoverageStatus: String, Codable, Sendable {
  case complete
  case partial
}

public enum UsageBreakdownDimension: String, Codable, Sendable {
  case device
  case agent
  case model
  case billingChannel = "billing_channel"
  case usageDate = "usage_date"
  case bucketStartUTC = "bucket_start_utc"
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
    try decoder.rejectUnknownWireKeys(["billingChannel", "model", "reason", "rows"])
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
    try decoder.rejectUnknownWireKeys([
      "mode", "basis", "status", "amountMicrousd", "catalogRevision", "calculatedRows",
      "reportedRows", "unpricedRows", "assumptions", "unpriced", "unpricedTruncated",
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

public struct UsageTokenTotals: Codable, Equatable, Sendable {
  public let inputTokens: Int
  public let cacheReadTokens: Int
  public let cacheWrite5mTokens: Int
  public let cacheWrite1hTokens: Int
  public let cacheWriteInferredTokens: Int
  public let outputTokens: Int
  public let reasoningTokens: Int
  public let requests: Int
  public let webSearchRequests: Int
  public let webFetchRequests: Int
  public let sourceCostMicrousd: String?
  public let sourceCostCoveredRequests: Int

  public init(
    inputTokens: Int,
    cacheReadTokens: Int,
    cacheWrite5mTokens: Int,
    cacheWrite1hTokens: Int,
    cacheWriteInferredTokens: Int,
    outputTokens: Int,
    reasoningTokens: Int,
    requests: Int,
    webSearchRequests: Int,
    webFetchRequests: Int,
    sourceCostMicrousd: String?,
    sourceCostCoveredRequests: Int
  ) {
    self.inputTokens = inputTokens
    self.cacheReadTokens = cacheReadTokens
    self.cacheWrite5mTokens = cacheWrite5mTokens
    self.cacheWrite1hTokens = cacheWrite1hTokens
    self.cacheWriteInferredTokens = cacheWriteInferredTokens
    self.outputTokens = outputTokens
    self.reasoningTokens = reasoningTokens
    self.requests = requests
    self.webSearchRequests = webSearchRequests
    self.webFetchRequests = webFetchRequests
    self.sourceCostMicrousd = sourceCostMicrousd
    self.sourceCostCoveredRequests = sourceCostCoveredRequests
  }

  public init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "inputTokens", "cacheReadTokens", "cacheWrite5MTokens", "cacheWrite1HTokens",
      "cacheWriteInferredTokens", "outputTokens", "reasoningTokens", "requests",
      "webSearchRequests", "webFetchRequests", "sourceCostMicrousd", "sourceCostCoveredRequests",
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

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(inputTokens, forKey: .inputTokens)
    try container.encode(cacheReadTokens, forKey: .cacheReadTokens)
    try container.encode(cacheWrite5mTokens, forKey: .cacheWrite5mTokens)
    try container.encode(cacheWrite1hTokens, forKey: .cacheWrite1hTokens)
    try container.encode(cacheWriteInferredTokens, forKey: .cacheWriteInferredTokens)
    try container.encode(outputTokens, forKey: .outputTokens)
    try container.encode(reasoningTokens, forKey: .reasoningTokens)
    try container.encode(requests, forKey: .requests)
    try container.encode(webSearchRequests, forKey: .webSearchRequests)
    try container.encode(webFetchRequests, forKey: .webFetchRequests)
    try container.encode(sourceCostMicrousd, forKey: .sourceCostMicrousd)
    try container.encode(sourceCostCoveredRequests, forKey: .sourceCostCoveredRequests)
  }

  public var isValid: Bool {
    let counts = [
      inputTokens, cacheReadTokens, cacheWrite5mTokens, cacheWrite1hTokens,
      cacheWriteInferredTokens, outputTokens, reasoningTokens, requests, webSearchRequests,
      webFetchRequests, sourceCostCoveredRequests,
    ]
    guard counts.allSatisfy(WireValidation.isSafeNonnegative),
      let classifiedInput = WireValidation.safeSum([
        cacheReadTokens, cacheWrite5mTokens, cacheWrite1hTokens, cacheWriteInferredTokens,
      ])
    else { return false }
    let hasSourceCost = sourceCostMicrousd != nil
    return classifiedInput <= inputTokens
      && reasoningTokens <= outputTokens
      && sourceCostCoveredRequests <= requests
      && (requests > 0 || (webSearchRequests == 0 && webFetchRequests == 0))
      && hasSourceCost == (sourceCostCoveredRequests > 0)
      && (sourceCostMicrousd.map(WireValidation.isNonnegativeInteger) ?? true)
  }

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
    try decoder.rejectUnknownWireKeys([
      "totalTokens", "inputTokens", "outputTokens", "cacheReadInputTokens",
      "cacheWriteInputTokens", "reasoningTokens", "messages",
    ])
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
    try decoder.rejectUnknownWireKeys(["model", "totals", "cost"])
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
    try decoder.rejectUnknownWireKeys(["provider", "totals", "cost", "models"])
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
    try decoder.rejectUnknownWireKeys(["agent", "totals", "cost", "providers"])
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

public struct UsageBreakdown: Codable, Equatable, Sendable {
  public let dimension: UsageBreakdownDimension
  public let key: String
  public let totals: UsageTokenTotals
  public let cost: UsageCostOutcome

  public init(
    dimension: UsageBreakdownDimension,
    key: String,
    totals: UsageTokenTotals,
    cost: UsageCostOutcome
  ) {
    self.dimension = dimension
    self.key = key
    self.totals = totals
    self.cost = cost
  }

  public init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["dimension", "key", "totals", "cost"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    dimension = try container.decode(UsageBreakdownDimension.self, forKey: .dimension)
    key = try container.decode(String.self, forKey: .key)
    totals = try container.decode(UsageTokenTotals.self, forKey: .totals)
    cost = try container.decode(UsageCostOutcome.self, forKey: .cost)
    let keyValid =
      dimension == .model
      ? WireValidation.isModel(key)
      : (!key.isEmpty && key.utf8.count <= 128
        && key.trimmingCharacters(in: .whitespacesAndNewlines) == key)
    guard keyValid, totals.isValid, cost.isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .key,
        in: container,
        debugDescription: "Invalid Usage breakdown key or totals."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case dimension
    case key
    case totals
    case cost
  }
}

/// How completely a read's range was scanned.  Readers have only ever asked whether anything
/// was missed, so the answer travels instead of the windows it was derived from.
public enum UsageCoverageVerdict: String, Codable, Equatable, Sendable {
  case none
  case complete
  case partial
}

public struct UsageDateRange: Codable, Equatable, Sendable {
  public let from: String
  public let to: String

  public init(from: String, to: String) {
    self.from = from
    self.to = to
  }

  public init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["from", "to"])
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

public struct AccountUsageSummary: Codable, Equatable, Sendable {
  public let range: UsageDateRange
  public let totals: UsageTokenTotals
  public let cost: UsageCostOutcome
  public let modelCatalogRevision: String?
  public let coverage: UsageCoverageVerdict
  public let breakdowns: [UsageBreakdown]
  public let agents: [LocalUsageAgentSummary]?
  public let breakdownsTruncated: Bool?

  public init(
    range: UsageDateRange,
    totals: UsageTokenTotals,
    cost: UsageCostOutcome,
    modelCatalogRevision: String? = nil,
    coverage: UsageCoverageVerdict,
    breakdowns: [UsageBreakdown],
    agents: [LocalUsageAgentSummary]? = nil,
    breakdownsTruncated: Bool? = nil
  ) {
    self.range = range
    self.totals = totals
    self.cost = cost
    self.modelCatalogRevision = modelCatalogRevision
    self.coverage = coverage
    self.breakdowns = breakdowns
    self.agents = agents
    self.breakdownsTruncated = breakdownsTruncated
  }

  public init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "range", "totals", "cost", "modelCatalogRevision", "coverage", "breakdowns", "agents",
      "breakdownsTruncated",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    range = try container.decode(UsageDateRange.self, forKey: .range)
    totals = try container.decode(UsageTokenTotals.self, forKey: .totals)
    cost = try container.decode(UsageCostOutcome.self, forKey: .cost)
    modelCatalogRevision = try container.decodeIfPresent(String.self, forKey: .modelCatalogRevision)
    coverage = try container.decode(UsageCoverageVerdict.self, forKey: .coverage)
    breakdowns = try container.decode([UsageBreakdown].self, forKey: .breakdowns)
    agents = try container.decodeIfPresent([LocalUsageAgentSummary].self, forKey: .agents)
    breakdownsTruncated = try decodeTrueMarker(.breakdownsTruncated, from: container)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .range,
        in: container,
        debugDescription: "Invalid account Usage summary."
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(range, forKey: .range)
    try container.encode(totals, forKey: .totals)
    try container.encode(cost, forKey: .cost)
    try container.encodeIfPresent(modelCatalogRevision, forKey: .modelCatalogRevision)
    try container.encode(coverage, forKey: .coverage)
    try container.encode(breakdowns, forKey: .breakdowns)
    try container.encodeIfPresent(agents, forKey: .agents)
    try container.encodeIfPresent(breakdownsTruncated, forKey: .breakdownsTruncated)
  }

  public var hasTruncatedDetails: Bool {
    breakdownsTruncated == true || cost.hasUnpricedTruncatedDetails
  }

  public var isValid: Bool {
    range.isValid
      && totals.isValid
      && cost.isValid
      && modelCatalogRevision.map(WireValidation.isOpaqueID) != false
      && breakdowns.count <= 1_000
      && agents.map { $0.count <= BillingAgent.allCases.count } != false
  }

  private enum CodingKeys: String, CodingKey {
    case range
    case totals
    case cost
    case modelCatalogRevision
    case coverage
    case breakdowns
    case agents
    case breakdownsTruncated
  }
}
