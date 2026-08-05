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

  static func enabledSet(defaults: UserDefaults = .standard) -> Set<ProviderID> {
    Set(ProviderID.allCases.filter { isVisible($0, defaults: defaults) })
  }
}
