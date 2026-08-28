/// Fixed Quota collection cadences. Account summary still polls every minute regardless.
enum QuotaRefreshInterval: Int, CaseIterable, Identifiable {
  case oneMinute = 60
  case twoMinutes = 120
  case fiveMinutes = 300
  case tenMinutes = 600
  case fifteenMinutes = 900

  var id: Int { rawValue }

  static let fallback = QuotaRefreshInterval.fiveMinutes

  var label: String {
    switch self {
    case .oneMinute: "1 minute"
    case .twoMinutes: "2 minutes"
    case .fiveMinutes: "5 minutes"
    case .tenMinutes: "10 minutes"
    case .fifteenMinutes: "15 minutes"
    }
  }

  static func resolved(_ seconds: Int) -> QuotaRefreshInterval {
    QuotaRefreshInterval(rawValue: seconds) ?? .fallback
  }
}
