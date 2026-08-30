import QuotaWire
import SwiftUI

/// Settings → Menu Bar → Style: what each item shows.
struct MenuBarStyleSettingsView: View {
  let onSelect: () -> Void

  @AppStorage(MenuBarStylePreference.storageKey) private var style =
    MenuBarStylePreference.fallback
  @AppStorage(MenuBarProviderPreference.storageKey) private var provider =
    MenuBarProviderPreference.fallback
  @AppStorage(MenuBarArrangementPreference.storageKey) private var arrangement =
    MenuBarArrangementPreference.fallback

  var body: some View {
    let layout = currentLayout
    let effective = layout.effectiveStyle(style)
    MenuBarChoiceList {
      ForEach(MenuBarStylePreference.allCases) { option in
        let locked = layout.usesMultiReadingStyle && option != .iconAndPercent
        MenuBarChoiceRow(
          title: option.label,
          isSelected: option == effective,
          isEnabled: !locked
        ) {
          guard !locked else { return }
          style = option
          onSelect()
        }
      }
    }
  }

  private var currentLayout: MenuBarLayout {
    MenuBarLayout.resolve(
      selection: provider,
      arrangement: arrangement,
      visibleProviders: ProviderDisplayOrder.enabledProviders()
    )
  }
}

/// Settings → Menu Bar → Provider: whose remaining quota the bar answers for.
///
/// Only providers Overview is showing are offered, because a number the panel does not carry has
/// no business in the menu bar either. Automatic is exclusive with the named set. Two or three
/// named providers can share one packed item; four or more are always separate items.
struct MenuBarProviderSettingsView: View {
  let providers: [ProviderID]

  @AppStorage(MenuBarProviderPreference.storageKey) private var provider =
    MenuBarProviderPreference.fallback
  @AppStorage(MenuBarArrangementPreference.storageKey) private var arrangement =
    MenuBarArrangementPreference.fallback

  var body: some View {
    let layout = MenuBarLayout.resolve(
      selection: provider,
      arrangement: arrangement,
      visibleProviders: providers
    )
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        MenuBarChoiceGroup {
          MenuBarChoiceRow(
            title: MenuBarProviderPreference.automatic.label,
            isSelected: layout == .automatic
          ) {
            provider = .automatic
          }

          ForEach(providers, id: \.self) { id in
            MenuBarChoiceRow(
              title: id.displayName,
              isSelected: provider.selected.contains(id),
              leading: {
                ProviderBrandIcon(provider: id, size: QuotaDesign.Layout.settingsIconColumnWidth)
              }
            ) {
              provider = provider.toggling(id, visibleProviders: providers)
            }
          }
        }

        if showsArrangement(layout) {
          MenuBarChoiceGroup {
            ForEach(MenuBarArrangementPreference.allCases) { option in
              let combinedDisabled =
                option == .combined && !canCombine(layout)
              MenuBarChoiceRow(
                title: option.label,
                subtitle: option.summary,
                isSelected: isArrangementSelected(option, layout: layout),
                isEnabled: !combinedDisabled
              ) {
                guard !combinedDisabled else { return }
                arrangement = option
              }
            }
          }
        }
      }
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
  }

  private func showsArrangement(_ layout: MenuBarLayout) -> Bool {
    switch layout {
    case .packed: true
    case .items(let providers): providers.count >= 2
    case .automatic: false
    }
  }

  private func canCombine(_ layout: MenuBarLayout) -> Bool {
    switch layout {
    case .packed: true
    case .items(let providers): providers.count <= MenuBarProviderPreference.combinedLimit
    case .automatic: false
    }
  }

  private func isArrangementSelected(
    _ option: MenuBarArrangementPreference,
    layout: MenuBarLayout
  ) -> Bool {
    switch (option, layout) {
    case (.combined, .packed): true
    case (.separate, .items(let providers)) where providers.count >= 2: true
    default: false
    }
  }
}

/// A page that is one list of options and nothing else, so it carries no section header to
/// repeat the title already in the header.
private struct MenuBarChoiceList<Content: View>: View {
  @ViewBuilder var content: () -> Content

  var body: some View {
    ScrollView {
      MenuBarChoiceGroup(content: content)
        .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
        .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
  }
}

private struct MenuBarChoiceGroup<Content: View>: View {
  @ViewBuilder var content: () -> Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .quotaGroupSurface()
  }
}

/// One option: its name, and a checkmark on the one in force.
struct MenuBarChoiceRow<Leading: View>: View {
  let title: String
  var subtitle: String? = nil
  let isSelected: Bool
  var isEnabled: Bool = true
  @ViewBuilder var leading: () -> Leading
  let select: () -> Void

  init(
    title: String,
    subtitle: String? = nil,
    isSelected: Bool,
    isEnabled: Bool = true,
    @ViewBuilder leading: @escaping () -> Leading,
    select: @escaping () -> Void
  ) {
    self.title = title
    self.subtitle = subtitle
    self.isSelected = isSelected
    self.isEnabled = isEnabled
    self.leading = leading
    self.select = select
  }

  var body: some View {
    Button(action: select) {
      SettingsListRow(
        title: title,
        subtitle: subtitle,
        height: subtitle == nil
          ? QuotaDesign.Layout.settingsRowHeight
          : QuotaDesign.Layout.settingsListRowHeight,
        leading: leading
      ) {
        Image(systemName: "checkmark")
          .quotaFont(.secondary)
          .foregroundStyle(QuotaPalette.accent)
          .opacity(isSelected ? 1 : 0)
      }
    }
    .buttonStyle(QuotaListRowButtonStyle())
    .disabled(!isEnabled)
    .opacity(isEnabled ? 1 : 0.45)
    .accessibilityLabel(title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}

extension MenuBarChoiceRow where Leading == EmptyView {
  init(
    title: String,
    subtitle: String? = nil,
    isSelected: Bool,
    isEnabled: Bool = true,
    select: @escaping () -> Void
  ) {
    self.init(
      title: title,
      subtitle: subtitle,
      isSelected: isSelected,
      isEnabled: isEnabled,
      leading: { EmptyView() },
      select: select
    )
  }
}
