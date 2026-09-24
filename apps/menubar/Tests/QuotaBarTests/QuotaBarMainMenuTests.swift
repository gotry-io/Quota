import AppKit
import Testing

@testable import QuotaBar

@Test @MainActor
func mainMenuHasEditMenuWithPaste() throws {
  let edit = try submenu(QuotaBarMainMenu.make(), titled: "Edit")
  let paste = try item(edit, titled: "Paste")
  #expect(paste.action == #selector(NSText.paste(_:)))
  #expect(paste.keyEquivalent == "v")
}

@Test @MainActor
func everyTargetedMenuItemValidates() {
  let menu = QuotaBarMainMenu.make()
  let actions = QuotaBarMainMenu.Actions.shared
  let targeted = allItems(in: menu).filter { $0.target != nil && $0.action != nil }
  #expect(!targeted.isEmpty)
  for item in targeted {
    #expect(item.target === actions)
    #expect(actions.responds(to: item.action!))
    #expect(actions.validateMenuItem(item))
  }
}

private func submenu(_ menu: NSMenu, titled title: String) throws -> NSMenu {
  try #require(menu.items.first { $0.submenu?.title == title }?.submenu)
}

private func item(_ menu: NSMenu, titled title: String) throws -> NSMenuItem {
  try #require(menu.items.first { $0.title == title })
}

private func allItems(in menu: NSMenu) -> [NSMenuItem] {
  menu.items.flatMap { item -> [NSMenuItem] in
    if let submenu = item.submenu {
      return allItems(in: submenu)
    }
    return [item]
  }
}
