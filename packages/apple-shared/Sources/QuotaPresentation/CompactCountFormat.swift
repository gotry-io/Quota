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
}
