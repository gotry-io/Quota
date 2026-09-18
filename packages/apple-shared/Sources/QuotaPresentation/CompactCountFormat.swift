import Foundation

public enum CompactCountFormat: Sendable {
  public static func compact(_ value: Int) -> String {
    value.formatted(
      .number
        .notation(.compactName)
        .precision(.significantDigits(1...3))
    )
    .replacingOccurrences(of: "K", with: "k")
  }

  public static func accessible(_ value: Int) -> String {
    value.formatted(.number)
  }

  /// One part of a whole as whole percent. A whole of nothing has no share to state.
  public static func share(_ part: Int, of whole: Int) -> String? {
    guard whole > 0 else { return nil }
    return "\((part * 200 + whole) / (whole * 2))%"
  }
}
