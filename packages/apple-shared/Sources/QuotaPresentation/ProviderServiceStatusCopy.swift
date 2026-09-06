import Foundation

/// Atlassian Statuspage v2 `status.indicator` values this build reads.
public enum ProviderServiceStatusIndicator: String, Sendable, Codable, Equatable {
  case none
  case minor
  case major
  case critical
}

/// Settings and Overview copy for an official status-page reading.
public enum ProviderServiceStatusCopy {
  public static let operational = "All systems operational"

  public static func settingsLine(
    indicator: ProviderServiceStatusIndicator,
    description: String
  ) -> String {
    switch indicator {
    case .none:
      operational
    case .minor, .major, .critical:
      "Degraded · \(description)"
    }
  }

  public static func showsDot(_ indicator: ProviderServiceStatusIndicator) -> Bool {
    indicator != .none
  }
}
