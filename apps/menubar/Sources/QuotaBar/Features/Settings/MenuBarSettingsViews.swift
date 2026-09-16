import QuotaWire
import SwiftUI

/// Settings window → Menu Bar: style, provider, reset time, and pace lines as one form.
struct MenuBarSettingsView: View {
  var model: MenuBarViewModel?
  /// Visual QA passes the fixture clock so the preview matches those readings.
  var now: Date?
  var visibleProviders: [ProviderID] = ProviderDisplayOrder.enabledProviders()

  @AppStorage(MenuBarStylePreference.storageKey) private var style =
    MenuBarStylePreference.fallback
  @AppStorage(MenuBarProviderPreference.storageKey) private var provider =
    MenuBarProviderPreference.fallback
  @AppStorage(MenuBarArrangementPreference.storageKey) private var arrangement =
    MenuBarArrangementPreference.fallback
  @AppStorage(ResetCopyStylePreference.storageKey) private var resetCopyStyle =
    ResetCopyStylePreference.fallback
  @AppStorage(PaceLinePreference.storageKey) private var showsPaceLines =
    PaceLinePreference.fallback

  var body: some View {
    Form {
      previewSection
      styleSection
      providerSection
      resetTimeSection
      paceSection
    }
    .formStyle(.grouped)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }

  private var currentLayout: MenuBarLayout {
    MenuBarLayout.resolve(
      selection: provider,
      arrangement: arrangement,
      visibleProviders: visibleProviders
    )
  }

  @ViewBuilder
  private var previewSection: some View {
    Section {
      HStack(spacing: previewItemSpacing) {
        ForEach(previewSpecs, id: \.id) { spec in
          QuotaMenuBarLabel(label: spec.label)
        }
      }
      .frame(maxWidth: .infinity)
      .accessibilityElement(children: .combine)
    } header: {
      Text("Preview")
    }
  }

  @ViewBuilder
  private var styleSection: some View {
    Section {
      if MenuBarStylePreference.usesSegmentedPicker {
        stylePicker.pickerStyle(.segmented)
      } else {
        stylePicker.pickerStyle(.menu)
      }
    }
  }

  private var stylePicker: some View {
    Picker("Style", selection: styleSelection) {
      ForEach(MenuBarStylePreference.allCases) { option in
        Text(option.label)
          .tag(option)
          .disabled(isStyleOptionDisabled(option))
      }
    }
  }

  @ViewBuilder
  private var providerSection: some View {
    Section {
      Toggle("Automatic", isOn: automaticIsOn)
      if !provider.isAutomatic {
        ForEach(visibleProviders, id: \.self) { id in
          Toggle(isOn: namedIsOn(id)) {
            HStack(spacing: QuotaDesign.Spacing.sm) {
              ProviderBrandIcon(
                provider: id,
                size: QuotaDesign.Layout.settingsIconColumnWidth
              )
              Text(id.displayName)
            }
          }
          .toggleStyle(.checkbox)
        }
        if currentLayout.showsArrangementControl {
          Picker("Combined / Separate", selection: arrangementSelection) {
            ForEach(MenuBarArrangementPreference.allCases) { option in
              Text(option.label)
                .tag(option)
                .disabled(option == .combined && !currentLayout.isCombinedEnabled)
            }
          }
          .pickerStyle(.segmented)
          .accessibilityIdentifier("menu-bar.arrangement")
        }
      }
    } header: {
      Text("Provider")
    } footer: {
      if !provider.isAutomatic, currentLayout.showsArrangementControl,
        !currentLayout.isCombinedEnabled
      {
        Text("Combined is unavailable past three providers.")
      }
    }
  }

  private var resetTimeSection: some View {
    Section {
      Picker("Reset time", selection: $resetCopyStyle) {
        ForEach(ResetCopyStylePreference.allCases) { option in
          Text(option.label)
            .tag(option)
        }
      }
      .pickerStyle(.segmented)
    } footer: {
      Text(
        ResetCopyStylePreference.allCases
          .map { "\($0.label): \($0.summary)" }
          .joined(separator: "  ·  ")
      )
    }
  }

  private var paceSection: some View {
    Section {
      Toggle("Show pace lines", isOn: $showsPaceLines)
        .accessibilityHint("Draw each window's usage curve and where it lands at reset")
    }
  }

  private var previewSpecs: [MenuBarStatusItemSpec] {
    let layout = currentLayout
    guard let model else {
      return [MenuBarStatusItemSpec(id: .automatic, label: .empty)]
    }
    return model.menuBarSpecs(
      style: layout.effectiveStyle(style),
      layout: layout,
      now: now ?? model.menuBarClock
    )
  }

  private var previewItemSpacing: CGFloat {
    switch currentLayout {
    case .items: 16
    case .packed, .automatic: MenuBarItemImage.cellSpacing
    }
  }

  private var styleSelection: Binding<MenuBarStylePreference> {
    Binding(
      get: { currentLayout.effectiveStyle(style) },
      set: { newValue in
        guard !isStyleOptionDisabled(newValue) else { return }
        style = newValue
      }
    )
  }

  private var automaticIsOn: Binding<Bool> {
    Binding(
      get: { provider.isAutomatic },
      set: { automatic in
        if automatic {
          provider = .automatic
        } else {
          provider = provider.turningAutomaticOff(visibleProviders: visibleProviders)
        }
      }
    )
  }

  private func namedIsOn(_ id: ProviderID) -> Binding<Bool> {
    Binding(
      get: { provider.selected.contains(id) },
      set: { _ in
        provider = provider.toggling(id, visibleProviders: visibleProviders)
      }
    )
  }

  private var arrangementSelection: Binding<MenuBarArrangementPreference> {
    Binding(
      get: { currentLayout.effectiveArrangement },
      set: { newValue in
        guard newValue != .combined || currentLayout.isCombinedEnabled else { return }
        arrangement = newValue
      }
    )
  }

  private func isStyleOptionDisabled(_ option: MenuBarStylePreference) -> Bool {
    currentLayout.usesMultiReadingStyle && (option == .icon || option == .percent)
  }

}
