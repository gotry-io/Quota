import SwiftUI

struct QuotaSelectionChoice: Identifiable, Equatable {
  let id: String
  let title: String
  let subtitle: String?
}

/// App-owned single-selection surface for the menu panel.
struct QuotaSelectionPopup: View {
  let title: String
  let message: String
  let choices: [QuotaSelectionChoice]
  let onCancel: () -> Void
  let onSelect: (String) -> Void

  @State private var selection: String?
  @FocusState private var isPopupFocused: Bool

  var body: some View {
    ZStack {
      QuotaPalette.modalScrim
        .contentShape(Rectangle())
        .onTapGesture(perform: onCancel)

      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        heading
        choiceList
        actions
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
      selection = choices.count == 1 ? choices.first?.id : nil
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

  private var heading: some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xs) {
      Text(title).quotaFont(.rowTitle).foregroundStyle(QuotaPalette.ink)
      Text(message).quotaSecondaryStyle().fixedSize(horizontal: false, vertical: true)
    }
  }

  private var choiceList: some View {
    ScrollView {
      VStack(spacing: 0) {
        ForEach(choices) { choice in
          choiceButton(choice)
        }
      }
    }
    .frame(maxHeight: 220)
  }

  private func choiceButton(_ choice: QuotaSelectionChoice) -> some View {
    Button { selection = choice.id } label: {
      HStack(spacing: QuotaDesign.Spacing.sm) {
        Image(systemName: selection == choice.id ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(selection == choice.id ? QuotaPalette.accent : QuotaPalette.mute)
        VStack(alignment: .leading, spacing: 2) {
          Text(choice.title).quotaFont(.rowTitle)
          if let subtitle = choice.subtitle {
            Text(subtitle).quotaListSecondaryStyle().lineLimit(1)
          }
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, QuotaDesign.Spacing.sm)
      .frame(minHeight: QuotaDesign.Layout.settingsListRowHeight)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(choice.title)
    .accessibilityValue(selection == choice.id ? "Selected" : "Not selected")
  }

  private var actions: some View {
    HStack(spacing: QuotaDesign.Spacing.sm) {
      Spacer(minLength: 0)
      Button("Cancel", action: onCancel)
        .buttonStyle(QuotaListRowButtonStyle(surfaceInset: 0))
      Button("Continue") {
        if let selection { onSelect(selection) }
      }
      .buttonStyle(QuotaPrimaryButtonStyle(isCompact: true))
      .disabled(selection == nil)
    }
  }
}
