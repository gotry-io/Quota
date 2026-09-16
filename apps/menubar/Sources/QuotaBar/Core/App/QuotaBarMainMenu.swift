import AppKit

/// The process's main menu.
///
/// Without an Edit menu, text fields in a regular window cannot paste — this is
/// the reason the menu exists.
enum QuotaBarMainMenu {
  @MainActor
  static func install() {
    let menu = make()
    NSApp.mainMenu = menu
    if let windowMenu = menu.items.first(where: { $0.submenu?.title == "Window" })?.submenu {
      NSApp.windowsMenu = windowMenu
    }
  }

  @MainActor
  static func make() -> NSMenu {
    let main = NSMenu()

    let appItem = NSMenuItem()
    appItem.submenu = applicationMenu()
    main.addItem(appItem)

    let editItem = NSMenuItem()
    editItem.submenu = editMenu()
    main.addItem(editItem)

    let windowItem = NSMenuItem()
    windowItem.submenu = windowMenu()
    main.addItem(windowItem)

    return main
  }

  @MainActor
  private static func applicationMenu() -> NSMenu {
    let menu = NSMenu(title: "QuotaBar")
    menu.addItem(
      withTitle: "About QuotaBar",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
      keyEquivalent: ""
    )
    menu.addItem(.separator())
    let updates = NSMenuItem(
      title: "Check for Updates…",
      action: #selector(Actions.checkForUpdates(_:)),
      keyEquivalent: ""
    )
    updates.target = Actions.shared
    menu.addItem(updates)
    menu.addItem(.separator())
    let settings = NSMenuItem(
      title: "Settings…",
      action: #selector(Actions.openSettings(_:)),
      keyEquivalent: ","
    )
    settings.target = Actions.shared
    menu.addItem(settings)
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Hide QuotaBar",
      action: #selector(NSApplication.hide(_:)),
      keyEquivalent: "h"
    )
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Quit QuotaBar",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    return menu
  }

  @MainActor
  private static func editMenu() -> NSMenu {
    let menu = NSMenu(title: "Edit")
    menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
    let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
    redo.keyEquivalentModifierMask = [.command, .shift]
    menu.addItem(redo)
    menu.addItem(.separator())
    menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Select All",
      action: #selector(NSText.selectAll(_:)),
      keyEquivalent: "a"
    )
    return menu
  }

  @MainActor
  private static func windowMenu() -> NSMenu {
    let menu = NSMenu(title: "Window")
    menu.addItem(
      withTitle: "Close",
      action: #selector(NSWindow.performClose(_:)),
      keyEquivalent: "w"
    )
    menu.addItem(
      withTitle: "Minimize",
      action: #selector(NSWindow.performMiniaturize(_:)),
      keyEquivalent: "m"
    )
    menu.addItem(.separator())
    let dashboard = NSMenuItem(
      title: "Dashboard",
      action: #selector(Actions.openDashboard(_:)),
      keyEquivalent: "d"
    )
    dashboard.target = Actions.shared
    menu.addItem(dashboard)
    let settings = NSMenuItem(
      title: "Settings",
      action: #selector(Actions.openSettings(_:)),
      keyEquivalent: ","
    )
    settings.target = Actions.shared
    menu.addItem(settings)
    return menu
  }

  @MainActor
  final class Actions: NSObject, NSMenuItemValidation {
    static let shared = Actions()

    @objc func checkForUpdates(_ sender: Any?) {
      QuotaBarUpdater.checkForUpdates()
    }

    @objc func openSettings(_ sender: Any?) {
      SettingsWindowController.shared.show()
    }

    @objc func openDashboard(_ sender: Any?) {
      // WP 7.7
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
      if menuItem.action == #selector(openDashboard(_:)) {
        return false  // WP 7.7
      }
      return true
    }
  }
}
