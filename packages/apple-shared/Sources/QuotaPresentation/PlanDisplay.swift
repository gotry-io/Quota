import Foundation

public enum PlanDisplay: Sendable {
  public static func displayName(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else {
      return nil
    }

    let key = normalize(trimmed)
    if let mapped = knownPlans[key] {
      return mapped
    }

    if trimmed.contains(where: \.isUppercase) || trimmed.contains(where: \.isWhitespace) {
      return trimmed
    }

    return titleCaseSlug(trimmed)
  }

  /// Plan text only — never falls back to account label.
  public static func planBadge(_ raw: String?) -> String? {
    displayName(raw)
  }

  /// Secondary account identity under the provider header.
  public static func accountLabel(_ label: String?) -> String? {
    nonempty(label)
  }

  /// Plan slugs reach us with any separator (`supergrok heavy`, `super_grok`,
  /// `pro-lite`), so the lookup key drops them all rather than the table
  /// carrying one entry per spelling.
  private static func normalize(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .filter { $0.isLetter || $0.isNumber }
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else {
      return nil
    }
    return trimmed
  }

  private static func titleCaseSlug(_ value: String) -> String {
    value
      .replacingOccurrences(of: "-", with: "_")
      .split(separator: "_", omittingEmptySubsequences: true)
      .map { part in
        let lower = part.lowercased()
        guard let first = lower.first else { return "" }
        return String(first).uppercased() + lower.dropFirst()
      }
      .joined(separator: " ")
  }
}
