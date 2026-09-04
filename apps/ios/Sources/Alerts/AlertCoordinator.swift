import Foundation
import QuotaAlerts
import QuotaPresentation
import QuotaWire

/// Evaluates local remaining-quota alert rules against an Account summary.
///
/// Delivery is `AlertSink`. Sign-out clears the state store and leaves rules in place.
@MainActor
final class AlertCoordinator {
  private let rulesStore: IOSAlertRulesStore
  private let stateStore: any IOSAlertStateStore
  private let sink: any AlertSink
  private let now: () -> Date

  init(
    rulesStore: IOSAlertRulesStore,
    stateStore: any IOSAlertStateStore,
    sink: any AlertSink,
    now: @escaping () -> Date = Date.init
  ) {
    self.rulesStore = rulesStore
    self.stateStore = stateStore
    self.sink = sink
    self.now = now
  }

  func evaluate(summary: AccountSummary) {
    let rules = rulesStore.load()
    let previous = (try? stateStore.load()) ?? .empty
    let current = Self.readings(from: summary.subscriptions)
    let result = AlertEvaluator.evaluate(
      rules: rules,
      previous: previous,
      current: current,
      now: now()
    )
    if result.state != previous {
      try? stateStore.save(result.state)
    }
    if !result.events.isEmpty {
      sink.deliver(result.events)
    }
  }

  func currentRules() -> AlertRules {
    rulesStore.load()
  }

  func clearState() {
    try? stateStore.clear()
  }

  static func selector(for subscription: QuotaSubscription) -> String {
    SubscriptionSelector.make(
      provider: subscription.provider.rawValue,
      fingerprint: subscription.snapshot.account.fingerprint,
      fingerprintScope: subscription.snapshot.account.fingerprintScope.rawValue,
      // A source-scoped subscription carries its source id as the key's fourth segment;
      // the selector has to include it so every client names the same subscription.
      sourceID: sourceID(fromKey: subscription.key)
    )
  }

  static func catalog(from subscriptions: [QuotaSubscription]) -> AlertDeliveryCatalog {
    var entries: [String: AlertDeliveryCatalog.Entry] = [:]
    for subscription in subscriptions {
      let windows = Dictionary(
        uniqueKeysWithValues: subscription.snapshot.windows.map { ($0.id, $0.title) }
      )
      entries[selector(for: subscription)] = AlertDeliveryCatalog.Entry(
        providerDisplayName: subscription.provider.displayName,
        windows: windows
      )
    }
    return AlertDeliveryCatalog(entries: entries)
  }

  static func readings(from subscriptions: [QuotaSubscription]) -> [AlertSubscriptionReading] {
    subscriptions.map { subscription in
      AlertSubscriptionReading(
        selector: selector(for: subscription),
        status: subscription.snapshot.status.rawValue,
        windows: subscription.snapshot.windows.compactMap { window in
          guard window.showsPercentMeter else { return nil }
          return AlertWindowReading(
            id: window.id,
            title: window.title,
            remainingPercent: RemainingQuotaFormat.remainingPercent(usedPercent: window.usedPercent),
            resetsAt: window.resetsAt,
            primaryCadence: window.primaryCadenceKind?.rawValue
          )
        }
      )
    }
  }

  /// `provider|fingerprint|scope|source_id`; empty when the subscription is global.
  static func sourceID(fromKey key: String) -> String? {
    let parts = key.split(separator: "|", omittingEmptySubsequences: false)
    guard parts.count >= 4, !parts[3].isEmpty else { return nil }
    return String(parts[3])
  }
}
