import AppKit
import SwiftUI

/// Sidebar pages of the Settings window. Menu Bar is one form; other pages are filled later.
enum SettingsPage: String, CaseIterable, Identifiable, Hashable {
  case account
  case agents
  case notifications
  case menuBar
  case general
  case support

  var id: SettingsPage { self }

  var title: String {
    switch self {
    case .account: "Account"
    case .agents: "Agents"
    case .notifications: "Notifications"
    case .menuBar: "Menu Bar"
    case .general: "General"
    case .support: "Support"
    }
  }

  /// SF Symbols matching the current Settings home rows for these sections.
  var systemImage: String {
    switch self {
    case .account: "person.crop.circle"
    case .agents: "cpu"
    case .notifications: "bell"
    case .menuBar: "menubar.rectangle"
    case .general: "gearshape"
    case .support: "questionmark.circle"
    }
  }
}

struct SettingsWindowView: View {
  var model: MenuBarViewModel?
  var initialPage: SettingsPage?
  var now: Date?
  @AppStorage("settings.page") private var page = SettingsPage.account
  @State private var columnVisibility: NavigationSplitViewVisibility = .all

  var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
      List(
        SettingsPage.allCases,
        selection: Binding<SettingsPage?>(
          get: { page },
          set: { newValue in
            if let newValue {
              page = newValue
            }
          }
        )
      ) { item in
        Label(item.title, systemImage: item.systemImage)
          .tag(item)
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(
        min: QuotaDesign.Layout.windowSidebarWidth,
        ideal: QuotaDesign.Layout.windowSidebarWidth,
        max: QuotaDesign.Layout.windowSidebarWidth
      )
    } detail: {
      switch page {
      case .menuBar:
        NavigationStack {
          MenuBarSettingsView(model: model, now: now)
            .navigationTitle(SettingsPage.menuBar.title)
        }
      default:
        Text(page.title)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(
      minWidth: QuotaDesign.Layout.settingsWindowMinSize.width,
      minHeight: QuotaDesign.Layout.settingsWindowMinSize.height
    )
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear {
      if let initialPage {
        page = initialPage
      }
    }
  }
}

/// The Settings window. Modelled on `BrowserAccessWindowController`: an AppKit
/// `NSWindow` hosting SwiftUI, with frame autosave and Esc to close.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
  static let shared = SettingsWindowController()

  private static let frameAutosaveName = "QuotaBarSettingsWindow"

  /// Opening Settings hides the panel so the activation-policy switch does not
  /// collapse it as a non-key window.
  var closePanel: () -> Void = {}

  /// The same view model the panel uses; Menu Bar preview reads current quota from it.
  var model: MenuBarViewModel?

  private var window: NSWindow?

  var isPresented: Bool { window?.isVisible == true }

  func show() {
    closePanel()
    let window = self.window ?? makeWindow()
    self.window = window
    WindowActivation.shared.register(window)
    window.makeKeyAndOrderFront(nil)
  }

  private func makeWindow() -> NSWindow {
    let hosting = NSHostingController(rootView: SettingsWindowView(model: model))
    let window = SettingsWindow(contentViewController: hosting)
    window.title = "QuotaBar Settings"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.titlebarAppearsTransparent = false
    window.contentMinSize = QuotaDesign.Layout.settingsWindowMinSize
    window.level = .normal
    window.collectionBehavior = [.moveToActiveSpace]
    window.isReleasedWhenClosed = false
    window.delegate = self
    if !window.setFrameUsingName(Self.frameAutosaveName) {
      window.setContentSize(QuotaDesign.Layout.settingsWindowMinSize)
      window.center()
    }
    window.setFrameAutosaveName(Self.frameAutosaveName)
    return window
  }
}

/// Escape closes it like any other window; ⌘W is routed by the Window menu.
private final class SettingsWindow: NSWindow {
  override func cancelOperation(_ sender: Any?) {
    performClose(sender)
  }
}
