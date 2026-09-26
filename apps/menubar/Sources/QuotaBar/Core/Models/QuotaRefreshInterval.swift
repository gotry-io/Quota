import QuotaWire

/// Fixed Quota collection cadences. Account summary still polls every minute regardless.
enum QuotaRefreshInterval: Int, CaseIterable, Identifiable {
  case oneMinute = 60
  case twoMinutes = 120
  case fiveMinutes = 300
  case tenMinutes = 600
  case fifteenMinutes = 900

  var id: Int { rawValue }

  static let fallback = QuotaRefreshInterval.fiveMinutes

  var label: String {
    switch self {
    case .oneMinute: "1 minute"
    case .twoMinutes: "2 minutes"
    case .fiveMinutes: "5 minutes"
    case .tenMinutes: "10 minutes"
    case .fifteenMinutes: "15 minutes"
    }
  }

  static func resolved(_ seconds: Int) -> QuotaRefreshInterval {
    QuotaRefreshInterval(rawValue: seconds) ?? .fallback
  }
}

/// How the helper paces collection: each provider on its own tier, or one fixed interval.
enum QuotaRefreshMode: String, Decodable, Sendable {
  case automatic
  case fixed
}

/// The Refresh Interval picker's choices: Automatic first, then the fixed cadences.
enum QuotaRefreshChoice: Hashable, Identifiable {
  case automatic
  case fixed(QuotaRefreshInterval)

  static let allCases: [QuotaRefreshChoice] =
    [.automatic] + QuotaRefreshInterval.allCases.map(Self.fixed)

  var id: Int {
    switch self {
    case .automatic: 0
    case .fixed(let interval): interval.rawValue
    }
  }

  var label: String {
    switch self {
    case .automatic: "Automatic"
    case .fixed(let interval): interval.label
    }
  }

  init(mode: QuotaRefreshMode, intervalSeconds: Int) {
    switch mode {
    case .automatic: self = .automatic
    case .fixed: self = .fixed(QuotaRefreshInterval.resolved(intervalSeconds))
    }
  }
}

/// What Automatic is doing now, as the helper judged it.
struct LocalServiceQuotaRefreshTier: Decodable, Equatable, Sendable {
  enum Tier: String, Decodable, Sendable {
    case active
    case normal
    case idle
  }

  enum Reason: String, Decodable, Sendable {
    case agentActive = "agent_active"
    case lowRemaining = "low_remaining"
  }

  let tier: Tier
  let intervalSeconds: Int
  let provider: ProviderID
  let reason: Reason?

  private enum CodingKeys: String, CodingKey {
    case tier
    case intervalSeconds
    case provider
    case reason
  }

  init(tier: Tier, intervalSeconds: Int, provider: ProviderID, reason: Reason? = nil) {
    self.tier = tier
    self.intervalSeconds = intervalSeconds
    self.provider = provider
    self.reason = reason
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["tier", "intervalSeconds", "provider", "reason"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    tier = try container.decode(Tier.self, forKey: .tier)
    intervalSeconds = try container.decode(Int.self, forKey: .intervalSeconds)
    provider = try container.decode(ProviderID.self, forKey: .provider)
    reason = try container.decodeIfPresent(Reason.self, forKey: .reason)
  }

  /// The line under Refresh Interval: **Automatic · every 1 min while Codex is active**.
  var hint: String {
    let minutes = max(1, intervalSeconds / 60)
    let every = "Automatic · every \(minutes) min"
    switch (tier, reason) {
    case (.active, .lowRemaining): return "\(every) while \(provider.displayName) is running low"
    case (.active, _): return "\(every) while \(provider.displayName) is active"
    case (.idle, _): return "\(every) while idle"
    case (.normal, _): return every
    }
  }
}
