import SwiftUI

// MARK: - Text field

/// Soft-fill single-line field chrome. Optional trailing × clears draft text only.
struct QuotaTextFieldStyleModifier: ViewModifier {
  var isFocused = false
  var showsClear = false
  var onClear: (() -> Void)?

  @Environment(\.isEnabled) private var isEnabled

  func body(content: Content) -> some View {
    HStack(spacing: QuotaDesign.Spacing.xxs) {
      content
        .textFieldStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)

      if showsClear, let onClear {
        Button(action: onClear) {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 14))
            .foregroundStyle(QuotaPalette.mute)
            .frame(
              width: QuotaDesign.Layout.minimumInteractiveDimension,
              height: QuotaDesign.Layout.minimumInteractiveDimension
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel("Clear")
      }
    }
    .padding(.leading, 10)
    .padding(.trailing, showsClear ? 2 : 10)
    .frame(minHeight: QuotaDesign.Layout.fieldMinHeight)
    .background(isFocused ? QuotaPalette.fieldFillFocused : QuotaPalette.fieldFill)
    .clipShape(
      RoundedRectangle(cornerRadius: QuotaDesign.Layout.fieldCornerRadius, style: .continuous)
    )
    .opacity(isEnabled ? 1 : 0.55)
  }
}

extension View {
  func quotaTextFieldStyle(
    isFocused: Bool = false,
    showsClear: Bool = false,
    onClear: (() -> Void)? = nil
  ) -> some View {
    modifier(
      QuotaTextFieldStyleModifier(
        isFocused: isFocused,
        showsClear: showsClear,
        onClear: onClear
      )
    )
  }
}

// MARK: - Toggle

/// Compact product switch using accent/soft tracks instead of system green chrome.
struct QuotaToggleStyle: ToggleStyle {
  @Environment(\.isEnabled) private var isEnabled
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func makeBody(configuration: Configuration) -> some View {
    Button {
      if reduceMotion {
        configuration.isOn.toggle()
      } else {
        withAnimation(.snappy(duration: 0.18)) {
          configuration.isOn.toggle()
        }
      }
    } label: {
      ZStack(alignment: configuration.isOn ? .trailing : .leading) {
        Capsule()
          .fill(trackFill(isOn: configuration.isOn))
          .frame(
            width: QuotaDesign.Layout.toggleTrackWidth,
            height: QuotaDesign.Layout.toggleTrackHeight
          )
          .overlay {
            Capsule()
              .stroke(trackStroke(isOn: configuration.isOn), lineWidth: 1)
          }

        Circle()
          .fill(QuotaPalette.toggleThumb)
          .frame(
            width: QuotaDesign.Layout.toggleThumbSize,
            height: QuotaDesign.Layout.toggleThumbSize
          )
          .padding(1)
      }
      .frame(
        width: QuotaDesign.Layout.minimumInteractiveDimension,
        height: QuotaDesign.Layout.minimumInteractiveDimension,
        alignment: .center
      )
      .contentShape(Rectangle())
      .opacity(isEnabled ? 1 : 0.55)
    }
    .buttonStyle(.plain)
    .disabled(!isEnabled)
    .accessibilityValue(configuration.isOn ? "On" : "Off")
  }

  private func trackFill(isOn: Bool) -> Color {
    if isOn {
      // Soft accent wash — solid accent reads too heavy on material chrome.
      return isEnabled ? QuotaPalette.toggleOnTrack : QuotaPalette.soft
    }
    return QuotaPalette.progressTrack
  }

  private func trackStroke(isOn: Bool) -> Color {
    if isOn && isEnabled {
      return QuotaPalette.accent.opacity(0.35)
    }
    return QuotaPalette.hairlineBorder
  }
}
