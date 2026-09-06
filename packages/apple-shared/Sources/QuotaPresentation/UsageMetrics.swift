import Foundation

/// The Usage metrics every runtime derives rather than reads.
///
/// See [ADR 0036](../../../../docs/decisions/0036-usage-derived-metrics.md). The rule is stated
/// once per runtime and answered against one shared fixture, so a change to one of them that
/// the others did not make fails a test rather than reaching a person as two different numbers.
public enum UsageMetrics: Sendable {
  /// How much of a period's input tokens came back from a cache, in basis points.
  ///
  /// `inputTokens` is every input token the request was billed for and the cache counts are
  /// parts of it, so this is one share of one whole. A period with no input has no rate rather
  /// than a rate of zero. Basis points keep the answer an integer, which is what lets three
  /// runtimes agree exactly instead of to within a rounding.
  ///
  /// The multiplication is done at double width because a token count reaches the JSON safe
  /// integer, and ten thousand times that does not fit a machine word.
  public static func cacheHitBasisPoints(cacheReadInputTokens: Int, inputTokens: Int) -> Int? {
    guard inputTokens > 0, cacheReadInputTokens >= 0 else { return nil }
    var product = cacheReadInputTokens.multipliedFullWidth(by: 20_000)
    let (low, carried) = product.low.addingReportingOverflow(UInt(inputTokens))
    product.low = low
    if carried { product.high += 1 }
    return (inputTokens * 2).dividingFullWidth(product).quotient
  }

  /// The same rate as a percentage, rounded to whole percent the way a headline states it.
  public static func cacheHitPercentLabel(basisPoints: Int?) -> String? {
    guard let basisPoints else { return nil }
    return "\((basisPoints + 50) / 100)%"
  }
}

/// The four stretches of the local clock a rhythm is summed into.
///
/// Six hours each, named for when a person would say they were working. The order is the order
/// they are shown in, which starts at the morning rather than at midnight.
public enum UsageDayPart: String, CaseIterable, Sendable {
  case morning
  case afternoon
  case evening
  case night

  public var hours: Range<Int> {
    switch self {
    case .morning: 6..<12
    case .afternoon: 12..<18
    case .evening: 18..<24
    case .night: 0..<6
    }
  }

  public var title: String {
    switch self {
    case .morning: "Morning"
    case .afternoon: "Afternoon"
    case .evening: "Evening"
    case .night: "Night"
    }
  }

  /// The stretch one hour of the local clock belongs to.
  public static func containing(hour: Int) -> UsageDayPart? {
    allCases.first { $0.hours.contains(hour) }
  }
}
