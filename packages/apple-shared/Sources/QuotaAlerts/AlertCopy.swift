import Foundation
import QuotaPresentation

/// Title and body for a local remaining-quota alert.
///
/// The phrases live in `apps/menubar/DESIGN.md` Shared product vocabulary.
public enum AlertCopy {
  public static func title(providerDisplayName: String, windowTitle: String) -> String {
    "\(providerDisplayName) · \(windowTitle)"
  }

  public static func thresholdBody(
    remainingPercent: Double,
    resetsAt: Date?,
    now: Date,
    timeZone: TimeZone = .current,
    calendar: Calendar = .current
  ) -> String {
    let left = "\(RemainingQuotaFormat.percent(remainingPercent)) left"
    guard let resetsAt,
      let phrase = FreshnessCopy.resetCopy(
        resetsAt: resetsAt, now: now, timeZone: timeZone, calendar: calendar)
    else {
      return left
    }
    // The shared copy reads "Resets in 42m" on its own line; inside a sentence it is lowercase.
    let lowered = phrase.prefix(1).lowercased() + phrase.dropFirst()
    return "\(left) · \(lowered)"
  }

  /// `<Window title> quota reset`.
  public static func resetBody(windowTitle: String) -> String {
    "\(windowTitle) quota reset"
  }

  /// The shared pace line, so the notification says exactly what the window row says.
  public static func paceBody(pace: QuotaPace, resetsAt: Date?) -> String? {
    QuotaPaceCopy.line(pace, resetsAt: resetsAt)
  }

  /// `Monthly budget`, which is the one budget there is.
  public static let budgetTitle = "Monthly budget"

  /// `80% of $50.00 spent` — or `Budget spent` once the whole amount is gone.
  public static func budgetBody(threshold: Int, budgetUSD: Decimal) -> String {
    threshold >= UsageBudget.exhaustedPercent
      ? "\(UsageBudgetProgress.usd(budgetUSD)) budget spent"
      : "\(threshold)% of \(UsageBudgetProgress.usd(budgetUSD)) spent"
  }
}
