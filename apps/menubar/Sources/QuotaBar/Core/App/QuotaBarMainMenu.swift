import AppKit

/// The process's main menu: a regular-app menu bar.
enum QuotaBarMainMenu {
  @MainActor
  static func install() {
    let menu = make()
    NSApp.mainMenu = menu
    NSApp.windowsMenu = firstSubmenu(menu, titled: "Window")
    NSApp.helpMenu = firstSubmenu(menu, titled: "Help")
    if let app = firstSubmenu(menu, titled: "QuotaBar") {
      NSApp.servicesMenu = app.items.first { $0.title == "Services" }?.submenu
    }
  }

  @MainActor
  static func make() -> NSMenu {
    let main = NSMenu()
    addSubmenu(applicationMenu(), to: main)
    addSubmenu(fileMenu(), to: main)
    addSubmenu(editMenu(), to: main)
    addSubmenu(viewMenu(), to: main)
    addSubmenu(windowMenu(), to: main)
    addSubmenu(helpMenu(), to: main)
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
    menu.addItem(targetedItem("Check for Updates…", #selector(Actions.checkForUpdates(_:))))
    menu.addItem(.separator())
    menu.addItem(targetedItem("Settings…", #selector(Actions.openSettings(_:)), ","))
    menu.addItem(.separator())
    let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    services.submenu = NSMenu(title: "Services")
    menu.addItem(services)
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Hide QuotaBar",
      action: #selector(NSApplication.hide(_:)),
      keyEquivalent: "h"
    )
    let hideOthers = NSMenuItem(
      title: "Hide Others",
      action: #selector(NSApplication.hideOtherApplications(_:)),
      keyEquivalent: "h"
    )
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    menu.addItem(hideOthers)
    menu.addItem(
      withTitle: "Show All",
      action: #selector(NSApplication.unhideAllApplications(_:)),
      keyEquivalent: ""
    )
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Quit QuotaBar",
      action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q"
    )
    let quitCompletely = NSMenuItem(
      title: "Quit QuotaBar Completely",
      action: #selector(Actions.quitCompletely(_:)),
      keyEquivalent: "q"
    )
    quitCompletely.keyEquivalentModifierMask = [.command, .option]
    quitCompletely.target = Actions.shared
    menu.addItem(quitCompletely)
    return menu
  }

  @MainActor
  private static func fileMenu() -> NSMenu {
    let menu = NSMenu(title: "File")
    menu.addItem(
      withTitle: "Close",
      action: #selector(NSWindow.performClose(_:)),
      keyEquivalent: "w"
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
  private static func viewMenu() -> NSMenu {
    let menu = NSMenu(title: "View")
    menu.addItem(targetedItem("Quota", #selector(Actions.showQuota(_:)), "1"))
    menu.addItem(targetedItem("Usage", #selector(Actions.showUsage(_:)), "2"))
    menu.addItem(targetedItem("Settings", #selector(Actions.openSettings(_:)), "3"))
    menu.addItem(.separator())
    menu.addItem(targetedItem("Refresh", #selector(Actions.refresh(_:)), "r"))
    menu.addItem(.separator())
    let fullScreen = NSMenuItem(
      title: "Enter Full Screen",
      action: #selector(NSWindow.toggleFullScreen(_:)),
      keyEquivalent: "f"
    )
    fullScreen.keyEquivalentModifierMask = [.command, .control]
    menu.addItem(fullScreen)
    return menu
  }

  @MainActor
  private static func windowMenu() -> NSMenu {
    let menu = NSMenu(title: "Window")
    menu.addItem(
      withTitle: "Minimize",
      action: #selector(NSWindow.performMiniaturize(_:)),
      keyEquivalent: "m"
    )
    menu.addItem(
      withTitle: "Zoom",
      action: #selector(NSWindow.performZoom(_:)),
      keyEquivalent: ""
    )
    menu.addItem(.separator())
    menu.addItem(targetedItem("QuotaBar", #selector(Actions.openMainWindow(_:))))
    menu.addItem(.separator())
    menu.addItem(
      withTitle: "Bring All to Front",
      action: #selector(NSApplication.arrangeInFront(_:)),
      keyEquivalent: ""
    )
    return menu
  }

  @MainActor
  private static func helpMenu() -> NSMenu {
    let menu = NSMenu(title: "Help")
    menu.addItem(targetedItem("QuotaBar Help", #selector(Actions.openHelp(_:))))
    menu.addItem(targetedItem("Feedback", #selector(Actions.openFeedback(_:))))
    return menu
  }

  @MainActor
  private static func targetedItem(
    _ title: String,
    _ action: Selector,
    _ keyEquivalent: String = ""
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.target = Actions.shared
    return item
  }

  @MainActor
  private static func addSubmenu(_ submenu: NSMenu, to menu: NSMenu) {
    let item = NSMenuItem()
    item.submenu = submenu
    menu.addItem(item)
  }

  @MainActor
  private static func firstSubmenu(_ menu: NSMenu, titled title: String) -> NSMenu? {
    menu.items.first { $0.submenu?.title == title }?.submenu
  }

  @MainActor
  final class Actions: NSObject, NSMenuItemValidation {
    static let shared = Actions()

    @objc func checkForUpdates(_ sender: Any?) {
      QuotaBarUpdater.checkForUpdates()
    }

    @objc func openSettings(_ sender: Any?) {
      MainWindowController.shared.showSettings()
    }

    @objc func openMainWindow(_ sender: Any?) {
      MainWindowController.shared.show()
    }

    @objc func showQuota(_ sender: Any?) {
      MainWindowController.shared.show(page: .quota)
    }

    @objc func showUsage(_ sender: Any?) {
      MainWindowController.shared.show(page: .usage)
    }

    @objc func refresh(_ sender: Any?) {
      MainWindowController.shared.refresh()
    }

    @objc func openHelp(_ sender: Any?) {
      NSWorkspace.shared.open(AppMetadata.websiteURL)
    }

    @objc func openFeedback(_ sender: Any?) {
      NSWorkspace.shared.open(AppMetadata.feedbackURL)
    }

    @objc func quitCompletely(_ sender: Any?) {
      QuitIntent.requestFullQuit()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
      if menuItem.action == #selector(refresh(_:)) {
        return MainWindowController.shared.canRefresh
      }
      return true
    }
  }
}
