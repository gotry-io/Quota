import Foundation
import QuotaPresentation
import QuotaWire

extension QuotaWindow {
  /// Overview remaining copy. No "left" suffix; the value is remaining by product rule.
  /// Amount-of-limit usd/credits windows show `$12.50 of $40.00`. Other budget windows with
  /// an amount show `71% · $3.75`.
  var remainingDisplayLabel: String {
    RemainingQuotaFormat.remaining(
      remainingPercent: remainingPercent,
      remainingValue: remainingValue,
      limitValue: limitValue,
      hasLimit: limitValue != nil,
      unit: remainingUnit
    )
  }

  /// Compact Overview copy. Cursor's Other Models percentage and included-usage dollars are
  /// different provider meters, so retain the dollars for a future detail surface without
  /// presenting them as one value here.
  func overviewRemainingDisplayLabel(provider: ProviderID) -> String {
    if provider == .cursor, id == "other_models" {
      return formattedRemainingPercent
    }
    return remainingDisplayLabel
  }

  var formattedRemainingPercent: String {
    RemainingQuotaFormat.percent(remainingPercent)
  }

  var displayTitle: String {
    RemainingQuotaFormat.windowTitle(title, isBalanceOnly: isBalanceOnly)
  }

  /// Where remaining would stand now at an even burn rate (`docs/design.md` Even-pace tick):
  /// only beside a pace line the reading prints, and never on a reading that is no longer
  /// current, whose clock has stopped.
  func evenPaceTick(now: Date, isStale: Bool) -> Double? {
    guard !isStale, let pace, let resetsAt, resetsAt > now,
      QuotaPaceCopy.headline(pace, resetsAt: resetsAt) != nil
    else {
      return nil
    }
    return EvenPacePosition.remainingPercent(paceReading, now: now)
  }

  static func formattedPercent(_ value: Double) -> String {
    RemainingQuotaFormat.percent(value)
  }
}
