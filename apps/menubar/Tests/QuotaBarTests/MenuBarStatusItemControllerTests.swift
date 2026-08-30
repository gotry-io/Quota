import AppKit
import Foundation
import QuotaWire
import Testing

@testable import QuotaBar

@Test @MainActor
func automaticToOneProviderKeepsButtonAndPanel() throws {
  try withStatusItems { controller, defaults, a, _ in
    let oldButton = try #require(controller.button(for: .automatic))
    controller.panel.open(relativeTo: oldButton, id: .automatic)

    defaults.set(
      MenuBarProviderPreference.provider(a).rawValue,
      forKey: MenuBarProviderPreference.storageKey
    )
    controller.reconcile()

    #expect(controller.statusItemIDs == [.provider(a)])
    #expect(controller.button(for: .provider(a)) === oldButton)
    #expect(controller.panel.anchorID == .provider(a))
    #expect(controller.panel.isOpen)
  }
}

@Test @MainActor
func combinedToSeparateRebindsSlotAndAddsOne() throws {
  try withStatusItems(provider: { a, b in .providers([a, b]) }, arrangement: .combined) {
    controller, defaults, a, b in
    let oldButton = try #require(controller.button(for: .combined))
    controller.panel.open(relativeTo: oldButton, id: .combined)

    defaults.set(
      MenuBarArrangementPreference.separate.rawValue,
      forKey: MenuBarArrangementPreference.storageKey
    )
    controller.reconcile()

    #expect(controller.statusItemIDs == [.provider(a), .provider(b)])
    #expect(controller.button(for: .provider(a)) === oldButton)
    #expect(controller.panel.anchorID == .provider(a))
    #expect(controller.panel.isOpen)
  }
}

@Test @MainActor
func separateToCombinedKeepsAnchoredSlot() throws {
  try withStatusItems(provider: { a, b in .providers([a, b]) }, arrangement: .separate) {
    controller, defaults, _, b in
    let oldButton = try #require(controller.button(for: .provider(b)))
    controller.panel.open(relativeTo: oldButton, id: .provider(b))

    defaults.set(
      MenuBarArrangementPreference.combined.rawValue,
      forKey: MenuBarArrangementPreference.storageKey
    )
    controller.reconcile()

    #expect(controller.statusItemIDs == [.combined])
    #expect(controller.button(for: .combined) === oldButton)
    #expect(controller.panel.anchorID == .combined)
    #expect(controller.panel.isOpen)
  }
}

@Test @MainActor
func droppingTheAnchoredProviderReanchorsToSurvivor() throws {
  try withStatusItems(provider: { a, b in .providers([a, b]) }, arrangement: .separate) {
    controller, defaults, a, b in
    let oldA = try #require(controller.button(for: .provider(a)))
    let oldB = try #require(controller.button(for: .provider(b)))
    controller.panel.open(relativeTo: oldA, id: .provider(a))

    defaults.set(
      MenuBarProviderPreference.provider(b).rawValue,
      forKey: MenuBarProviderPreference.storageKey
    )
    controller.reconcile()

    #expect(controller.statusItemIDs == [.provider(b)])
    #expect(controller.button(for: .provider(b)) === oldB)
    #expect(controller.panel.anchorID == .provider(b))
    #expect(controller.panel.isOpen)
  }
}

@Test @MainActor
func styleChangeKeepsEveryItem() throws {
  try withStatusItems(provider: { a, b in .providers([a, b]) }, arrangement: .separate) {
    controller, defaults, a, b in
    let oldA = try #require(controller.button(for: .provider(a)))
    let oldB = try #require(controller.button(for: .provider(b)))

    defaults.set(MenuBarStylePreference.percent.rawValue, forKey: MenuBarStylePreference.storageKey)
    controller.reconcile()

    #expect(controller.statusItemIDs == [.provider(a), .provider(b)])
    #expect(controller.button(for: .provider(a)) === oldA)
    #expect(controller.button(for: .provider(b)) === oldB)
  }
}

/// Re-binding the item under the panel changes what it shows, not where the panel is.
@Test @MainActor
func backToAutomaticKeepsSlotAndPanelPosition() throws {
  try withStatusItems(provider: { a, _ in .provider(a) }) { controller, defaults, a, _ in
    let oldButton = try #require(controller.button(for: .provider(a)))
    controller.panel.open(relativeTo: oldButton, id: .provider(a))
    let frameBefore = controller.panel.panelFrame

    defaults.set(
      MenuBarProviderPreference.automatic.rawValue,
      forKey: MenuBarProviderPreference.storageKey
    )
    controller.reconcile()

    #expect(controller.statusItemIDs == [.automatic])
    #expect(controller.button(for: .automatic) === oldButton)
    #expect(controller.panel.anchorID == .automatic)
    #expect(controller.panel.panelFrame == frameBefore)
  }
}

/// A controller on its own defaults suite, seeded with a provider choice, torn down with its items.
@MainActor
private func withStatusItems(
  provider: (ProviderID, ProviderID) -> MenuBarProviderPreference = { _, _ in .automatic },
  arrangement: MenuBarArrangementPreference = .combined,
  _ body: (MenuBarStatusItemController, UserDefaults, ProviderID, ProviderID) throws -> Void
) throws {
  let suiteName = "quotabar.tests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let visible = ProviderDisplayOrder.enabledProviders(defaults: defaults)
  try #require(visible.count >= 2)
  let (a, b) = (visible[0], visible[1])
  defaults.set(provider(a, b).rawValue, forKey: MenuBarProviderPreference.storageKey)
  defaults.set(arrangement.rawValue, forKey: MenuBarArrangementPreference.storageKey)

  let controller = MenuBarStatusItemController(
    model: MenuBarViewModel(visualTestState: nil, errorMessage: nil, lastCheckedAt: nil),
    defaults: defaults
  )
  defer { controller.invalidate() }
  try body(controller, defaults, a, b)
}
