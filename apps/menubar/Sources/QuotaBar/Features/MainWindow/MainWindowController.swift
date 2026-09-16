import AppKit
import SwiftUI

/// Sidebar pages of the main window: a Quota group and a Settings group.
enum MainPage: String, CaseIterable, Identifiable, Hashable {
  static let storageKey = "main.page"
  static let agentsProviderStorageKey = "settings.agents.provider"

  case quota
  case today
  case usage
  case account
  case agents
  case notifications
  case menuBar
  case general
  case support

  var id: MainPage { self }

  static var quotaGroup: [MainPage] { [.quota, .today, .usage] }
  static var settingsGroup: [MainPage] {
    [.account, .agents, .notifications, .menuBar, .general, .support]
  }

  var isQuotaGroup: Bool {
    switch self {
    case .quota, .today, .usage: true
    default: false
    }
  }

  var isSettings: Bool { !isQuotaGroup }

  var title: String {
    switch self {
    case .quota: "Quota"
    case .today: "Today"
    case .usage: "Usage"
    case .account: "Account"
    case .agents: "Agents"
    case .notifications: "Notifications"
    case .menuBar: "Menu Bar"
    case .general: "General"
    case .support: "Support"
    }
  }

  /// SF Symbols for the main window sidebar.
  var systemImage: String {
    switch self {
    case .quota: "chart.xyaxis.line"
    case .today: "sun.max"
    case .usage: "chart.bar.xaxis"
    case .account: "person.crop.circle"
    case .agents: "cpu"
    case .notifications: "bell"
    case .menuBar: "menubar.rectangle"
    case .general: "gearshape"
    case .support: "questionmark.circle"
    }
  }

  /// Missing or unknown `main.page` lands on Quota.
  static var resolved: MainPage { stored ?? .quota }

  static var stored: MainPage? {
    UserDefaults.standard.string(forKey: storageKey).flatMap(MainPage.init(rawValue:))
  }

  /// Settings… opens the last Settings page when that is what is stored; otherwise Account.
  static func settingsLandingPage(_ stored: MainPage?) -> MainPage {
    if let stored, stored.isSettings { return stored }
    return .account
  }
}

/// The main window. Same AppKit hosting pattern as the windows it replaces: frame autosave,
/// Esc to close, and registration with `WindowActivation`.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
  static let shared = MainWindowController()

  private static let frameAutosaveName = "QuotaBarMainWindow"

  /// Opening the main window hides the panel so the activation-policy switch does not
  /// collapse it as a non-key window.
  var closePanel: () -> Void = {}

  private var model: MenuBarViewModel?
  private var window: NSWindow?
  private var hosting: NSHostingController<MainWindowView>?

  var isPresented: Bool { window?.isVisible == true }

  func attach(model: MenuBarViewModel) {
    self.model = model
    hosting?.rootView = MainWindowView(model: model)
  }

  func show(page: MainPage? = nil) {
    closePanel()
    if let page {
      UserDefaults.standard.set(page.rawValue, forKey: MainPage.storageKey)
    }
    model?.loadQuotaHistory()
    let window = self.window ?? makeWindow()
    self.window = window
    WindowActivation.shared.register(window)
    window.makeKeyAndOrderFront(nil)
  }

  func showSettings() {
    show(page: MainPage.settingsLandingPage(MainPage.stored))
  }

  private func makeWindow() -> NSWindow {
    guard let model else {
      preconditionFailure("MainWindowController.attach(model:) must run before show().")
    }
    let hosting = NSHostingController(rootView: MainWindowView(model: model))
    self.hosting = hosting
    let window = MainWindow(contentViewController: hosting)
    window.title = "QuotaBar"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.titlebarAppearsTransparent = false
    window.contentMinSize = QuotaDesign.Layout.mainWindowMinSize
    window.level = .normal
    window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
    window.isReleasedWhenClosed = false
    window.delegate = self
    if !window.setFrameUsingName(Self.frameAutosaveName) {
      window.setContentSize(QuotaDesign.Layout.mainWindowMinSize)
      window.center()
    }
    window.setFrameAutosaveName(Self.frameAutosaveName)
    return window
  }
}

/// Escape closes it like any other window; ⌘W is routed by the Window menu.
private final class MainWindow: NSWindow {
  override func cancelOperation(_ sender: Any?) {
    performClose(sender)
  }
}
