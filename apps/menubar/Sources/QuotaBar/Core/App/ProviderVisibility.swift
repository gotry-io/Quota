import Foundation

/// Catalog-driven Agents visibility (`provider.<id>.visible` in UserDefaults).
/// Missing keys fall back to `ProviderID.defaultVisible` from the generated catalog.
enum ProviderVisibility {
  static func storageKey(for provider: ProviderID) -> String {
    "provider.\(provider.rawValue).visible"
  }

  static func isVisible(_ provider: ProviderID, defaults: UserDefaults = .standard) -> Bool {
    if defaults.object(forKey: storageKey(for: provider)) == nil {
      return provider.defaultVisible
    }
    return defaults.bool(forKey: storageKey(for: provider))
  }

  static func setVisible(_ provider: ProviderID, _ visible: Bool, defaults: UserDefaults = .standard) {
    defaults.set(visible, forKey: storageKey(for: provider))
  }

}

/// User-defined Provider order shared by Settings → Agents and Overview.
enum ProviderDisplayOrder {
  static let storageKey = "provider.display_order"

  static func enabledProviders(defaults: UserDefaults = .standard) -> [ProviderID] {
    allProviders(defaults: defaults).filter {
      ProviderVisibility.isVisible($0, defaults: defaults)
    }
  }

  static func saveEnabledOrder(
    _ enabledProviders: [ProviderID],
    defaults: UserDefaults = .standard
  ) {
    let providers = allProviders(defaults: defaults)
    let enabledSet = Set(enabledProviders)
    let visibleSet = Set(
      providers.filter { ProviderVisibility.isVisible($0, defaults: defaults) }
    )
    guard enabledSet.count == enabledProviders.count, enabledSet == visibleSet else { return }

    var merged = providers
    let enabledIndices = providers.indices.filter { enabledSet.contains(providers[$0]) }
    for (index, provider) in zip(enabledIndices, enabledProviders) {
      merged[index] = provider
    }
    defaults.set(merged.map(\.rawValue), forKey: storageKey)
  }

  static func reset(defaults: UserDefaults = .standard) {
    defaults.removeObject(forKey: storageKey)
  }

  private static func allProviders(defaults: UserDefaults) -> [ProviderID] {
    let stored = defaults.stringArray(forKey: storageKey) ?? []
    var seen: Set<ProviderID> = []
    let known = stored.compactMap(ProviderID.init(rawValue:)).filter { seen.insert($0).inserted }
    return known + ProviderID.allCases.filter { !seen.contains($0) }
  }
}
