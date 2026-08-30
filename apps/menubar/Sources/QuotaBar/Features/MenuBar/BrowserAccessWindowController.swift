import AppKit
import CoreGraphics
import Observation
import SwiftUI
import SweetCookieKit

/// What the Browser Access window shows: every installed browser, the grant each still needs,
/// and the one step this session is in the middle of.
struct BrowserAccessGrantSnapshot: Equatable, Sendable {
  var statuses: [BrowserAccessStatus]
  var awaitingRelaunch: Bool
  var keychainPromptBrowser: Browser?

  var needs: [BrowserAccessNeed] { statuses.compactMap(\.need) }
  var hasOutstandingGrants: Bool { !needs.isEmpty }
}

@MainActor
protocol BrowserAccessGrantPresenting: AnyObject {
  var handler: (any BrowserAccessGrantHandling)? { get set }
  var isPresented: Bool { get }
  /// Brings the window forward, activating QuotaBar so it takes keyboard focus.
  func present(_ snapshot: BrowserAccessGrantSnapshot)
  /// Redraws an open window; closes it once nothing is outstanding. Never opens one.
  func update(_ snapshot: BrowserAccessGrantSnapshot)
  func dismiss()
  func openFullDiskAccessSettings()
}

@MainActor
protocol BrowserAccessGrantHandling: AnyObject {
  func browserAccessGrantDidRequestFullDiskAccess()
  func browserAccessGrantDidRequestKeychain(_ browser: Browser)
  func browserAccessGrantDidRequestRelaunch()
  /// The QuotaBar icon was dropped on System Settings: the grant lands on the next launch.
  func browserAccessGrantDidDropIntoFullDiskAccess()
  func browserAccessGrantDidDismiss()
}

@MainActor
protocol QuotaBarRelaunching: AnyObject {
  func relaunch()
}

@MainActor
final class WorkspaceQuotaBarRelauncher: QuotaBarRelaunching {
  func relaunch() {
    let path = Bundle.main.bundlePath
    let pid = ProcessInfo.processInfo.processIdentifier
    let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
      "-c",
      "while /bin/ps -p \(pid) >/dev/null 2>&1; do /bin/sleep 0.2; done; /usr/bin/open '\(escaped)'",
    ]
    try? process.run()
    NSApp.terminate(nil)
  }
}

@MainActor
final class NoOpQuotaBarRelauncher: QuotaBarRelaunching {
  func relaunch() {}
}

/// The Browser Access window. It is a window rather than a page in the menu extra because the
/// extra closes on the click in System Settings that granting Full Disk Access needs, and the
/// QuotaBar icon has to be dragged from somewhere that stays open. It floats, keeps the place
/// the person last put it, and never moves itself.
@MainActor
final class BrowserAccessWindowController: NSObject, BrowserAccessGrantPresenting,
  NSWindowDelegate
{
  private static let frameAutosaveName = "QuotaBarBrowserAccess"

  weak var handler: (any BrowserAccessGrantHandling)?

  private let state = BrowserAccessWindowState()
  private var window: NSWindow?

  var isPresented: Bool { window?.isVisible == true }

  func present(_ snapshot: BrowserAccessGrantSnapshot) {
    state.snapshot = snapshot
    let window = self.window ?? makeWindow()
    self.window = window
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }

  func update(_ snapshot: BrowserAccessGrantSnapshot) {
    state.snapshot = snapshot
    if !snapshot.hasOutstandingGrants {
      dismiss()
    }
  }

  func dismiss() {
    window?.orderOut(nil)
  }

  func openFullDiskAccessSettings() {
    SystemSettingsLinks.openFullDiskAccess()
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    handler?.browserAccessGrantDidDismiss()
    return true
  }

  private func makeWindow() -> NSWindow {
    let root = BrowserAccessWindowView(
      state: state,
      onOpenFullDiskAccess: { [weak self] in
        self?.handler?.browserAccessGrantDidRequestFullDiskAccess()
      },
      onAllowKeychain: { [weak self] browser in
        self?.handler?.browserAccessGrantDidRequestKeychain(browser)
      },
      onRelaunch: { [weak self] in
        self?.handler?.browserAccessGrantDidRequestRelaunch()
      },
      onFullDiskAccessDrop: { [weak self] in
        self?.handler?.browserAccessGrantDidDropIntoFullDiskAccess()
      },
      onDone: { [weak self] in
        self?.handler?.browserAccessGrantDidDismiss()
        self?.dismiss()
      }
    )
    let hosting = NSHostingController(rootView: root)
    hosting.sizingOptions = [.preferredContentSize]
    let window = BrowserAccessWindow(contentViewController: hosting)
    window.title = BrowserSessionCopy.grantWindowTitle
    window.styleMask = [.titled, .closable]
    window.level = .floating
    window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    window.isMovableByWindowBackground = true
    window.isReleasedWhenClosed = false
    window.delegate = self
    if !window.setFrameUsingName(Self.frameAutosaveName) {
      window.center()
    }
    window.setFrameAutosaveName(Self.frameAutosaveName)
    return window
  }
}

/// Escape and ⌘W close it like any other window; there is no main menu to route them.
private final class BrowserAccessWindow: NSWindow {
  override func cancelOperation(_ sender: Any?) {
    performClose(sender)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
      event.charactersIgnoringModifiers == "w"
    {
      performClose(nil)
      return true
    }
    return super.performKeyEquivalent(with: event)
  }
}

enum SystemSettingsLinks {
  static func openFullDiskAccess() {
    let urls: [URL] = [
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"),
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy"),
      URL(string: "x-apple.systempreferences:com.apple.preference.security"),
    ].compactMap(\.self)
    for url in urls where NSWorkspace.shared.open(url) {
      return
    }
  }
}

@Observable
@MainActor
final class BrowserAccessWindowState {
  var snapshot = BrowserAccessGrantSnapshot(
    statuses: [], awaitingRelaunch: false, keychainPromptBrowser: nil)
}

private struct BrowserAccessWindowView: View {
  @Bindable var state: BrowserAccessWindowState
  let onOpenFullDiskAccess: () -> Void
  let onAllowKeychain: (Browser) -> Void
  let onRelaunch: () -> Void
  let onFullDiskAccessDrop: () -> Void
  let onDone: () -> Void

  private static let width: CGFloat = 380

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
      Text(BrowserSessionCopy.grantWindowMessage)
        .quotaSecondaryStyle()
        .fixedSize(horizontal: false, vertical: true)

      VStack(spacing: 0) {
        ForEach(Array(state.snapshot.statuses.enumerated()), id: \.element.id) { index, status in
          if index > 0 {
            Divider()
              .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
          }
          BrowserAccessRow(
            status: status,
            isPrompting: state.snapshot.keychainPromptBrowser == status.browser,
            onOpenFullDiskAccess: onOpenFullDiskAccess,
            onAllowKeychain: { onAllowKeychain(status.browser) }
          )
        }
      }
      .padding(.vertical, QuotaDesign.Layout.groupSurfaceInset)
      .quotaGroupSurface()

      if state.snapshot.needs.contains(where: { $0.kind == .fullDiskAccess }) {
        HStack(alignment: .center, spacing: QuotaDesign.Spacing.md) {
          FullDiskAccessDragIcon(onDrop: onFullDiskAccessDrop)
            .frame(width: 40, height: 40)
            .accessibilityLabel(BrowserSessionCopy.dragHintTitle)
            .accessibilityHint(BrowserSessionCopy.dragHintSubtitle)
          VStack(alignment: .leading, spacing: 2) {
            Text(BrowserSessionCopy.dragHintTitle)
              .quotaSettingsLabelStyle()
            Text(BrowserSessionCopy.dragHintSubtitle)
              .quotaListSecondaryStyle()
              .fixedSize(horizontal: false, vertical: true)
          }
        }
        .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
        .padding(.vertical, QuotaDesign.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .quotaGroupSurface()
      }

      if state.snapshot.awaitingRelaunch {
        HStack(alignment: .center, spacing: QuotaDesign.Spacing.md) {
          VStack(alignment: .leading, spacing: 2) {
            Text(BrowserSessionCopy.relaunchTitle)
              .quotaSettingsLabelStyle()
            Text(BrowserSessionCopy.relaunchSubtitle)
              .quotaListSecondaryStyle()
              .fixedSize(horizontal: false, vertical: true)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          Button(BrowserSessionCopy.relaunchActionTitle, action: onRelaunch)
            .buttonStyle(QuotaSecondaryButtonStyle())
        }
        .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
        .padding(.vertical, QuotaDesign.Spacing.sm)
        .quotaGroupSurface()
      }

      HStack {
        Spacer(minLength: 0)
        Button(BrowserSessionCopy.grantDoneTitle, action: onDone)
          .buttonStyle(QuotaSecondaryButtonStyle())
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(QuotaDesign.Spacing.lg)
    .frame(width: Self.width, alignment: .leading)
    .background(Color(nsColor: .windowBackgroundColor))
  }
}

/// One installed browser: its icon, what stands in front of its cookies, and the one action.
private struct BrowserAccessRow: View {
  let status: BrowserAccessStatus
  let isPrompting: Bool
  let onOpenFullDiskAccess: () -> Void
  let onAllowKeychain: () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: QuotaDesign.Spacing.sm) {
      BrowserApplicationIcon(browser: status.browser)
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        Text(status.browser.displayName)
          .quotaSettingsLabelStyle()
        Text(BrowserSessionCopy.grantSubtitle(for: status))
          .quotaListSecondaryStyle()
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      trailing
    }
    .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
    .padding(.vertical, QuotaDesign.Spacing.sm)
    .frame(minHeight: QuotaDesign.Layout.settingsListRowHeight)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(
      "\(status.browser.displayName). \(BrowserSessionCopy.grantSubtitle(for: status))")
  }

  @ViewBuilder
  private var trailing: some View {
    switch status.state {
    case .readable:
      Label(BrowserSessionCopy.grantReadyTitle, systemImage: "checkmark.circle.fill")
        .quotaFont(.meta)
        .foregroundStyle(QuotaPalette.accent)
    case .needsFullDiskAccess:
      Button(BrowserSessionCopy.grantOpenSettingsTitle, action: onOpenFullDiskAccess)
        .buttonStyle(QuotaSecondaryButtonStyle())
        .accessibilityHint("Opens System Settings › Privacy & Security › Full Disk Access")
    case .needsKeychain:
      Button(action: onAllowKeychain) {
        if isPrompting {
          ProgressView()
            .controlSize(.small)
            .frame(minWidth: 40)
        } else {
          Text(BrowserSessionCopy.grantAllowTitle)
        }
      }
      .buttonStyle(QuotaSecondaryButtonStyle())
      .disabled(isPrompting)
      .accessibilityHint("Asks macOS to let QuotaBar use this browser's Keychain item")
    case .unavailable:
      Text(BrowserSessionCopy.grantUnavailableTitle)
        .quotaMetaStyle()
    }
  }
}

/// The browser's own icon, so the row reads as the program it names.
private struct BrowserApplicationIcon: View {
  let browser: Browser

  var body: some View {
    if let url = BrowserApplicationCatalog.applicationURL(for: browser) {
      Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
    } else {
      Image(systemName: "globe")
        .quotaFont(.rowTitle)
        .foregroundStyle(QuotaPalette.body)
    }
  }
}

private struct FullDiskAccessDragIcon: NSViewRepresentable {
  let onDrop: () -> Void

  func makeNSView(context: Context) -> FullDiskAccessDragSourceView {
    let view = FullDiskAccessDragSourceView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
    view.onDroppedIntoSystemSettings = onDrop
    return view
  }

  func updateNSView(_ nsView: FullDiskAccessDragSourceView, context: Context) {
    nsView.onDroppedIntoSystemSettings = onDrop
  }
}

/// App icon the user drags into System Settings › Full Disk Access: a plain file drag of
/// QuotaBar.app, the same thing dragging it out of the Applications folder would put on the
/// pasteboard. The URL is on the pasteboard from the first pixel — a drop target decides on the
/// types it sees when the drag enters, so nothing may be swapped in later. Before the drag
/// starts, System Settings is brought to the front so the list is the window under the cursor.
final class FullDiskAccessDragSourceView: NSView, NSDraggingSource {
  static let allowedDropOperation: NSDragOperation = .copy
  /// Points the cursor must travel before a press becomes a drag, so a click stays a click.
  static let dragThreshold: CGFloat = 4
  static let systemSettingsBundleIdentifiers: Set<String> = [
    "com.apple.systempreferences", "com.apple.Settings",
  ]

  /// A drop counts as landing in System Settings when it was accepted and System Settings is
  /// the application in front — a copy onto the desktop leaves Finder in front instead.
  static func droppedIntoSystemSettings(
    operation: NSDragOperation,
    frontmostBundleIdentifier: String?
  ) -> Bool {
    !operation.isEmpty
      && frontmostBundleIdentifier.map(systemSettingsBundleIdentifiers.contains) == true
  }

  private static let dragIconSize = NSSize(width: 48, height: 48)

  var onDroppedIntoSystemSettings: (() -> Void)?

  private var mouseDownEvent: NSEvent?
  private var didBeginDrag = false

  override var mouseDownCanMoveWindow: Bool { false }
  override var isOpaque: Bool { false }
  override var intrinsicContentSize: NSSize { NSSize(width: 40, height: 40) }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? {
    bounds.contains(point) ? self : nil
  }

  override func draw(_ dirtyRect: NSRect) {
    NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
      .draw(in: bounds.insetBy(dx: 2, dy: 2))
  }

  override func mouseDown(with event: NSEvent) {
    NSApp.preventWindowOrdering()
    mouseDownEvent = event
    didBeginDrag = false
  }

  override func mouseDragged(with event: NSEvent) {
    guard !didBeginDrag, let mouseDownEvent else { return }
    let dx = event.locationInWindow.x - mouseDownEvent.locationInWindow.x
    let dy = event.locationInWindow.y - mouseDownEvent.locationInWindow.y
    guard hypot(dx, dy) >= Self.dragThreshold else { return }
    didBeginDrag = true

    // Reassert the drop target before AppKit enters its nested drag loop: the list has to be
    // the window under the cursor, not this floating one or whatever was behind it.
    Self.runningSystemSettings()?.activate()

    let draggingItem = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
    let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    icon.size = Self.dragIconSize
    let click = convert(event.locationInWindow, from: nil)
    draggingItem.setDraggingFrame(
      NSRect(
        origin: NSPoint(
          x: click.x - Self.dragIconSize.width / 2,
          y: click.y - Self.dragIconSize.height / 2
        ),
        size: Self.dragIconSize
      ),
      contents: icon
    )
    _ = beginDraggingSession(with: [draggingItem], event: event, source: self)
  }

  override func mouseUp(with event: NSEvent) {
    mouseDownEvent = nil
  }

  /// Nothing inside QuotaBar takes the drop; other applications may copy the reference.
  func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    context == .outsideApplication ? Self.allowedDropOperation : []
  }

  /// Option or Command must not turn the copy into a link or a move.
  func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

  func draggingSession(
    _ session: NSDraggingSession,
    endedAt screenPoint: NSPoint,
    operation: NSDragOperation
  ) {
    mouseDownEvent = nil
    didBeginDrag = false
    let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    if Self.droppedIntoSystemSettings(operation: operation, frontmostBundleIdentifier: frontmost) {
      onDroppedIntoSystemSettings?()
    }
  }

  private static func runningSystemSettings() -> NSRunningApplication? {
    for identifier in systemSettingsBundleIdentifiers {
      if let app = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        .first
      {
        return app
      }
    }
    return nil
  }
}
