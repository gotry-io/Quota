import SwiftUI

/// App-owned confirmation surface. Overlay is for the menu panel; sheet is for the main window.
struct QuotaConfirmationPopup: View {
  enum Style {
    /// Scrimmed overlay sized for the menu panel.
    case overlay
    /// Card content for a window sheet, with no panel-sized scrim.
    case sheet
  }

  let title: String
  let message: String
  let confirmTitle: String
  var style: Style = .overlay
  let onCancel: () -> Void
  let onConfirm: () -> Void

  @FocusState private var isPopupFocused: Bool

  var body: some View {
    Group {
      switch style {
      case .overlay:
        ZStack {
          QuotaPalette.modalScrim
            .contentShape(Rectangle())
            .onTapGesture(perform: onCancel)
          card
            .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
        }
      case .sheet:
        card
          .frame(minWidth: 360, idealWidth: 400)
          .padding(QuotaDesign.Spacing.lg)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
    .focusable()
    .focused($isPopupFocused)
    .onAppear {
      Task { @MainActor in
        await Task.yield()
        isPopupFocused = true
      }
    }
    .onKeyPress(.escape) {
      onCancel()
      return .handled
    }
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xs) {
        Text(title)
          .quotaFont(.rowTitle)
          .foregroundStyle(QuotaPalette.ink)
        Text(message)
          .quotaSecondaryStyle()
          .fixedSize(horizontal: false, vertical: true)
      }

      HStack(spacing: QuotaDesign.Spacing.sm) {
        Spacer(minLength: 0)

        Button(action: onCancel) {
          Text("Cancel")
            .quotaFont(.rowTitle)
            .foregroundStyle(QuotaPalette.ink)
            .padding(.horizontal, QuotaDesign.Spacing.sm)
            .frame(minHeight: QuotaDesign.Layout.fieldMinHeight)
        }
        .buttonStyle(QuotaListRowButtonStyle(surfaceInset: 0))

        Button(role: .destructive, action: onConfirm) {
          Text(confirmTitle)
            .quotaFont(.rowTitle)
            .foregroundStyle(QuotaPalette.onCritical)
            .padding(.horizontal, QuotaDesign.Spacing.lg)
            .frame(minHeight: QuotaDesign.Layout.fieldMinHeight)
            .background(QuotaPalette.criticalAction)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(QuotaDesign.Spacing.lg)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quotaFloatingSurface()
  }
}
