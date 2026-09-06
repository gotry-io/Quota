import Foundation
import QuotaPresentation

/// Pure evaluation of the monthly-budget alert, over the dedup state the quota alerts use.
///
/// A budget crossing is the same shape as a threshold crossing: one key fires once per cycle,
/// and the cycle is the month. The month is the window, so a new month starts a new cycle with
/// nothing to clear, and lowering a budget mid-month can only make a threshold arrive early.
/// The store is the app's own, apart from the quota alert store: one switch does not silence
/// the other.
public enum BudgetAlertEvaluator {
  /// The selector a budget event carries. A budget belongs to the device, not a subscription.
  public static let selector = "budget"

  public static func evaluate(
    budget: UsageBudget,
    progress: UsageBudgetProgress?,
    month: String,
    previous: AlertDedupState
  ) -> AlertEvaluation {
    guard budget.alerts, let amount = budget.amountUSD, let progress else {
      return AlertEvaluation(events: [], state: previous)
    }
    var fired = Set(previous.fired)
    var events: [AlertEvent] = []
    for threshold in progress.crossedThresholds {
      let key = AlertDedupKey(
        kind: .budget,
        selector: selector,
        windowID: month,
        resetsAt: nil,
        threshold: threshold
      )
      guard !fired.contains(key) else { continue }
      fired.insert(key)
      events.append(.budgetCrossed(month: month, threshold: threshold, budgetUSD: amount))
    }
    return AlertEvaluation(
      events: events,
      state: AlertDedupState(fired: Array(fired), readings: previous.readings).sorted()
    )
  }

  /// `YYYY-MM` in the device's own calendar, which is the cycle a monthly budget runs on.
  public static func month(containing date: Date, calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month], from: date)
    return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
  }
}
