import SwiftUI

/// App-owned confirmation surface that stays inside the MenuBarExtra window.
struct QuotaConfirmationDialog: View {
  private enum Action: Hashable {
    case cancel
    case confirm
  }

  let title: String
  let message: String
  let confirmTitle: String
  let cancelTitle: String
  let onConfirm: () -> Void
  let onCancel: () -> Void

  @FocusState private var focusedAction: Action?

  var body: some View {
    ZStack {
      QuotaPalette.modalScrim
        .contentShape(Rectangle())
        .onTapGesture(perform: onCancel)

      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        Text(title)
          .quotaFont(.panelTitle)
          .foregroundStyle(QuotaPalette.ink)
          .accessibilityAddTraits(.isHeader)

        Text(message)
          .quotaSecondaryStyle()
          .fixedSize(horizontal: false, vertical: true)

        ViewThatFits(in: .horizontal) {
          HStack(spacing: QuotaDesign.Spacing.sm) {
            Spacer(minLength: 0)
            cancelButton
            confirmButton
          }

          VStack(alignment: .trailing, spacing: QuotaDesign.Spacing.sm) {
            cancelButton
            confirmButton
          }
          .frame(maxWidth: .infinity, alignment: .trailing)
        }
      }
      .padding(QuotaDesign.Spacing.lg)
      .frame(width: QuotaDesign.Layout.panelContentWidth - (QuotaDesign.Spacing.lg * 2))
      .quotaFloatingMenuSurface()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .transition(.opacity)
    .onExitCommand(perform: onCancel)
    .onAppear { focusedAction = .cancel }
  }

  private var cancelButton: some View {
    Button(action: onCancel) {
      Text(cancelTitle)
        .quotaSettingsLabelStyle()
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(minHeight: QuotaDesign.Layout.fieldMinHeight)
    }
    .buttonStyle(
      QuotaListRowButtonStyle(
        cornerRadius: QuotaDesign.Layout.floatingMenuRowCornerRadius,
        surfaceInset: 0
      )
    )
    .keyboardShortcut(.cancelAction)
    .focused($focusedAction, equals: .cancel)
  }

  private var confirmButton: some View {
    Button(role: .destructive, action: onConfirm) {
      Text(confirmTitle)
        .lineLimit(1)
    }
    .buttonStyle(QuotaDestructiveButtonStyle())
    .keyboardShortcut(.defaultAction)
    .focused($focusedAction, equals: .confirm)
  }
}
