import SwiftUI

/// Settings → Agents: catalog providers with drill-in to visibility and configuration.
struct AgentsSettingsView: View {
  let relayReportedProviders: Set<ProviderID>
  let onOpenProvider: (ProviderID) -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var enabledProviders = ProviderDisplayOrder.enabledProviders()
  @State private var draggedProvider: ProviderID?
  @State private var dragOriginIndex = 0

  private var disabledProviders: [ProviderID] {
    let enabled = Set(enabledProviders)
    return ProviderID.allCases.filter { !enabled.contains($0) }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        if !enabledProviders.isEmpty {
          SettingsSection(title: "Shown in Overview") {
            VStack(alignment: .leading, spacing: 0) {
              ForEach(enabledProviders) { provider in
                providerRow(provider, isEnabled: true)
              }
            }
          }
        }

        if !disabledProviders.isEmpty {
          SettingsSection(title: "Hidden from Overview") {
            VStack(alignment: .leading, spacing: 0) {
              ForEach(disabledProviders) { provider in
                providerRow(provider, isEnabled: false)
              }
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
    .onAppear {
      enabledProviders = ProviderDisplayOrder.enabledProviders()
    }
  }

  @ViewBuilder
  private func providerRow(_ provider: ProviderID, isEnabled: Bool) -> some View {
    let isRelayReported = relayReportedProviders.contains(provider)
    let row = Button {
      onOpenProvider(provider)
    } label: {
      SettingsListRow(
        title: provider.displayName,
        leading: {
          ProviderBrandIcon(provider: provider, size: QuotaDesign.Layout.settingsIconColumnWidth)
        },
        trailing: {
          HStack(spacing: QuotaDesign.Spacing.inline) {
            if isRelayReported {
              Image(systemName: "network")
                .quotaAffordanceStyle()
                .help("Reported through Relay")
                .accessibilityHidden(true)
            }
            if isEnabled {
              Image(systemName: "line.3.horizontal")
                .quotaAffordanceStyle()
                .frame(
                  width: QuotaDesign.Layout.minimumInteractiveDimension,
                  height: QuotaDesign.Layout.settingsRowHeight
                )
                .contentShape(Rectangle())
                .highPriorityGesture(reorderGesture(for: provider))
                .help("Drag to reorder")
                .accessibilityHidden(true)
            }
            Image(systemName: "chevron.right")
              .quotaChevronStyle()
          }
        }
      )
    }
    .buttonStyle(QuotaListRowButtonStyle())
    .accessibilityLabel(provider.displayName)
    .accessibilityValue(isRelayReported ? "Source: Relay" : "")
    .accessibilityHint(
      "\(isEnabled ? "Shown in Overview" : "Hidden from Overview"). Opens \(provider.displayName) settings"
    )

    if isEnabled {
      row
        .opacity(draggedProvider == provider ? 0.72 : 1)
        .accessibilityActions {
          if enabledProviders.first != provider {
            Button("Move Up") { move(provider, by: -1) }
          }
          if enabledProviders.last != provider {
            Button("Move Down") { move(provider, by: 1) }
          }
        }
    } else {
      row
    }
  }

  private func reorderGesture(for provider: ProviderID) -> some Gesture {
    DragGesture(minimumDistance: 3, coordinateSpace: .global)
      .onChanged { value in
        guard let currentIndex = enabledProviders.firstIndex(of: provider) else { return }
        if draggedProvider != provider {
          draggedProvider = provider
          dragOriginIndex = currentIndex
        }

        let targetIndex = Self.reorderTargetIndex(
          originIndex: dragOriginIndex,
          currentIndex: currentIndex,
          translation: value.translation.height,
          count: enabledProviders.count
        )
        guard targetIndex != currentIndex else { return }

        var reordered = enabledProviders
        let movedProvider = reordered.remove(at: currentIndex)
        reordered.insert(movedProvider, at: targetIndex)
        setOrder(reordered)
      }
      .onEnded { _ in
        draggedProvider = nil
        ProviderDisplayOrder.saveEnabledOrder(enabledProviders)
      }
  }

  /// A 20%-of-row dead band prevents adjacent rows from swapping back and forth at the midpoint.
  static func reorderTargetIndex(
    originIndex: Int,
    currentIndex: Int,
    translation: CGFloat,
    count: Int
  ) -> Int {
    guard count > 0 else { return 0 }

    let pointerIndex = CGFloat(originIndex) + translation / QuotaDesign.Layout.settingsRowHeight
    let threshold: CGFloat = 0.6
    var targetIndex = currentIndex
    while pointerIndex > CGFloat(targetIndex) + threshold, targetIndex < count - 1 {
      targetIndex += 1
    }
    while pointerIndex < CGFloat(targetIndex) - threshold, targetIndex > 0 {
      targetIndex -= 1
    }
    return targetIndex
  }

  private func setOrder(_ providers: [ProviderID]) {
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
      enabledProviders = providers
    }
  }

  private func move(_ provider: ProviderID, by offset: Int) {
    guard let sourceIndex = enabledProviders.firstIndex(of: provider) else { return }
    let destination = sourceIndex + offset
    guard enabledProviders.indices.contains(destination) else { return }

    var reordered = enabledProviders
    reordered.swapAt(sourceIndex, destination)
    applyOrder(reordered)
  }

  private func applyOrder(_ providers: [ProviderID]) {
    setOrder(providers)
    ProviderDisplayOrder.saveEnabledOrder(providers)
  }
}
