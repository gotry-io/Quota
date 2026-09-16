import QuotaWire
import SwiftUI

/// Main window → Settings → Agents: a provider list beside the selected provider's settings.
struct AgentsSettingsView: View {
  @Bindable var model: MenuBarViewModel
  var initialProvider: ProviderID? = nil

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @AppStorage(MainPage.agentsProviderStorageKey) private var storedProviderRaw = ""
  @State private var enabledProviders = ProviderDisplayOrder.enabledProviders()
  @State private var selectedProvider: ProviderID?
  @State private var draggedProvider: ProviderID?
  @State private var dragOriginIndex = 0

  private var disabledProviders: [ProviderID] {
    let enabled = Set(enabledProviders)
    return ProviderID.allCases.filter { !enabled.contains($0) }
  }

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      HStack(spacing: 0) {
        agentList
          .frame(width: QuotaDesign.Layout.agentsListWidth)
          .frame(maxHeight: .infinity, alignment: .top)
        Divider()
        providerPane(now: context.date)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onAppear(perform: appear)
  }

  private var agentList: some View {
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
  }

  @ViewBuilder
  private func providerPane(now: Date) -> some View {
    if let provider = selectedProvider {
      ProviderSettingsView(
        model: model,
        provider: provider,
        now: now,
        onVisibilityChange: refreshEnabledProviders
      )
      .id(provider)
    } else {
      Text("Select an agent")
        .quotaSecondaryStyle()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  @ViewBuilder
  private func providerRow(_ provider: ProviderID, isEnabled: Bool) -> some View {
    let status = model.agentStatusLine(for: provider)
    let isSelected = selectedProvider == provider
    let row = Button {
      select(provider)
    } label: {
      SettingsListRow(
        title: provider.displayName,
        subtitle: status,
        height: QuotaDesign.Layout.settingsListRowHeight,
        leading: {
          ProviderBrandIcon(provider: provider, size: QuotaDesign.Layout.settingsIconColumnWidth)
        },
        trailing: {
          if isEnabled {
            Image(systemName: "line.3.horizontal")
              .quotaAffordanceStyle()
              .frame(
                width: QuotaDesign.Layout.minimumInteractiveDimension,
                height: QuotaDesign.Layout.settingsListRowHeight
              )
              .contentShape(Rectangle())
              .highPriorityGesture(reorderGesture(for: provider))
              .help("Drag to reorder")
              .accessibilityHidden(true)
          }
        }
      )
      .background {
        RoundedRectangle(
          cornerRadius: QuotaDesign.Layout.rowCornerRadius,
          style: .continuous
        )
        .fill(isSelected ? QuotaPalette.rowHoverFill : Color.clear)
      }
    }
    .buttonStyle(QuotaListRowButtonStyle())
    .accessibilityLabel(provider.displayName)
    .accessibilityValue(status)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityHint(
      "\(isEnabled ? "Shown in Overview" : "Hidden from Overview"). Shows \(provider.displayName) settings"
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

  private func appear() {
    refreshEnabledProviders()
    if let initialProvider {
      select(initialProvider)
    } else if let stored = ProviderID(rawValue: storedProviderRaw),
      ProviderID.allCases.contains(stored)
    {
      select(stored)
    } else {
      select(enabledProviders.first ?? disabledProviders.first)
    }
  }

  private func select(_ provider: ProviderID?) {
    selectedProvider = provider
    storedProviderRaw = provider?.rawValue ?? ""
  }

  private func refreshEnabledProviders() {
    enabledProviders = ProviderDisplayOrder.enabledProviders()
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
