import Foundation
import Testing

@testable import QuotaBar

struct ProviderDisplayOrderTests {
  @Test
  func persistsEnabledOrderAndPreservesDisabledSlots() throws {
    let suiteName = "QuotaBarTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    for provider in ProviderID.allCases {
      ProviderVisibility.setVisible(provider, provider.defaultVisible, defaults: defaults)
    }

    ProviderDisplayOrder.saveEnabledOrder([.grok, .codex, .claude], defaults: defaults)
    #expect(ProviderDisplayOrder.enabledProviders(defaults: defaults) == [.grok, .codex, .claude])

    ProviderVisibility.setVisible(.codex, false, defaults: defaults)
    ProviderVisibility.setVisible(.openrouter, true, defaults: defaults)
    ProviderDisplayOrder.saveEnabledOrder([.openrouter, .grok, .claude], defaults: defaults)
    ProviderVisibility.setVisible(.codex, true, defaults: defaults)

    #expect(
      ProviderDisplayOrder.enabledProviders(defaults: defaults)
        == [.openrouter, .codex, .grok, .claude]
    )
  }

  @Test
  func ignoresUnknownAndDuplicateStoredIDs() throws {
    let suiteName = "QuotaBarTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(["grok", "unknown", "grok", "codex"], forKey: ProviderDisplayOrder.storageKey)
    for provider in ProviderID.allCases {
      ProviderVisibility.setVisible(provider, true, defaults: defaults)
    }

    #expect(
      ProviderDisplayOrder.enabledProviders(defaults: defaults)
        == [.grok, .codex, .claude, .openrouter, .deepseek, .kimi, .litellm, .cursor]
    )
  }
}
