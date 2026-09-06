import Foundation

/// Folds the activity days a range covers into the one period a Usage page shows.
///
/// An Account summary folds four periods on the server, because those four are what every client
/// opens on. Any other period — a week, a month, a range someone picked — is the same days added
/// up, and the days are already here: the activity read answers a year at a time. Adding them
/// locally is the same arithmetic the server does, stated once in
/// `packages/protocol/fixtures/usage-day-fold-conformance.json`, which this and the website both
/// answer.
///
/// Only the totals and the cost fold. A day carries its agent tree only when it was asked for on
/// its own, so a folded period has no breakdown and says so by carrying no agents.
public enum UsageDayFold: Sendable {
  /// The days inside an inclusive date range, in date order.
  public static func days(
    _ days: [UsageActivityDay],
    from: String,
    to: String
  ) -> [UsageActivityDay] {
    days.filter { $0.date >= from && $0.date <= to }.sorted { $0.date < $1.date }
  }

  public static func period(_ days: [UsageActivityDay]) -> UsagePeriod {
    UsagePeriod(
      totals: totals(days.map(\.totals)),
      cost: cost(days.map(\.cost)),
      partial: days.contains { $0.partial },
      agents: []
    )
  }

  public static func period(_ days: [UsageActivityDay], from: String, to: String) -> UsagePeriod {
    period(self.days(days, from: from, to: to))
  }

  /// Adds token counts, which are counts of the same events over disjoint days.
  public static func totals(_ values: [UsageSummaryTotals]) -> UsageSummaryTotals {
    UsageSummaryTotals(
      totalTokens: values.reduce(0) { $0 + $1.totalTokens },
      inputTokens: values.reduce(0) { $0 + $1.inputTokens },
      outputTokens: values.reduce(0) { $0 + $1.outputTokens },
      cacheReadInputTokens: values.reduce(0) { $0 + $1.cacheReadInputTokens },
      cacheWriteInputTokens: values.reduce(0) { $0 + $1.cacheWriteInputTokens },
      reasoningTokens: values.reduce(0) { $0 + $1.reasoningTokens },
      messages: values.reduce(0) { $0 + $1.messages }
    )
  }

  /// Adds cost outcomes, then reaches the same verdict one row does.
  ///
  /// The amount and the row counts add. The basis and the status follow from the counts, so a
  /// period is partly priced exactly when one of its days left a row unpriced. Two days priced
  /// against different catalog revisions name no single revision, so the fold names none.
  public static func cost(_ outcomes: [UsageCostOutcome]) -> UsageCostOutcome {
    var amount = 0 as Decimal
    var priced = false
    var calculated = 0
    var reported = 0
    var unpricedRows = 0
    var assumptions: [UsageCostAssumption] = []
    var unpriced: [UnpricedKey: Int] = [:]
    var truncated = false
    var revision: String?
    for (index, outcome) in outcomes.enumerated() {
      if index == 0 {
        revision = outcome.catalogRevision
      } else if revision != outcome.catalogRevision {
        revision = nil
      }
      if let value = outcome.amountMicrousd,
        let parsed = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
      {
        amount += parsed
        priced = true
      }
      calculated += outcome.calculatedRows
      reported += outcome.reportedRows
      unpricedRows += outcome.unpricedRows
      for assumption in outcome.assumptions where !assumptions.contains(assumption) {
        assumptions.append(assumption)
      }
      truncated = truncated || outcome.unpricedTruncated == true
      for item in outcome.unpriced {
        let key = UnpricedKey(
          billingChannel: item.billingChannel, model: item.model, reason: item.reason)
        unpriced[key, default: 0] += item.rows
      }
    }
    let pricedRows = calculated + reported
    let items = unpriced
      .map { UsageUnpricedItem(billingChannel: $0.key.billingChannel, model: $0.key.model, reason: $0.key.reason, rows: $0.value) }
      .sorted {
        ($0.billingChannel.rawValue, $0.model, $0.reason.rawValue)
          < ($1.billingChannel.rawValue, $1.model, $1.reason.rawValue)
      }
    let keptItems = Array(items.prefix(maximumUnpricedItems))
    return UsageCostOutcome(
      mode: outcomes.first?.mode ?? .auto,
      basis: calculated > 0 && reported > 0
        ? .mixed : calculated > 0 ? .calculated : reported > 0 ? .reported : .none,
      status: unpricedRows == 0 ? .complete : pricedRows > 0 ? .partial : .unavailable,
      amountMicrousd: priced && pricedRows > 0 ? decimalText(amount) : nil,
      catalogRevision: revision,
      calculatedRows: calculated,
      reportedRows: reported,
      unpricedRows: unpricedRows,
      assumptions: assumptions.sorted { $0.rawValue < $1.rawValue },
      unpriced: keptItems,
      unpricedTruncated: truncated || items.count > maximumUnpricedItems ? true : nil
    )
  }

  /// The bound the protocol puts on an unpriced list, which a fold does not get to exceed.
  static let maximumUnpricedItems = 100

  private struct UnpricedKey: Hashable {
    var billingChannel: BillingChannel
    var model: String
    var reason: UsageUnpricedReason
  }

  private static func decimalText(_ value: Decimal) -> String {
    NSDecimalNumber(decimal: value).description(withLocale: Locale(identifier: "en_US_POSIX"))
  }
}
