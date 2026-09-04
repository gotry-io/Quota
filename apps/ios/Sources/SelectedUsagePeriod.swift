import QuotaWire

/// The four periods an Account summary already carries. Selection is in-memory for the
/// signed-in session; it is not persisted.
enum SelectedUsagePeriod: String, CaseIterable, Identifiable, Sendable {
  case today
  case last7Days
  case last30Days
  case all

  var id: Self { self }

  /// Segmented-control label. `all` uses **2 Years** because **Up to 2 years** does not fit.
  var segmentTitle: String {
    switch self {
    case .today: "Today"
    case .last7Days: "7 Days"
    case .last30Days: "30 Days"
    case .all: "2 Years"
    }
  }

  /// VoiceOver name. The fourth segment is spoken in full.
  var accessibilityTitle: String {
    switch self {
    case .all: "Up to 2 years"
    default: segmentTitle
    }
  }

  func period(in usage: AccountUsage) -> UsagePeriod {
    switch self {
    case .today: usage.today
    case .last7Days: usage.last7Days
    case .last30Days: usage.last30Days
    case .all: usage.all
    }
  }
}
