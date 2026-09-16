import AppKit
import SwiftUI

/// The Dashboard window. Same AppKit hosting pattern as Settings: frame autosave, Esc to
/// close, and registration with `WindowActivation`.
@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
  static let shared = DashboardWindowController()

  private static let frameAutosaveName = "QuotaBarDashboardWindow"

  /// Opening Dashboard hides the panel so the activation-policy switch does not
  /// collapse it as a non-key window.
  var closePanel: () -> Void = {}

  private var model: MenuBarViewModel?
  private var window: NSWindow?
  private var hosting: NSHostingController<DashboardView>?

  var isPresented: Bool { window?.isVisible == true }

  func attach(model: MenuBarViewModel) {
    self.model = model
    hosting?.rootView = DashboardView(model: model)
  }

  func show() {
    closePanel()
    model?.loadQuotaHistory()
    let window = self.window ?? makeWindow()
    self.window = window
    WindowActivation.shared.register(window)
    window.makeKeyAndOrderFront(nil)
  }

  private func makeWindow() -> NSWindow {
    guard let model else {
      preconditionFailure("DashboardWindowController.attach(model:) must run before show().")
    }
    let hosting = NSHostingController(rootView: DashboardView(model: model))
    self.hosting = hosting
    let window = DashboardWindow(contentViewController: hosting)
    window.title = "QuotaBar Dashboard"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.titlebarAppearsTransparent = false
    window.contentMinSize = QuotaDesign.Layout.dashboardWindowMinSize
    window.level = .normal
    window.collectionBehavior = [.moveToActiveSpace, .fullScreenPrimary]
    window.isReleasedWhenClosed = false
    window.delegate = self
    if !window.setFrameUsingName(Self.frameAutosaveName) {
      window.setContentSize(QuotaDesign.Layout.dashboardWindowMinSize)
      window.center()
    }
    window.setFrameAutosaveName(Self.frameAutosaveName)
    return window
  }
}

/// Escape closes it like any other window; ⌘W is routed by the Window menu.
private final class DashboardWindow: NSWindow {
  override func cancelOperation(_ sender: Any?) {
    performClose(sender)
  }
}
