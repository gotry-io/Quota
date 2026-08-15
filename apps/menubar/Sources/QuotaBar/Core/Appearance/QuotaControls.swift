import SwiftUI

/// Neutral hover plus restrained accent press feedback for destination/list rows.
struct QuotaListRowButtonStyle: ButtonStyle {
  var cornerRadius = QuotaDesign.Layout.rowCornerRadius
  var surfaceInset = QuotaDesign.Layout.groupSurfaceInset

  func makeBody(configuration: Configuration) -> some View {
    QuotaListRowButtonBody(
      configuration: configuration,
      cornerRadius: cornerRadius,
      surfaceInset: surfaceInset
    )
  }

  private struct QuotaListRowButtonBody: View {
    let configuration: Configuration
    let cornerRadius: CGFloat
    let surfaceInset: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
      configuration.label
        .background {
          RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(surfaceFill)
            .padding(surfaceInset)
        }
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.55)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
    }

    private var surfaceFill: Color {
      if configuration.isPressed && isEnabled { return QuotaPalette.rowPressedFill }
      return isHovered && isEnabled ? QuotaPalette.rowHoverFill : .clear
    }
  }
}

/// Header icon actions keep their 28×44 hit target while drawing a compact hover surface.
struct QuotaHeaderButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    QuotaHeaderButtonBody(configuration: configuration)
  }

  private struct QuotaHeaderButtonBody: View {
    let configuration: Configuration

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
      configuration.label
        .background {
          RoundedRectangle(cornerRadius: QuotaDesign.Layout.rowCornerRadius, style: .continuous)
            .fill(configuration.isPressed ? QuotaPalette.rowPressedFill : hoverFill)
            .frame(
              width: QuotaDesign.Layout.headerControlSurfaceSize,
              height: QuotaDesign.Layout.headerControlSurfaceSize
            )
        }
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.65)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
    }

    private var hoverFill: Color {
      isHovered && isEnabled ? QuotaPalette.rowHoverFill : .clear
    }
  }
}

extension View {
  func quotaFloatingMenuSurface() -> some View {
    background {
      RoundedRectangle(
        cornerRadius: QuotaDesign.Layout.floatingMenuCornerRadius,
        style: .continuous
      )
      .fill(.regularMaterial)
      .overlay {
        RoundedRectangle(
          cornerRadius: QuotaDesign.Layout.floatingMenuCornerRadius,
          style: .continuous
        )
        .fill(QuotaPalette.floatingMenuFill)
      }
    }
    .clipShape(
      RoundedRectangle(
        cornerRadius: QuotaDesign.Layout.floatingMenuCornerRadius,
        style: .continuous
      )
    )
    .overlay {
      RoundedRectangle(
        cornerRadius: QuotaDesign.Layout.floatingMenuCornerRadius,
        style: .continuous
      )
      .strokeBorder(QuotaPalette.hairlineBorder.opacity(0.55), lineWidth: 0.5)
    }
    .shadow(
      color: QuotaPalette.floatingMenuShadow.opacity(0.45),
      radius: 2,
      x: 0,
      y: 1
    )
    .shadow(
      color: QuotaPalette.floatingMenuShadow,
      radius: QuotaDesign.Layout.floatingMenuShadowRadius,
      x: 0,
      y: QuotaDesign.Layout.floatingMenuShadowY
    )
  }
}
