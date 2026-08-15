import Foundation

public enum UsageCostCoverage: Sendable, Equatable {
  case complete
  case partial
  case unavailable
}

public enum UsageCostFormat: Sendable {
  public static func compact(status: UsageCostCoverage, amountMicrousd: String?) -> String {
    guard status != .unavailable else { return "— unpriced" }
    let amount = usd(amountMicrousd) ?? "$0.00"
    return status == .partial ? "≥ \(amount)" : amount
  }

  public static func accessible(status: UsageCostCoverage, amountMicrousd: String?) -> String {
    switch status {
    case .complete:
      return "\(compact(status: status, amountMicrousd: amountMicrousd)), complete"
    case .partial:
      return "\(compact(status: status, amountMicrousd: amountMicrousd)), partial"
    case .unavailable:
      return "unpriced"
    }
  }

  private static func usd(_ microusd: String?) -> String? {
    guard let microusd,
      let decimal = Decimal(string: microusd, locale: Locale(identifier: "en_US_POSIX"))
    else {
      return nil
    }
    let dollars = decimal / 1_000_000
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.locale = .current
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSDecimalNumber(decimal: dollars))
  }
}
