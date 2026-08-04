import AppKit
import SwiftUI

/// Single header chrome for every page.
///
/// Edge rule: header, body, and footer share `panelHorizontalPadding` (16).
/// Every trailing action is the same plain SwiftUI button. Overflow uses that
/// button plus a zero-size AppKit menu anchor — never SwiftUI `Menu`, which
/// injects borderlessButton insets and misaligns Settings vs Overview.
struct MenuBarHeader: View {
  enum TrailingAction {
    case none
    case openSettings(() -> Void)
    case addRelay(() -> Void)
    case overflowMenu(deleteEnabled: Bool, onDeleteAll: () -> Void)
  }

  let title: String
  let canNavigateBack: Bool
  let onNavigateBack: () -> Void
  /// Overview root only: app mark before the title.
  var showsLeadingIcon: Bool = false
  let trailing: TrailingAction

  private let backGlyphWidth: CGFloat = 12

  var body: some View {
    HStack(spacing: 0) {
      if canNavigateBack {
        headerButton(
          systemName: "chevron.left",
          accessibilityLabel: "Back",
          width: backGlyphWidth,
          alignment: .leading,
          action: onNavigateBack
        )
        Color.clear.frame(width: QuotaDesign.Spacing.xs, height: 1)
      } else if showsLeadingIcon {
        leadingTitleIcon
        Color.clear.frame(width: QuotaDesign.Spacing.xs, height: 1)
      }

      Text(title)
        .font(QuotaDesign.Typography.panelTitle)
        .foregroundStyle(QuotaPalette.ink)
        .lineLimit(1)
        .accessibilityAddTraits(.isHeader)

      Spacer(minLength: QuotaDesign.Spacing.inline)

      trailingControl
    }
    .frame(maxWidth: .infinity, minHeight: QuotaDesign.Layout.headerHeight, alignment: .center)
    .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
  }

  private var leadingTitleIcon: some View {
    Group {
      if let image = QuotaBrandAssets.menuBarTemplateImage() {
        Image(nsImage: image)
          .resizable()
          .renderingMode(.template)
          .interpolation(.high)
          .scaledToFit()
      }
    }
    .frame(width: 16, height: 16)
    .foregroundStyle(QuotaPalette.ink)
    .accessibilityHidden(true)
  }

  @ViewBuilder
  private var trailingControl: some View {
    switch trailing {
    case .none:
      EmptyView()

    case .openSettings(let action):
      headerButton(
        systemName: "gearshape",
        accessibilityLabel: "Open settings",
        width: QuotaDesign.Layout.headerControlWidth,
        alignment: .trailing,
        action: action
      )

    case .addRelay(let action):
      headerButton(
        systemName: "plus",
        accessibilityLabel: "Add Relay",
        width: QuotaDesign.Layout.headerControlWidth,
        alignment: .trailing,
        action: action
      )

    case .overflowMenu(let deleteEnabled, let onDeleteAll):
      HeaderOverflowPlainButton(
        width: QuotaDesign.Layout.headerControlWidth,
        deleteEnabled: deleteEnabled,
        onDeleteAll: onDeleteAll
      )
      .accessibilityLabel("Settings menu")
    }
  }

  private func headerButton(
    systemName: String,
    accessibilityLabel: String,
    width: CGFloat,
    alignment: Alignment,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(QuotaDesign.Typography.headerIcon)
        .foregroundStyle(QuotaPalette.body)
        .frame(
          width: width,
          height: QuotaDesign.Layout.headerHeight,
          alignment: alignment
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
  }
}

/// Same visual metrics as `headerButton`, but pops an AppKit menu on click.
private struct HeaderOverflowPlainButton: View {
  let width: CGFloat
  let deleteEnabled: Bool
  let onDeleteAll: () -> Void

  @State private var anchor = HeaderMenuAnchor()

  var body: some View {
    Button {
      anchor.present(deleteEnabled: deleteEnabled, onDeleteAll: onDeleteAll)
    } label: {
      Image(systemName: "ellipsis")
        .font(QuotaDesign.Typography.headerIcon)
        .foregroundStyle(QuotaPalette.body)
        .frame(
          width: width,
          height: QuotaDesign.Layout.headerHeight,
          alignment: .trailing
        )
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      HeaderMenuAnchorView(anchor: anchor)
        .frame(width: 0, height: 0)
    )
  }
}

@MainActor
private final class HeaderMenuAnchor {
  weak var view: NSView?

  func present(deleteEnabled: Bool, onDeleteAll: @escaping () -> Void) {
    guard let view else { return }

    let menu = NSMenu()
    let target = HeaderMenuTarget(onDeleteAll: onDeleteAll)
    objc_setAssociatedObject(
      menu,
      &HeaderMenuTarget.assocKey,
      target,
      .OBJC_ASSOCIATION_RETAIN
    )

    let deleteItem = NSMenuItem(
      title: "Delete All QuotaBar Data…",
      action: #selector(HeaderMenuTarget.deleteAll),
      keyEquivalent: ""
    )
    deleteItem.target = target
    deleteItem.isEnabled = deleteEnabled

    let quitItem = NSMenuItem(
      title: "Quit QuotaBar",
      action: #selector(HeaderMenuTarget.quit),
      keyEquivalent: "q"
    )
    quitItem.target = target

    menu.addItem(deleteItem)
    menu.addItem(.separator())
    menu.addItem(quitItem)

    // Pop just under the trailing edge of the header control.
    let point = NSPoint(x: view.bounds.maxX, y: view.bounds.minY)
    menu.popUp(positioning: nil, at: point, in: view)
  }
}

private struct HeaderMenuAnchorView: NSViewRepresentable {
  let anchor: HeaderMenuAnchor

  func makeNSView(context: Context) -> NSView {
    let view = NSView(frame: .zero)
    DispatchQueue.main.async {
      anchor.view = view
    }
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {
    anchor.view = view
  }
}

@MainActor
private final class HeaderMenuTarget: NSObject {
  static var assocKey: UInt8 = 0
  private let onDeleteAll: () -> Void

  init(onDeleteAll: @escaping () -> Void) {
    self.onDeleteAll = onDeleteAll
  }

  @objc func deleteAll() {
    onDeleteAll()
  }

  @objc func quit() {
    NSApplication.shared.terminate(nil)
  }
}
