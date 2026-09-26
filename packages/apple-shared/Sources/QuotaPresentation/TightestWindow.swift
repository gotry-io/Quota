import Foundation

// The tightest current window across subscriptions: what the menu bar's Automatic item shows,
// what heads a quota page's gauge, and what a quota band ring shows per subscription.
//
// Public API:
// - `TightestWindowChoice<Subscription, Window>` — the subscription, its window, the remaining.
// - `TightestWindow.choose(in:isCurrent:windows:)` — the rule.

/// The window that constrains most, and whose it is.
public struct TightestWindowChoice<Subscription, Window> {
  public let subscription: Subscription
  public let window: Window
  public let remainingPercent: Double

  public init(subscription: Subscription, window: Window, remainingPercent: Double) {
    self.subscription = subscription
    self.window = window
    self.remainingPercent = remainingPercent
  }
}

extension TightestWindowChoice: Sendable where Subscription: Sendable, Window: Sendable {}
extension TightestWindowChoice: Equatable where Subscription: Equatable, Window: Equatable {}

public enum TightestWindow {
  /// The smallest remaining percent of any metered window of any current subscription.
  ///
  /// Only windows that draw a percent meter compete: a balance has no budget to be a percent of,
  /// and an amount-of-limit window (`$12.50 of $40.00`) is stated as that amount instead — the
  /// `RemainingQuotaFormat.showsPercentMeter` rule. A subscription `isCurrent` refuses (stale,
  /// or its source reported it cannot read) answers for nothing. On a tie the first in
  /// `subscriptions` order, then window order, wins, so the order a surface already lists
  /// subscriptions in decides.
  public static func choose<Subscription, Window: RemainingQuotaWindow>(
    in subscriptions: some Sequence<Subscription>,
    isCurrent: (Subscription) -> Bool,
    windows: (Subscription) -> [Window]
  ) -> TightestWindowChoice<Subscription, Window>? {
    var tightest: TightestWindowChoice<Subscription, Window>?
    for subscription in subscriptions where isCurrent(subscription) {
      for window in windows(subscription) {
        let remaining = RemainingQuotaFormat.remainingPercent(usedPercent: window.usedPercent)
        guard
          RemainingQuotaFormat.showsPercentMeter(
            remainingPercent: remaining,
            remainingValue: window.remainingValue,
            limitValue: window.limitValue,
            hasLimit: window.limitValue != nil,
            unit: window.remainingUnit
          ),
          tightest.map({ remaining < $0.remainingPercent }) ?? true
        else { continue }
        tightest = TightestWindowChoice(
          subscription: subscription,
          window: window,
          remainingPercent: remaining
        )
      }
    }
    return tightest
  }
}
