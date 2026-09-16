import AppKit
import Testing

@testable import QuotaBar

@Test @MainActor
func mainMenuHasTheRegularAppMenus() {
  let menu = QuotaBarMainMenu.make()
  #expect(
    menu.items.compactMap(\.submenu?.title) == [
      "QuotaBar", "File", "Edit", "View", "Window", "Help",
    ]
  )
}

@Test @MainActor
func applicationMenuHasAboutUpdatesSettingsServicesHideAndQuit() throws {
  let app = try submenu(QuotaBarMainMenu.make(), titled: "QuotaBar")
  #expect(titles(app) == [
    "About QuotaBar",
    "",
    "Check for Updates…",
    "",
    "Settings…",
    "",
    "Services",
    "",
    "Hide QuotaBar",
    "Hide Others",
    "Show All",
    "",
    "Quit QuotaBar",
  ])

  let settings = try item(app, titled: "Settings…")
  #expect(settings.action == #selector(QuotaBarMainMenu.Actions.openSettings(_:)))
  #expect(settings.keyEquivalent == ",")
  #expect(settings.target === QuotaBarMainMenu.Actions.shared)

  let hide = try item(app, titled: "Hide QuotaBar")
  #expect(hide.action == #selector(NSApplication.hide(_:)))
  #expect(hide.keyEquivalent == "h")

  let hideOthers = try item(app, titled: "Hide Others")
  #expect(hideOthers.action == #selector(NSApplication.hideOtherApplications(_:)))
  #expect(hideOthers.keyEquivalent == "h")
  #expect(hideOthers.keyEquivalentModifierMask == [.command, .option])

  let quit = try item(app, titled: "Quit QuotaBar")
  #expect(quit.action == #selector(NSApplication.terminate(_:)))
  #expect(quit.keyEquivalent == "q")

  let services = try item(app, titled: "Services")
  #expect(services.submenu?.title == "Services")
}

@Test @MainActor
func fileMenuClosesWithCommandW() throws {
  let file = try submenu(QuotaBarMainMenu.make(), titled: "File")
  let close = try item(file, titled: "Close")
  #expect(close.action == #selector(NSWindow.performClose(_:)))
  #expect(close.keyEquivalent == "w")
}

@Test @MainActor
func mainMenuHasEditMenuWithPaste() throws {
  let edit = try submenu(QuotaBarMainMenu.make(), titled: "Edit")
  let paste = try item(edit, titled: "Paste")
  #expect(paste.action == #selector(NSText.paste(_:)))
  #expect(paste.keyEquivalent == "v")
}

@Test @MainActor
func viewMenuCommand1Through3SelectQuotaTodayAndUsage() throws {
  let previous = UserDefaults.standard.object(forKey: MainPage.storageKey)
  defer {
    if let previous {
      UserDefaults.standard.set(previous, forKey: MainPage.storageKey)
    } else {
      UserDefaults.standard.removeObject(forKey: MainPage.storageKey)
    }
  }

  let view = try submenu(QuotaBarMainMenu.make(), titled: "View")
  let quota = try item(view, titled: "Quota")
  let today = try item(view, titled: "Today")
  let usage = try item(view, titled: "Usage")
  #expect(quota.action == #selector(QuotaBarMainMenu.Actions.showQuota(_:)))
  #expect(today.action == #selector(QuotaBarMainMenu.Actions.showToday(_:)))
  #expect(usage.action == #selector(QuotaBarMainMenu.Actions.showUsage(_:)))
  #expect(quota.keyEquivalent == "1")
  #expect(today.keyEquivalent == "2")
  #expect(usage.keyEquivalent == "3")

  QuotaBarMainMenu.Actions.shared.showQuota(nil)
  #expect(MainPage.stored == .quota)
  QuotaBarMainMenu.Actions.shared.showToday(nil)
  #expect(MainPage.stored == .today)
  QuotaBarMainMenu.Actions.shared.showUsage(nil)
  #expect(MainPage.stored == .usage)
}

@Test @MainActor
func viewMenuRefreshAndFullScreenUseTheStandardShortcuts() throws {
  let view = try submenu(QuotaBarMainMenu.make(), titled: "View")
  let refresh = try item(view, titled: "Refresh")
  #expect(refresh.action == #selector(QuotaBarMainMenu.Actions.refresh(_:)))
  #expect(refresh.keyEquivalent == "r")
  #expect(refresh.target === QuotaBarMainMenu.Actions.shared)

  let fullScreen = try item(view, titled: "Enter Full Screen")
  #expect(fullScreen.action == #selector(NSWindow.toggleFullScreen(_:)))
  #expect(fullScreen.keyEquivalent == "f")
  #expect(fullScreen.keyEquivalentModifierMask == [.command, .control])
}

@Test @MainActor
func windowMenuBringsTheMainWindowFrontWithoutAShortcut() throws {
  let window = try submenu(QuotaBarMainMenu.make(), titled: "Window")
  #expect(titles(window) == [
    "Minimize",
    "Zoom",
    "",
    "QuotaBar",
    "",
    "Bring All to Front",
  ])

  let minimize = try item(window, titled: "Minimize")
  #expect(minimize.action == #selector(NSWindow.performMiniaturize(_:)))
  #expect(minimize.keyEquivalent == "m")

  let zoom = try item(window, titled: "Zoom")
  #expect(zoom.action == #selector(NSWindow.performZoom(_:)))
  #expect(zoom.keyEquivalent.isEmpty)

  let mainWindow = try item(window, titled: "QuotaBar")
  #expect(mainWindow.action == #selector(QuotaBarMainMenu.Actions.openMainWindow(_:)))
  #expect(mainWindow.keyEquivalent.isEmpty)
  #expect(mainWindow.isEnabled)

  let bringAll = try item(window, titled: "Bring All to Front")
  #expect(bringAll.action == #selector(NSApplication.arrangeInFront(_:)))
}

@Test @MainActor
func helpMenuOpensTheWebsiteAndFeedbackURLs() throws {
  let help = try submenu(QuotaBarMainMenu.make(), titled: "Help")
  let quotaHelp = try item(help, titled: "QuotaBar Help")
  #expect(quotaHelp.action == #selector(QuotaBarMainMenu.Actions.openHelp(_:)))
  #expect(quotaHelp.target === QuotaBarMainMenu.Actions.shared)
  #expect(AppMetadata.websiteURL.absoluteString == "https://quota.gotry.io")

  let feedback = try item(help, titled: "Feedback")
  #expect(feedback.action == #selector(QuotaBarMainMenu.Actions.openFeedback(_:)))
  #expect(feedback.target === QuotaBarMainMenu.Actions.shared)
  #expect(AppMetadata.feedbackURL.absoluteString == "https://github.com/gotry-io/Quota/issues")
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

private func titles(_ menu: NSMenu) -> [String] {
  menu.items.map { $0.isSeparatorItem ? "" : $0.title }
}

private func allItems(in menu: NSMenu) -> [NSMenuItem] {
  menu.items.flatMap { item -> [NSMenuItem] in
    if let submenu = item.submenu {
      return allItems(in: submenu)
    }
    return [item]
  }
}
