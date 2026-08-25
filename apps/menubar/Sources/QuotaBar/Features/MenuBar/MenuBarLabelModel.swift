import Foundation
import QuotaPresentation
import QuotaWire

/// What the menu-bar item shows. Persisted in UserDefaults so the choice survives relaunch.
enum MenuBarDisplayPreference: String, CaseIterable, Identifiable, Sendable {
  case icon
  case percent
  case iconAndPercent = "icon_and_percent"

  static let storageKey = "menubar.display"
  static let fallback = MenuBarDisplayPreference.iconAndPercent

  var id: Self { self }

  var label: String {
    switch self {
    case .icon: "Icon"
    case .percent: "Percent"
    case .iconAndPercent: "Icon and percent"
    }
  }

  var showsIcon: Bool { self != .percent }
  var showsPercent: Bool { self != .icon }
}

/// The menu-bar item's content: the mark, and the remaining percent of the subscription
/// closest to running out.
///
/// The point of the item is that the tightest number is readable without opening anything,
/// so it names the single most constrained current reading rather than an average or a
/// count. A reading that no longer describes live quota answers for nothing, and a menu bar
/// with nothing to say is the icon alone.
struct MenuBarLabelModel: Equatable, Sendable {
  let showsIcon: Bool
  let text: String?
  let accessibilityLabel: String

  /// The menu bar renders as a template image, so low quota cannot be said in color. Below
  /// this percent the text says it in punctuation instead.
  static let warningPercent: Double = 10

  static func make(
    overview: [LocalServiceOverviewItem],
    preference: MenuBarDisplayPreference,
    now: Date
  ) -> MenuBarLabelModel {
    guard preference.showsPercent, let remaining = lowestRemainingPercent(in: overview, now: now)
    else {
      return MenuBarLabelModel(showsIcon: true, text: nil, accessibilityLabel: "QuotaBar")
    }
    let percent = RemainingQuotaFormat.percent(remaining)
    return MenuBarLabelModel(
      showsIcon: preference.showsIcon,
      text: remaining < warningPercent ? "!\(percent)" : percent,
      accessibilityLabel: "QuotaBar, \(percent) remaining"
    )
  }

  /// The smallest remaining percent any window of any current reading reports.
  ///
  /// Balance-only windows carry no budget to be a percent of, so they cannot be the
  /// constraint; every other window can.
  private static func lowestRemainingPercent(
    in overview: [LocalServiceOverviewItem],
    now: Date
  ) -> Double? {
    var lowest: Double?
    for item in overview where isCurrent(item, now: now) {
      for window in item.snapshot.windows where window.showsPercentMeter {
        lowest = min(lowest ?? window.remainingPercent, window.remainingPercent)
      }
    }
    return lowest
  }

  /// A reading that still describes live quota: the source reported it could read, and the
  /// shared freshness rule has not aged it out.
  private static func isCurrent(_ item: LocalServiceOverviewItem, now: Date) -> Bool {
    !item.isStale && item.snapshot.observedState(now: now) == .available
  }
}
