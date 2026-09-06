import Foundation

/// A monthly API-equivalent spend budget, which is this device's own preference.
///
/// The amount is whole US dollars. It is never uploaded: a budget says what someone wants to be
/// warned about, which is not a fact about their Account. Each app persists it in its own
/// `UserDefaults`; the website keeps the same two fields in `localStorage`.
public struct UsageBudget: Equatable, Sendable {
  /// Nil means no budget is set, which is the state a device starts in.
  public var amountUSD: Decimal?
  /// Whether crossing 80% and 100% of the amount posts a notification.
  public var alerts: Bool

  public static let none = UsageBudget(amountUSD: nil, alerts: true)
  /// The share of the budget that is worth saying something about before it is spent.
  public static let warningPercent = 80
  public static let exhaustedPercent = 100
  public static let thresholds = [warningPercent, exhaustedPercent]
  /// The widest budget the editors accept, which keeps the progress text one line.
  public static let maximumAmountUSD = Decimal(1_000_000)

  public init(amountUSD: Decimal?, alerts: Bool) {
    self.amountUSD = Self.normalized(amountUSD)
    self.alerts = alerts
  }

  public var isSet: Bool { amountUSD != nil }

  /// An amount outside `(0, maximum]` is no budget at all rather than a budget of zero.
  public static func normalized(_ amount: Decimal?) -> Decimal? {
    guard let amount, amount > 0, amount <= maximumAmountUSD else { return nil }
    return amount
  }
}

/// How far into a budget one month's spend has gone.
public struct UsageBudgetProgress: Equatable, Sendable {
  public var spentUSD: Decimal
  public var budgetUSD: Decimal
  /// Whole percent, rounded down, so 99.9% of a budget never reads as spent.
  public var percent: Int
  /// Whether the priced share of the month is short, which makes the spend a lower bound.
  public var partial: Bool

  public init(spentUSD: Decimal, budgetUSD: Decimal, partial: Bool) {
    self.spentUSD = spentUSD
    self.budgetUSD = budgetUSD
    self.partial = partial
    let ratio = (spentUSD / budgetUSD) * 100
    var floored = Decimal()
    var raw = ratio
    NSDecimalRound(&floored, &raw, 0, .down)
    percent = max(0, min(Int(truncating: NSDecimalNumber(decimal: floored)), 1_000))
  }

  /// The bar's fill, clamped: a month past its budget fills it once, not twice.
  public var fraction: Double {
    min(1, Double(percent) / 100)
  }

  /// `$5.39 / $50.00 · 11%`, with `≥` in front of a spend that is only partly priced.
  public var text: String {
    let spent = Self.usd(spentUSD)
    return "\(partial ? "≥ " : "")\(spent) / \(Self.usd(budgetUSD)) · \(percent)%"
  }

  public var accessibilityText: String {
    "\(partial ? "at least " : "")\(Self.usd(spentUSD)) of \(Self.usd(budgetUSD)) spent, \(percent) percent"
  }

  /// The budget thresholds this progress has reached, lowest first.
  public var crossedThresholds: [Int] {
    UsageBudget.thresholds.filter { percent >= $0 }
  }

  /// The amount as an editor writes it back into its field: digits and a decimal point, no
  /// currency symbol and no grouping, so what was typed is what comes back.
  public static func plain(_ amount: Decimal) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.locale = .current
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "0"
  }

  public static func usd(_ amount: Decimal) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.locale = .current
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "$0.00"
  }

  /// The dollars a `amount_microusd` string names, which is how every Usage cost is carried.
  public static func dollars(microusd: String?) -> Decimal? {
    guard let microusd,
      let value = Decimal(string: microusd, locale: Locale(identifier: "en_US_POSIX"))
    else { return nil }
    return value / 1_000_000
  }
}
