import QuotaPresentation
import QuotaWire

/// The Usage page's model ledger: the first rows of `ModelLedger.rows`, then one row that names
/// how many models the page did not list and what they came to (docs/design.md, Model ledger).
/// The rest are one tap away on All models, which lists every row.
enum UsageLedgerFold {
  static let visibleRows = 6

  struct Rest: Equatable, Sendable {
    let count: Int
    let tokens: Int
    /// Their tokens over the period's, 0…1.
    let share: Double
  }

  static func split(
    _ rows: [ModelLedgerRow<BillingAgent>],
    visible: Int = visibleRows
  ) -> (visible: [ModelLedgerRow<BillingAgent>], rest: Rest?) {
    guard rows.count > visible else { return (rows, nil) }
    let hidden = rows.dropFirst(visible)
    return (
      Array(rows.prefix(visible)),
      Rest(
        count: hidden.count,
        tokens: hidden.reduce(0) { $0 + $1.totals.totalTokens },
        share: hidden.reduce(0) { $0 + $1.share }
      )
    )
  }
}
