import AppKit
import SwiftUI

private struct QuotaGroupSurfaceModifier: ViewModifier {
  func body(content: Content) -> some View {
    content.background {
      RoundedRectangle(
        cornerRadius: QuotaDesign.Layout.groupCornerRadius,
        style: .continuous
      )
      .fill(QuotaPalette.settingsGroupFill)
    }
  }
}

extension View {
  /// Shared persistent group surface. Elevation and transient menus use separate components.
  func quotaGroupSurface() -> some View {
    modifier(QuotaGroupSurfaceModifier())
  }
}

/// Monospaced command plus a self-contained Copy/Copied affordance.
struct QuotaCommandRow: View {
  let command: String
  let copyLabel: String
  var isCopyEnabled = true

  @State private var isCopied = false
  @State private var copyFeedbackTask: Task<Void, Never>?

  var body: some View {
    HStack(spacing: QuotaDesign.Spacing.inline) {
      Text(command)
        .quotaMonoStyle()
        .textSelection(.enabled)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)

      Button(action: copyCommand) {
        Text(isCopied && isCopyEnabled ? "Copied" : "Copy")
          .quotaSecondaryStyle()
          .frame(
            minWidth: QuotaDesign.Layout.minimumInteractiveDimension,
            minHeight: QuotaDesign.Layout.minimumInteractiveDimension
          )
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!isCopyEnabled)
      .accessibilityLabel(copyLabel)
    }
    .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
    .padding(.vertical, QuotaDesign.Layout.settingsRowVerticalPadding)
    .onChange(of: command) { _, _ in clearCopyFeedback() }
    .onDisappear { copyFeedbackTask?.cancel() }
  }

  private func copyCommand() {
    guard isCopyEnabled else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)
    isCopied = true
    copyFeedbackTask?.cancel()
    copyFeedbackTask = Task {
      try? await Task.sleep(for: .seconds(1.5))
      guard !Task.isCancelled else { return }
      isCopied = false
    }
  }

  private func clearCopyFeedback() {
    copyFeedbackTask?.cancel()
    copyFeedbackTask = nil
    isCopied = false
  }
}
