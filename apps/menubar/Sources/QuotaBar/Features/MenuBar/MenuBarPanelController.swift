import AppKit
import Observation
import QuotaWire
import SwiftUI

/// Panel-owned navigation toward an Overview provider, so a status-item click does not
/// write through the local-service view model.
@Observable
final class MenuBarPanelSession {
  private(set) var revealGeneration: UInt = 0
  private(set) var revealProvider: ProviderID?

  func reveal(provider: ProviderID) {
    revealProvider = provider
    revealGeneration += 1
  }
}

/// One panel for every status item. Clicking a second item moves it rather than opening another.
@MainActor
final class MenuBarPanelController: NSObject {
  private let model: MenuBarViewModel
  private let session = MenuBarPanelSession()
  private let panel: MenuBarPanel
  private var localMonitor: Any?
  private var globalMonitor: Any?
  private weak var anchorButton: NSStatusBarButton?

  private(set) var isOpen = false
  private(set) var anchorID: MenuBarStatusItemID?
  /// Windows belonging to QuotaBar's own status items, so a click on one is a toggle, not a dismiss.
  var statusItemWindows: () -> Set<NSWindow> = { [] }

  init(model: MenuBarViewModel) {
    self.model = model
    let root = MenuBarPanelRoot(model: model, session: session)
    let hosting = NSHostingView(rootView: root)
    hosting.frame = NSRect(
      x: 0,
      y: 0,
      width: QuotaDesign.Layout.panelWidth,
      height: QuotaDesign.Layout.panelMaxHeight
    )
    hosting.wantsLayer = true
    hosting.layer?.cornerRadius = QuotaDesign.Layout.floatingMenuCornerRadius
    hosting.layer?.masksToBounds = true

    let panel = MenuBarPanel(
      contentRect: hosting.frame,
      styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.isFloatingPanel = true
    panel.level = .statusBar
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.isMovableByWindowBackground = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.hasShadow = true
    panel.backgroundColor = .clear
    panel.isOpaque = false
    panel.becomesKeyOnlyIfNeeded = true
    panel.animationBehavior = .utilityWindow
    panel.contentView = hosting
    panel.setContentSize(hosting.frame.size)

    self.panel = panel
    super.init()
  }

  func toggle(
    relativeTo button: NSStatusBarButton,
    id: MenuBarStatusItemID,
    focusProvider: ProviderID?
  ) {
    if isOpen, anchorID == id {
      close()
      return
    }
    open(relativeTo: button, id: id)
    if let focusProvider {
      session.reveal(provider: focusProvider)
    }
  }

  func open(relativeTo button: NSStatusBarButton, id: MenuBarStatusItemID) {
    if anchorButton !== button {
      anchorButton?.highlight(false)
    }
    anchorButton = button
    anchorID = id
    position(relativeTo: button)
    if !isOpen {
      isOpen = true
      panel.orderFrontRegardless()
      panel.makeKey()
      startMonitors()
    }
    // Mouse-up ends the button's own highlight; keep it on while the panel is up.
    DispatchQueue.main.async { [weak self] in
      self?.anchorButton?.highlight(true)
    }
  }

  func close() {
    guard isOpen else { return }
    isOpen = false
    stopMonitors()
    anchorButton?.highlight(false)
    anchorButton = nil
    anchorID = nil
    panel.orderOut(nil)
  }

  func invalidate() {
    close()
  }

  /// Keep the open panel under its item when the item's width changed, without re-highlighting.
  func repositionIfOpen() {
    guard isOpen, let anchorButton else { return }
    position(relativeTo: anchorButton)
  }

  private func position(relativeTo button: NSStatusBarButton) {
    guard let buttonWindow = button.window else { return }
    let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    let size = panel.frame.size
    let screenFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
    var origin = NSPoint(
      x: buttonFrame.maxX - size.width,
      y: buttonFrame.minY - size.height - 4
    )
    if let screenFrame {
      origin.x = min(max(origin.x, screenFrame.minX), screenFrame.maxX - size.width)
      if origin.y < screenFrame.minY {
        origin.y = buttonFrame.maxY + 4
      }
    }
    panel.setFrameOrigin(origin)
  }

  private func startMonitors() {
    stopMonitors()
    localMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .keyDown]
    ) { [weak self] event in
      guard let self else { return event }
      return self.handleLocalEvent(event)
    }
    globalMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown]
    ) { [weak self] _ in
      self?.close()
    }
  }

  private func stopMonitors() {
    if let localMonitor {
      NSEvent.removeMonitor(localMonitor)
      self.localMonitor = nil
    }
    if let globalMonitor {
      NSEvent.removeMonitor(globalMonitor)
      self.globalMonitor = nil
    }
  }

  private func handleLocalEvent(_ event: NSEvent) -> NSEvent? {
    if event.type == .keyDown, event.keyCode == 53 {
      close()
      return nil
    }
    guard event.type == .leftMouseDown || event.type == .rightMouseDown else { return event }
    if event.window === panel { return event }
    if let window = event.window, statusItemWindows().contains(window) { return event }
    close()
    return event
  }
}

private final class MenuBarPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

private struct MenuBarPanelRoot: View {
  @Bindable var model: MenuBarViewModel
  var session: MenuBarPanelSession

  var body: some View {
    MenuBarContentView(model: model, panelSession: session)
      .background(.regularMaterial)
  }
}
