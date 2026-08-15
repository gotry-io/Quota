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

  private static let knownPlans: [String: String] = [
    "free": "Free",
    "plus": "Plus",
    "pro": "Pro",
    "prolite": "Pro Lite",
    "pro_lite": "Pro Lite",
    "pro-lite": "Pro Lite",
    "max": "Max",
    "team": "Team",
    "business": "Business",
    "enterprise": "Enterprise",
    "edu": "Edu",
    "education": "Education",
    "supergrok": "SuperGrok",
    "super_grok": "SuperGrok",
    "super-grok": "SuperGrok",
    "super": "Super",
  ]

  private static func normalize(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: " ", with: "")
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
