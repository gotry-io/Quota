import SwiftUI

/// App-owned confirmation surface for actions that cannot use a system alert in MenuBarExtra.
struct QuotaConfirmationPopup: View {
  let title: String
  let message: String
  let confirmTitle: String
  let onCancel: () -> Void
  let onConfirm: () -> Void

  @FocusState private var isPopupFocused: Bool

  var body: some View {
    ZStack {
      QuotaPalette.modalScrim
        .contentShape(Rectangle())
        .onTapGesture(perform: onCancel)

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
      .quotaFloatingMenuSurface()
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
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
}
