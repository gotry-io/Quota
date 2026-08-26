import QuotaWire
import SwiftUI

/// Settings → Menu Bar → Style: what the item shows.
struct MenuBarStyleSettingsView: View {
  let onSelect: () -> Void

  @AppStorage(MenuBarStylePreference.storageKey) private var style =
    MenuBarStylePreference.fallback

  var body: some View {
    MenuBarChoiceList {
      ForEach(MenuBarStylePreference.allCases) { option in
        MenuBarChoiceRow(
          title: option.label,
          isSelected: option == style,
          leading: { EmptyView() }
        ) {
          style = option
          onSelect()
        }
      }
    }
  }
}

/// Settings → Menu Bar → Provider: whose remaining quota the item answers for.
///
/// Only providers Overview is showing are offered, because a number the panel does not carry has
/// no business in the menu bar either.
struct MenuBarProviderSettingsView: View {
  let providers: [ProviderID]
  let onSelect: () -> Void

  @AppStorage(MenuBarProviderPreference.storageKey) private var provider =
    MenuBarProviderPreference.fallback

  var body: some View {
    MenuBarChoiceList {
      ForEach(MenuBarProviderPreference.choices(visibleProviders: providers)) { choice in
        MenuBarChoiceRow(
          title: choice.label,
          isSelected: choice == provider,
          leading: {
            // Automatic is not a provider, so it wears no provider's mark.
            if case .provider(let id) = choice {
              ProviderBrandIcon(provider: id, size: QuotaDesign.Layout.settingsIconColumnWidth)
            }
          }
        ) {
          provider = choice
          onSelect()
        }
      }
    }
  }
}

/// A page that is one list of options and nothing else, so it carries no section header to
/// repeat the title already in the header.
private struct MenuBarChoiceList<Content: View>: View {
  @ViewBuilder var content: () -> Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .quotaGroupSurface()
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
  }
}

/// One option: its name, and a checkmark on the one in force. Choosing is the whole page, so it
/// takes effect and returns rather than waiting for a confirmation nobody would give.
private struct MenuBarChoiceRow<Leading: View>: View {
  let title: String
  let isSelected: Bool
  @ViewBuilder var leading: () -> Leading
  let select: () -> Void

  var body: some View {
    Button(action: select) {
      SettingsListRow(title: title, leading: leading) {
        Image(systemName: "checkmark")
          .quotaFont(.secondary)
          .foregroundStyle(QuotaPalette.accent)
          .opacity(isSelected ? 1 : 0)
      }
    }
    .buttonStyle(QuotaListRowButtonStyle())
    .accessibilityLabel(title)
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }
}
