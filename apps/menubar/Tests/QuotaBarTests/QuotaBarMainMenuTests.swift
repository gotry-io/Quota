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
