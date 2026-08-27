import Foundation
import QuotaPresentation
import QuotaWire

/// What the menu-bar item shows. Persisted in UserDefaults so the choice survives relaunch.
enum MenuBarStylePreference: String, CaseIterable, Identifiable, Sendable {
  case icon
  case percent
  case iconAndPercent = "icon_and_percent"

  /// The key is older than the name on screen. A rename is not worth losing what someone chose.
  static let storageKey = "menubar.display"
  static let fallback = MenuBarStylePreference.iconAndPercent

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

/// Which subscription the menu-bar item answers for: whichever is closest to running out, or
/// one named provider for a person who only cares about that one.
enum MenuBarProviderPreference: RawRepresentable, Hashable, Identifiable, Sendable {
  case automatic
  case provider(ProviderID)

  static let storageKey = "menubar.provider"
  static let fallback = MenuBarProviderPreference.automatic
  private static let automaticRawValue = "automatic"

  init?(rawValue: String) {
    if rawValue == Self.automaticRawValue {
      self = .automatic
      return
    }
    guard let provider = ProviderID(rawValue: rawValue) else { return nil }
    self = .provider(provider)
  }

  var rawValue: String {
    switch self {
    case .automatic: Self.automaticRawValue
    case .provider(let provider): provider.rawValue
    }
  }

  var id: String { rawValue }

  var label: String {
    switch self {
    case .automatic: "Automatic"
    case .provider(let provider): provider.displayName
    }
  }

  /// Automatic, then the providers Overview is actually showing, in Overview's own order. A
  /// provider hidden from Overview is not a choice, because its number is not on screen anywhere.
  static func choices(visibleProviders: [ProviderID]) -> [MenuBarProviderPreference] {
    [.automatic] + visibleProviders.map(MenuBarProviderPreference.provider)
  }
}

/// The mark the item wears: the provider the number belongs to, or Quota's own when there is no
/// number to attribute.
enum MenuBarLabelIcon: Equatable, Sendable {
  case quota
  case provider(ProviderID)
}

/// The menu-bar item's content: a mark, and the remaining percent of the subscription the
/// person chose to watch — by default the one closest to running out.
///
/// The point of the item is that the tightest number is readable without opening anything,
/// so it names a single reading rather than an average or a count. A reading that no longer
/// describes live quota answers for nothing, and a menu bar with nothing to say is the mark
/// alone.
struct MenuBarLabelModel: Equatable, Sendable {
  let icon: MenuBarLabelIcon?
  let text: String?
  let accessibilityLabel: String

  /// The menu bar renders as a template image, so low quota cannot be said in color. Below
  /// this percent the text says it in punctuation instead.
  static let warningPercent: Double = 10

  static func make(
    overview: [LocalServiceOverviewItem],
    style: MenuBarStylePreference,
    provider: MenuBarProviderPreference,
    now: Date
  ) -> MenuBarLabelModel {
    guard
      style.showsPercent,
      let tightest = tightestReading(in: overview, provider: provider, now: now)
    else {
      // Nothing to attribute, so the mark is Quota's own — including for Percent, because an
      // item with no content cannot be clicked.
      return MenuBarLabelModel(icon: .quota, text: nil, accessibilityLabel: "QuotaBar")
    }
    let percent = RemainingQuotaFormat.percent(tightest.remainingPercent)
    return MenuBarLabelModel(
      icon: style.showsIcon ? .provider(tightest.provider) : nil,
      text: tightest.remainingPercent < warningPercent ? "!\(percent)" : percent,
      accessibilityLabel: "QuotaBar, \(tightest.provider.displayName) \(percent) remaining"
    )
  }

  private struct Reading {
    let provider: ProviderID
    let remainingPercent: Double
  }

  /// The smallest remaining percent any window of any current reading reports, among the
  /// readings the provider choice allows.
  ///
  /// Balance-only windows carry no budget to be a percent of, so they cannot be the
  /// constraint; every other window can.
  private static func tightestReading(
    in overview: [LocalServiceOverviewItem],
    provider preference: MenuBarProviderPreference,
    now: Date
  ) -> Reading? {
    var tightest: Reading?
    for item in overview where isCurrent(item, now: now) {
      if case .provider(let chosen) = preference, item.identity.provider != chosen { continue }
      for window in item.snapshot.windows where window.showsPercentMeter {
        guard tightest.map({ window.remainingPercent < $0.remainingPercent }) ?? true else {
          continue
        }
        tightest = Reading(
          provider: item.identity.provider,
          remainingPercent: window.remainingPercent
        )
      }
    }
    return tightest
  }

  /// Which Overview readings still describe live quota, in Overview's order.
  ///
  /// Time enters the item's content in exactly one place — this verdict — because a percent
  /// does not move on its own and only the freshness rule can retire it. A caller that has to
  /// re-evaluate the item on a clock compares this instead of the label, so a minute in which
  /// nothing aged out costs nothing.
  static func currency(of overview: [LocalServiceOverviewItem], now: Date) -> [Bool] {
    overview.map { isCurrent($0, now: now) }
  }

  /// A reading that still describes live quota: the source reported it could read, and the
  /// shared freshness rule has not aged it out.
  private static func isCurrent(_ item: LocalServiceOverviewItem, now: Date) -> Bool {
    !item.isStale && item.snapshot.observedState(now: now) == .available
  }
}
