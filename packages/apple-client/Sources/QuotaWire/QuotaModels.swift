import Foundation
import QuotaPresentation

public enum QuotaStatus: String, Codable, Sendable {
  case available
  case stale
  case authRequired = "auth_required"
  case unavailable
  case unsupported
  case error
}

public enum FingerprintScope: String, Codable, Sendable {
  case global
  case source
}

public enum QuotaValueUnit: String, Codable, Equatable, Sendable {
  case usd
  case credits
  case count
}

public struct QuotaAccount: Codable, Equatable, Sendable {
  public let fingerprint: String
  public let label: String?
  public let plan: String?
  public let fingerprintScope: FingerprintScope

  public init(
    fingerprint: String,
    label: String? = nil,
    plan: String? = nil,
    fingerprintScope: FingerprintScope
  ) {
    self.fingerprint = fingerprint
    self.label = label
    self.plan = plan
    self.fingerprintScope = fingerprintScope
  }

  public init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["fingerprint", "label", "plan", "fingerprintScope"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    fingerprint = try container.decode(String.self, forKey: .fingerprint)
    label = try container.decodeIfPresent(String.self, forKey: .label)
    plan = try container.decodeIfPresent(String.self, forKey: .plan)
    fingerprintScope = try container.decode(FingerprintScope.self, forKey: .fingerprintScope)
    guard WireValidation.isOpaqueID(fingerprint),
      label.map({ WireValidation.isTrimmedText($0, maximum: 128) }) ?? true,
      plan.map({ WireValidation.isTrimmedText($0, maximum: 64) }) ?? true
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .fingerprint,
        in: container,
        debugDescription: "Invalid quota account."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case fingerprint
    case label
    case plan
    case fingerprintScope
  }
}

public struct QuotaWindow: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let usedPercent: Double
  public let resetsAt: Date?
  public let durationSeconds: Int?
  public let remainingValue: Double?
  public let limitValue: Double?
  public let valueUnit: QuotaValueUnit?

  public init(
    id: String,
    title: String,
    usedPercent: Double,
    resetsAt: Date? = nil,
    durationSeconds: Int? = nil,
    remainingValue: Double? = nil,
    limitValue: Double? = nil,
    valueUnit: QuotaValueUnit? = nil
  ) {
    self.id = id
    self.title = title
    self.usedPercent = usedPercent
    self.resetsAt = resetsAt
    self.durationSeconds = durationSeconds
    self.remainingValue = remainingValue
    self.limitValue = limitValue
    self.valueUnit = valueUnit
  }

  public init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "id", "title", "usedPercent", "resetsAt", "durationSeconds", "remainingValue", "limitValue",
      "valueUnit",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    usedPercent = try container.decode(Double.self, forKey: .usedPercent)
    resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
    durationSeconds = try container.decodeIfPresent(Int.self, forKey: .durationSeconds)
    remainingValue = try container.decodeIfPresent(Double.self, forKey: .remainingValue)
    limitValue = try container.decodeIfPresent(Double.self, forKey: .limitValue)
    valueUnit = try container.decodeIfPresent(QuotaValueUnit.self, forKey: .valueUnit)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .id,
        in: container,
        debugDescription: "Invalid quota window."
      )
    }
  }

  var isValid: Bool {
    WireValidation.isBillingDimension(id)
      && WireValidation.isTrimmedText(title, maximum: 128)
      && usedPercent.isFinite
      && (0...100).contains(usedPercent)
      && (durationSeconds.map { WireValidation.isSafeNonnegative($0) } ?? true)
      && (remainingValue?.isFinite ?? true)
      && (limitValue.map { $0.isFinite && $0 >= 0 } ?? true)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case usedPercent
    case resetsAt
    case durationSeconds
    case remainingValue
    case limitValue
    case valueUnit
  }
}

public struct QuotaSnapshot: Codable, Equatable, Sendable {
  public let provider: ProviderID
  public let account: QuotaAccount
  public let windows: [QuotaWindow]
  public let status: QuotaStatus
  public let observedAt: Date

  public init(
    provider: ProviderID,
    account: QuotaAccount,
    windows: [QuotaWindow],
    status: QuotaStatus,
    observedAt: Date
  ) {
    self.provider = provider
    self.account = account
    self.windows = windows
    self.status = status
    self.observedAt = observedAt
  }

  public init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "provider", "account", "windows", "status", "observedAt",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(ProviderID.self, forKey: .provider)
    account = try container.decode(QuotaAccount.self, forKey: .account)
    windows = try container.decode([QuotaWindow].self, forKey: .windows)
    status = try container.decode(QuotaStatus.self, forKey: .status)
    observedAt = try container.decode(Date.self, forKey: .observedAt)
    guard windows.count <= 16, windows.allSatisfy(\.isValid)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .windows,
        in: container,
        debugDescription: "Invalid quota snapshot."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case provider
    case account
    case windows
    case status
    case observedAt
  }
}

extension QuotaSnapshot: QuotaObservationFreshness {
  public var reportedState: QuotaObservationState { status.observationState }

  public var validUntil: Date? {
    QuotaObservationValidity.validUntil(
      observedAt: observedAt,
      windows: windows.lazy.map {
        QuotaObservationWindow(resetsAt: $0.resetsAt, durationSeconds: $0.durationSeconds)
      }
    )
  }
}

extension QuotaStatus {
  public var observationState: QuotaObservationState {
    switch self {
    case .available: .available
    case .stale: .stale
    case .authRequired: .signInNeeded
    case .unavailable: .unavailable
    case .unsupported: .unsupported
    case .error: .failed
    }
  }
}

// Derivations both Apple products need from a window. The rules live in QuotaPresentation;
// these name them on the type so neither app restates them.
extension QuotaValueUnit {
  public var remainingUnit: RemainingQuotaUnit {
    switch self {
    case .usd: .usd
    case .credits: .credits
    case .count: .count
    }
  }
}

extension QuotaWindow {
  public var remainingPercent: Double {
    RemainingQuotaFormat.remainingPercent(usedPercent: usedPercent)
  }

  /// Wallet-style window: absolute remaining only, no budget/limit ratio.
  public var isBalanceOnly: Bool {
    RemainingQuotaFormat.isBalanceOnly(remainingValue: remainingValue, hasLimit: limitValue != nil)
  }

  /// Rate-limit / budget meters need a percent bar. Balance-only wallets do not.
  public var showsPercentMeter: Bool {
    RemainingQuotaFormat.showsPercentMeter(
      remainingValue: remainingValue,
      hasLimit: limitValue != nil
    )
  }
}
