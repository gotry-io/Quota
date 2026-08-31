import Foundation
import QuotaPresentation

public enum QuotaStatus: String, Codable, Sendable, TolerantWireEnum {
  case available
  case stale
  case authRequired = "auth_required"
  case unavailable
  case unsupported
  case error
  case unknown
}

public enum FingerprintScope: String, Codable, Sendable, TolerantWireEnum {
  case global
  case source
  case unknown
}

public enum QuotaValueUnit: String, Codable, Equatable, Sendable, TolerantWireEnum {
  case usd
  case credits
  case count
  case unknown
}

public enum PrimaryCadence: String, Codable, Equatable, Sendable, TolerantWireEnum {
  case fiveHour = "five_hour"
  case weekly
  case monthly
  case unknown
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
  public let primaryCadence: PrimaryCadence?
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
    valueUnit: QuotaValueUnit? = nil,
    primaryCadence: PrimaryCadence? = nil
  ) {
    self.id = id
    self.title = title
    self.usedPercent = usedPercent
    self.resetsAt = resetsAt
    self.durationSeconds = durationSeconds
    self.primaryCadence = primaryCadence
    self.remainingValue = remainingValue
    self.limitValue = limitValue
    self.valueUnit = valueUnit
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    usedPercent = try container.decode(Double.self, forKey: .usedPercent)
    resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
    durationSeconds = try container.decodeIfPresent(Int.self, forKey: .durationSeconds)
    primaryCadence = try container.decodeIfPresent(PrimaryCadence.self, forKey: .primaryCadence)
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
    case primaryCadence
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
    // A status this build has never heard of is one it cannot place: it says so rather than
    // claiming the reading is current.
    case .unknown: .unavailable
    }
  }
}

// Derivations both Apple products need from a window. The rules live in QuotaPresentation;
// these name them on the type so neither app restates them.
extension QuotaValueUnit {
  /// `nil` for a unit this build cannot name, which formats the number without a unit.
  public var remainingUnit: RemainingQuotaUnit? {
    switch self {
    case .usd: .usd
    case .credits: .credits
    case .count: .count
    case .unknown: nil
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

  /// The cadence this window headlines, or `nil` when it is not a headline meter this build
  /// can name — unknown, unmarked, or a balance that has no percent to stack.
  public var primaryCadenceKind: PrimaryCadenceKind? {
    guard showsPercentMeter else { return nil }
    switch primaryCadence {
    case .fiveHour: return .fiveHour
    case .weekly: return .weekly
    case .monthly: return .monthly
    case .unknown, nil: return nil
    }
  }
}

extension QuotaSnapshot {
  /// Headline meters, shortest cadence first, at most one per cadence. The service writes at
  /// most one; if two arrive, the first in wire order keeps the slot.
  public var primaryCadenceWindows: [QuotaWindow] {
    var selected: [QuotaWindow] = []
    for window in windows {
      guard let kind = window.primaryCadenceKind else { continue }
      if selected.contains(where: { $0.primaryCadenceKind == kind }) { continue }
      selected.append(window)
    }
    return selected.sorted {
      guard let left = $0.primaryCadenceKind, let right = $1.primaryCadenceKind else {
        return false
      }
      return left < right
    }
  }
}
