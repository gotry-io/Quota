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
    .background {
      RoundedRectangle(cornerRadius: QuotaDesign.Layout.fieldCornerRadius, style: .continuous)
        .fill(QuotaPalette.fieldFill)
        .overlay {
          if isFocused {
            RoundedRectangle(cornerRadius: QuotaDesign.Layout.fieldCornerRadius, style: .continuous)
              .fill(QuotaPalette.fieldFillFocused)
          }
        }
    }
    .clipShape(
      RoundedRectangle(cornerRadius: QuotaDesign.Layout.fieldCornerRadius, style: .continuous)
    )
    .overlay {
      if isFocused {
        RoundedRectangle(cornerRadius: QuotaDesign.Layout.fieldCornerRadius, style: .continuous)
          .strokeBorder(QuotaPalette.accent.opacity(0.72), lineWidth: 1.5)
      }
    }
    .opacity(isEnabled ? 1 : 0.55)
  }
}

// MARK: - Interactive surfaces

/// Neutral hover plus restrained accent press feedback for destination/list rows.
struct QuotaListRowButtonStyle: ButtonStyle {
  var cornerRadius = QuotaDesign.Layout.rowCornerRadius

  func makeBody(configuration: Configuration) -> some View {
    QuotaListRowButtonBody(configuration: configuration, cornerRadius: cornerRadius)
  }

  private struct QuotaListRowButtonBody: View {
    let configuration: Configuration
    let cornerRadius: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
      configuration.label
        .background {
          RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
          )
          .fill(surfaceFill)
          .padding(QuotaDesign.Layout.groupSurfaceInset)
        }
        .contentShape(Rectangle())
        .opacity(isEnabled ? 1 : 0.55)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
    }

    private var surfaceFill: Color {
      if configuration.isPressed && isEnabled {
        return QuotaPalette.rowPressedFill
      }
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
    @State private var isHovered = false

    var body: some View {
      configuration.label
        .background {
          RoundedRectangle(
            cornerRadius: QuotaDesign.Layout.rowCornerRadius,
            style: .continuous
          )
          .fill(configuration.isPressed ? QuotaPalette.rowPressedFill : hoverFill)
          .frame(
            width: QuotaDesign.Layout.headerControlSurfaceSize,
            height: QuotaDesign.Layout.headerControlSurfaceSize
          )
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
    }

    private var hoverFill: Color {
      isHovered ? QuotaPalette.rowHoverFill : .clear
    }
  }
}

// MARK: - Pop-up field

struct QuotaPopUpOption<Value: Hashable> {
  let value: Value
  let title: String
}

/// Quota selection control with a floating app-owned menu surface.
struct QuotaPopUpField<Value: Hashable>: View {
  @Binding var selection: Value
  let options: [QuotaPopUpOption<Value>]
  let accessibilityLabel: String

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.isEnabled) private var isEnabled
  @FocusState private var isFocused: Bool
  @FocusState private var focusedOption: Value?
  @State private var isHovered = false
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xs) {
      Button {
        setExpanded(!isExpanded)
      } label: {
        HStack(spacing: QuotaDesign.Spacing.inline) {
          Text(selectedTitle)
            .quotaSettingsLabelStyle()
            .lineLimit(1)

          Spacer(minLength: 0)

          Image(systemName: "chevron.down")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(QuotaPalette.mute)
            .frame(width: QuotaDesign.Layout.headerGlyphWidth)
            .rotationEffect(.degrees(isExpanded ? 180 : 0))
        }
        .padding(.horizontal, 10)
        .frame(
          maxWidth: .infinity,
          minHeight: QuotaDesign.Layout.fieldMinHeight,
          alignment: .leading
        )
        .background {
          RoundedRectangle(cornerRadius: QuotaDesign.Layout.fieldCornerRadius, style: .continuous)
            .fill(QuotaPalette.fieldFill)
            .overlay {
              if isHovered {
                RoundedRectangle(
                  cornerRadius: QuotaDesign.Layout.fieldCornerRadius,
                  style: .continuous
                )
                .fill(QuotaPalette.rowHoverFill)
              }
            }
        }
        .overlay {
          if isFocused {
            RoundedRectangle(cornerRadius: QuotaDesign.Layout.fieldCornerRadius, style: .continuous)
              .strokeBorder(QuotaPalette.accent.opacity(0.72), lineWidth: 1.5)
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .focusable()
      .focused($isFocused)
      .onHover { isHovered = $0 }
      .accessibilityLabel(accessibilityLabel)
      .accessibilityValue(selectedTitle)
      .accessibilityHint(isExpanded ? "Choose an option below" : "Show options")
      .onKeyPress(.upArrow) {
        setExpanded(true)
        return .handled
      }
      .onKeyPress(.downArrow) {
        setExpanded(true)
        return .handled
      }
    }
    .overlay(alignment: .topLeading) {
      if isExpanded {
        GeometryReader { proxy in
          ZStack(alignment: .topLeading) {
            Color.clear
              .contentShape(Rectangle())
              .frame(
                width: QuotaDesign.Layout.panelWidth,
                height: QuotaDesign.Layout.panelMaxHeight
              )
              .offset(
                x: -QuotaDesign.Layout.panelHorizontalPadding,
                y: QuotaDesign.Layout.fieldMinHeight + QuotaDesign.Spacing.xs
              )
              .onTapGesture { setExpanded(false) }

            optionsMenu
              .frame(width: proxy.size.width)
              .offset(y: QuotaDesign.Layout.fieldMinHeight + QuotaDesign.Spacing.xs)
          }
        }
        .transition(
          .asymmetric(
            insertion: .opacity.combined(
              with: .scale(scale: 0.98, anchor: .topLeading)
            ),
            removal: .opacity
          )
        )
      }
    }
    .zIndex(isExpanded ? 10 : 0)
    .opacity(isEnabled ? 1 : 0.55)
    .onChange(of: isEnabled) { _, enabled in
      if !enabled {
        isExpanded = false
        focusedOption = nil
      }
    }
    .onChange(of: focusedOption) { previous, option in
      if option == nil, isExpanded, let previous {
        Task { @MainActor in
          await Task.yield()
          guard isExpanded, focusedOption == nil else { return }
          focusedOption = previous
        }
      }
    }
    .onExitCommand {
      if isExpanded { setExpanded(false) }
    }
  }

  private var optionsMenu: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(options.enumerated()), id: \.offset) { _, option in
        Button {
          select(option.value)
        } label: {
          HStack(spacing: QuotaDesign.Spacing.inline) {
            Text(option.title)
              .quotaSettingsLabelStyle()
              .lineLimit(1)

            Spacer(minLength: 0)

            if option.value == selection {
              Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(QuotaPalette.accent)
                .frame(width: QuotaDesign.Layout.headerGlyphWidth)
            }
          }
          .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
          .frame(
            maxWidth: .infinity,
            minHeight: QuotaDesign.Layout.fieldMinHeight,
            alignment: .leading
          )
        }
        .buttonStyle(
          QuotaListRowButtonStyle(
            cornerRadius: QuotaDesign.Layout.floatingMenuRowCornerRadius
          )
        )
        .accessibilityLabel(option.title)
        .accessibilityValue(option.value == selection ? "Selected" : "")
        .focusable()
        .focused($focusedOption, equals: option.value)
        .onKeyPress(.upArrow) {
          moveOptionFocus(from: option.value, by: -1)
          return .handled
        }
        .onKeyPress(.downArrow) {
          moveOptionFocus(from: option.value, by: 1)
          return .handled
        }
        .onKeyPress(.return) {
          select(option.value)
          return .handled
        }
        .onKeyPress(.space) {
          select(option.value)
          return .handled
        }
      }
    }
    .quotaFloatingMenuSurface()
  }

  private var selectedTitle: String {
    options.first { $0.value == selection }?.title ?? options.first?.title ?? ""
  }

  private func select(_ value: Value) {
    selection = value
    setExpanded(false)
  }

  private func setExpanded(_ expanded: Bool) {
    if reduceMotion {
      isExpanded = expanded
    } else {
      withAnimation(expanded ? .easeOut(duration: 0.12) : .easeIn(duration: 0.08)) {
        isExpanded = expanded
      }
    }

    if expanded {
      Task { @MainActor in
        await Task.yield()
        guard isExpanded else { return }
        let option = options.first { $0.value == selection }?.value ?? options.first?.value
        focusedOption = option
      }
    } else {
      focusedOption = nil
      Task { @MainActor in
        await Task.yield()
        guard !isExpanded else { return }
        isFocused = true
      }
    }
  }

  private func moveOptionFocus(from value: Value, by offset: Int) {
    guard let index = options.firstIndex(where: { $0.value == value }) else { return }
    let destination = min(
      max(index + offset, options.startIndex),
      options.index(before: options.endIndex)
    )
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(50))
      guard isExpanded else { return }
      focusedOption = options[destination].value
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
