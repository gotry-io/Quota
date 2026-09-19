import AppKit
import QuotaPresentation
import SwiftUI

/// Sidebar pages of the main window: Quota, Usage, and a Settings group.
enum MainPage: String, CaseIterable, Identifiable, Hashable {
  static let storageKey = "main.page"
  static let agentsProviderStorageKey = "settings.agents.provider"
  /// Shipped `main.page` value for the Today page, rewritten to `usage`.
  static let legacyTodayRawValue = "today"

  case quota
  case usage
  case account
  case agents
  case notifications
  case menuBar
  case general
  case support

  var id: MainPage { self }

  static var quotaGroup: [MainPage] { [.quota] }
  static var usageGroup: [MainPage] { [.usage] }
  static var settingsGroup: [MainPage] {
    [.account, .agents, .notifications, .menuBar, .general, .support]
  }

  var isQuotaGroup: Bool {
    switch self {
    case .quota, .usage: true
    default: false
    }
  }

  var isSettings: Bool { !isQuotaGroup }

  var title: String {
    switch self {
    case .quota: "Quota"
    case .usage: "Usage"
    case .account: "Account"
    case .agents: "Agents"
    case .notifications: "Notifications"
    case .menuBar: "Menu Bar"
    case .general: "General"
    case .support: "Support"
    }
  }

  /// SF Symbols for the main window sidebar. Quota and Usage match the iOS tabs.
  var systemImage: String {
    switch self {
    case .quota: "gauge.with.dots.needle.33percent"
    case .usage: "chart.bar"
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
    migrateLegacyStoredPage()
    return UserDefaults.standard.string(forKey: storageKey).flatMap(MainPage.init(rawValue:))
  }

  /// Rewrites a shipped `today` value to `usage` so the last page is not dropped.
  static func migrateLegacyStoredPage(in defaults: UserDefaults = .standard) {
    guard defaults.string(forKey: storageKey) == legacyTodayRawValue else { return }
    defaults.set(MainPage.usage.rawValue, forKey: storageKey)
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

  /// Open in the sense a Quit cares about: on screen, or miniaturized into the Dock. A
  /// miniaturized window is not `isVisible`, but it is still the app's window, so a plain Quit
  /// closes it rather than ending the process behind it.
  var isOpen: Bool {
    guard let window else { return false }
    return window.isVisible || window.isMiniaturized
  }

  func attach(model: MenuBarViewModel) {
    self.model = model
    hosting?.rootView = MainWindowView(model: model)
  }

  func show(page: MainPage? = nil, usagePeriod: UsagePeriodSelection? = nil) {
    MainPage.migrateLegacyStoredPage()
    closePanel()
    if let page {
      UserDefaults.standard.set(page.rawValue, forKey: MainPage.storageKey)
    }
    guard let model else { return }
    if let usagePeriod {
      model.usage.selectUsagePeriod(usagePeriod)
    }
    model.usage.loadQuotaHistory()
    let window = self.window ?? makeWindow()
    self.window = window
    WindowActivation.shared.register(window)
    window.makeKeyAndOrderFront(nil)
  }

  func showSettings() {
    show(page: MainPage.settingsLandingPage(MainPage.stored))
  }

  /// Panel footer Today line and the old Today entry points: Usage with the Today period.
  func showUsageToday() {
    show(page: .usage, usagePeriod: .today)
  }

  /// Same path as File › Close / ⌘W, so `WindowActivation` drops to accessory.
  func close() {
    window?.performClose(nil)
  }

  func refresh() {
    guard let model, !model.isRefreshing else { return }
    Task { @MainActor in
      await model.refresh()
      model.usage.loadQuotaHistory()
    }
  }

  var canRefresh: Bool { model?.isRefreshing != true }

  var canExportUsage: Bool {
    guard let model else { return true }
    return model.usage.canExportUsage
  }

  func exportUsage() {
    guard let model,
      let input = model.usage.usageExportInput(now: Date(), appVersion: AppMetadata.version)
    else { return }
    show(page: .usage)
    UsageExportPanel.present(input: input, on: window)
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
    window.isExcludedFromWindowsMenu = true
    window.delegate = self
    if !window.setFrameUsingName(Self.frameAutosaveName) {
      window.setContentSize(QuotaDesign.Layout.mainWindowMinSize)
      window.center()
    }
    window.setFrameAutosaveName(Self.frameAutosaveName)
    return window
  }
}

/// Escape closes it like any other window; ⌘W is routed by File › Close.
private final class MainWindow: NSWindow {
  override func cancelOperation(_ sender: Any?) {
    performClose(sender)
  }
}
