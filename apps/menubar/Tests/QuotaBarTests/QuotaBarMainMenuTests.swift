import AppKit
import Testing

@testable import QuotaBar

@Test @MainActor
func mainMenuHasEditMenuWithPaste() throws {
  let menu = QuotaBarMainMenu.make()
  let edit = try #require(menu.items.first { $0.submenu?.title == "Edit" }?.submenu)
  let paste = try #require(edit.items.first { $0.title == "Paste" })
  #expect(paste.action == #selector(NSText.paste(_:)))
  #expect(paste.keyEquivalent == "v")
}

@Test @MainActor
func windowMenuOpensDashboardWithCommandD() throws {
  let menu = QuotaBarMainMenu.make()
  let window = try #require(menu.items.first { $0.submenu?.title == "Window" }?.submenu)
  let dashboard = try #require(window.items.first { $0.title == "Dashboard" })
  #expect(dashboard.action == #selector(QuotaBarMainMenu.Actions.openDashboard(_:)))
  #expect(dashboard.keyEquivalent == "d")
  #expect(dashboard.isEnabled)
}
