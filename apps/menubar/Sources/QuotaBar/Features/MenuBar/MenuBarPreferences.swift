import Foundation
import QuotaWire

/// What each menu-bar item shows. Persisted in UserDefaults so the choice survives relaunch.
enum MenuBarStylePreference: String, CaseIterable, Identifiable, Sendable {
  case icon
  case percent
  case iconAndPercent = "icon_and_percent"

  static let storageKey = "menubar.style"
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

/// How several chosen providers occupy the menu bar: one packed item, or one item each.
enum MenuBarArrangementPreference: String, CaseIterable, Identifiable, Sendable {
  case combined
  case separate

  static let storageKey = "menubar.arrangement"
  static let fallback = MenuBarArrangementPreference.combined

  var id: Self { self }

  var label: String {
    switch self {
    case .combined: "Combined"
    case .separate: "Separate"
    }
  }

  var summary: String {
    switch self {
    case .combined: "One item, up to 3 providers"
    case .separate: "One item per provider"
    }
  }
}

/// Whose remaining quota the menu bar answers for: the tightest current subscription, or a
/// named set of Overview providers.
///
/// An empty set is Automatic. A single stored provider id is the pre-multi-select spelling, so
/// a Mac that last chose one provider keeps that choice.
struct MenuBarProviderPreference: RawRepresentable, Hashable, Identifiable, Sendable {
  var selected: [ProviderID]

  static let storageKey = "menubar.provider"
  static let fallback = MenuBarProviderPreference.automatic
  static let automatic = MenuBarProviderPreference(selected: [])
  /// Packed items stay scannable only up to this many readings.
  static let combinedLimit = 3
  private static let automaticRawValue = "automatic"

  static func provider(_ provider: ProviderID) -> MenuBarProviderPreference {
    MenuBarProviderPreference(selected: [provider])
  }

  static func providers(_ providers: [ProviderID]) -> MenuBarProviderPreference {
    MenuBarProviderPreference(selected: providers)
  }

  var isAutomatic: Bool { selected.isEmpty }

  var id: String { rawValue }

  init(selected: [ProviderID] = []) {
    self.selected = selected
  }

  init?(rawValue: String) {
    if rawValue == Self.automaticRawValue || rawValue.isEmpty {
      selected = []
      return
    }
    var seen: Set<ProviderID> = []
    var providers: [ProviderID] = []
    for part in rawValue.split(separator: ",") {
      guard let provider = ProviderID(rawValue: String(part)), seen.insert(provider).inserted else {
        continue
      }
      providers.append(provider)
    }
    guard !providers.isEmpty else { return nil }
    selected = providers
  }

  var rawValue: String {
    if selected.isEmpty { return Self.automaticRawValue }
    return selected.map(\.rawValue).joined(separator: ",")
  }

  var label: String {
    if isAutomatic { return "Automatic" }
    if selected.count == 1 { return selected[0].displayName }
    return selected.map(\.displayName).joined(separator: ", ")
  }

  /// Automatic, then each Overview-visible provider as its own row identity.
  static func choices(visibleProviders: [ProviderID]) -> [MenuBarProviderPreference] {
    [.automatic] + visibleProviders.map(MenuBarProviderPreference.provider)
  }

  /// Toggles `provider` in Overview order. An empty result is Automatic.
  func toggling(_ provider: ProviderID, visibleProviders: [ProviderID]) -> MenuBarProviderPreference
  {
    var next = Set(selected)
    if isAutomatic {
      next = [provider]
    } else if next.contains(provider) {
      next.remove(provider)
    } else {
      next.insert(provider)
    }
    return MenuBarProviderPreference(selected: visibleProviders.filter { next.contains($0) })
  }
}

/// The stored menu-bar choices, read as one snapshot.
struct MenuBarItemPreferences: Equatable, Sendable {
  var style: MenuBarStylePreference
  var provider: MenuBarProviderPreference
  var arrangement: MenuBarArrangementPreference

  static func load(from defaults: UserDefaults = .standard) -> MenuBarItemPreferences {
    MenuBarItemPreferences(
      style: MenuBarStylePreference(
        rawValue: defaults.string(forKey: MenuBarStylePreference.storageKey) ?? ""
      ) ?? .fallback,
      provider: MenuBarProviderPreference(
        rawValue: defaults.string(forKey: MenuBarProviderPreference.storageKey) ?? ""
      ) ?? .fallback,
      arrangement: MenuBarArrangementPreference(
        rawValue: defaults.string(forKey: MenuBarArrangementPreference.storageKey) ?? ""
      ) ?? .fallback
    )
  }

  func layout(visibleProviders: [ProviderID]) -> MenuBarLayout {
    MenuBarLayout.resolve(
      selection: provider,
      arrangement: arrangement,
      visibleProviders: visibleProviders
    )
  }
}

/// What the menu bar actually occupies, after visible providers and Combined's cap.
enum MenuBarLayout: Equatable, Sendable {
  case automatic
  case packed([ProviderID])
  case items([ProviderID])

  static func resolve(
    selection: MenuBarProviderPreference,
    arrangement: MenuBarArrangementPreference,
    visibleProviders: [ProviderID]
  ) -> MenuBarLayout {
    let pinned = visibleProviders.filter { selection.selected.contains($0) }
    if selection.isAutomatic || pinned.isEmpty {
      return .automatic
    }
    if pinned.count >= 2, arrangement == .combined,
      pinned.count <= MenuBarProviderPreference.combinedLimit
    {
      return .packed(pinned)
    }
    return .items(pinned)
  }

  /// More than one reading cannot be Icon-only or Percent-only and still say whose number it is.
  var usesMultiReadingStyle: Bool {
    switch self {
    case .automatic: false
    case .packed(let providers), .items(let providers): providers.count > 1
    }
  }

  func effectiveStyle(_ style: MenuBarStylePreference) -> MenuBarStylePreference {
    usesMultiReadingStyle ? .iconAndPercent : style
  }

  var settingsSummary: String {
    switch self {
    case .automatic:
      "Automatic"
    case .packed(let providers):
      "\(Self.joinedNames(providers)) · Combined"
    case .items(let providers):
      providers.count <= 1
        ? (providers.first?.displayName ?? "Automatic")
        : "\(Self.joinedNames(providers)) · Separate"
    }
  }

  private static func joinedNames(_ providers: [ProviderID]) -> String {
    providers.map(\.displayName).joined(separator: ", ")
  }
}

/// Identity of one status item QuotaBar currently owns.
enum MenuBarStatusItemID: Hashable, Sendable {
  case automatic
  case combined
  case provider(ProviderID)

  var autosaveName: String {
    switch self {
    case .automatic: "quotabar-automatic"
    case .combined: "quotabar-combined"
    case .provider(let provider): "quotabar-\(provider.rawValue)"
    }
  }

  var accessibilityIdentifier: String {
    switch self {
    case .automatic: "QuotaBar.StatusItem"
    case .combined: "QuotaBar.StatusItem.combined"
    case .provider(let provider): "QuotaBar.StatusItem.\(provider.rawValue)"
    }
  }

  /// Separate items name the provider they show; packed and Automatic items do not.
  var focusProvider: ProviderID? {
    if case .provider(let provider) = self { return provider }
    return nil
  }
}
