import Foundation
import QuotaPresentation

/// UserDefaults adapter for the monthly budget and the crossings it has already announced.
///
/// The budget is a device's own preference and is never uploaded, so it sits beside the alert
/// rules rather than in the Account. Both Apple apps keep it under the same keys. The fired keys
/// are the dedup state `QuotaAlerts` works in, written as `requestIdentifier` strings because
/// that is what the notification centre is asked to post under too.
public struct UsageBudgetStore {
  public static let amountKey = "usage.budget.amountUSD"
  public static let alertsKey = "usage.budget.alerts"
  public static let firedKey = "usage.budget.fired"

  public let defaults: UserDefaults

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  public func load() -> UsageBudget {
    let amount = defaults.object(forKey: Self.amountKey) as? Double
    return UsageBudget(
      amountUSD: amount.map { Decimal($0) },
      alerts: defaults.object(forKey: Self.alertsKey) as? Bool ?? true
    )
  }

  @discardableResult
  public func save(_ budget: UsageBudget) -> UsageBudget {
    let normalized = UsageBudget(amountUSD: budget.amountUSD, alerts: budget.alerts)
    if let amount = normalized.amountUSD {
      defaults.set(NSDecimalNumber(decimal: amount).doubleValue, forKey: Self.amountKey)
    } else {
      defaults.removeObject(forKey: Self.amountKey)
    }
    defaults.set(normalized.alerts, forKey: Self.alertsKey)
    return normalized
  }

  public func loadFired() -> AlertDedupState {
    let raw = defaults.stringArray(forKey: Self.firedKey) ?? []
    return AlertDedupState(fired: raw.compactMap(Self.key), readings: [])
  }

  public func saveFired(_ state: AlertDedupState) {
    defaults.set(state.fired.map(\.requestIdentifier), forKey: Self.firedKey)
  }

  /// `budget:budget:<month>:none:<threshold>`, which is what a budget key writes.
  public static func key(_ identifier: String) -> AlertDedupKey? {
    let parts = identifier.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 5, parts[0] == AlertKind.budget.rawValue,
      parts[1] == BudgetAlertEvaluator.selector,
      let threshold = Int(parts[4])
    else { return nil }
    return AlertDedupKey(
      kind: .budget,
      selector: String(parts[1]),
      windowID: String(parts[2]),
      resetsAt: nil,
      threshold: threshold
    )
  }
}
