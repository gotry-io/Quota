import QuotaPresentation
import QuotaWire
import SwiftUI

/// Settings → Agents → <Provider>, read top to bottom as three questions: is it shown, what is
/// it reporting, and how does this Mac sign in.
struct ProviderSettingsView: View {
  @Bindable var model: MenuBarViewModel
  let provider: ProviderID
  let now: Date
  let onOpenSource: (LocalServiceOverviewItem, LocalServiceOverviewSource) -> Void
  let onOpenAPIKey: () -> Void

  @State private var isVisible: Bool
  @State private var expandedOverviewMenuKey: String?

  init(
    model: MenuBarViewModel,
    provider: ProviderID,
    now: Date,
    onOpenSource: @escaping (LocalServiceOverviewItem, LocalServiceOverviewSource) -> Void,
    onOpenAPIKey: @escaping () -> Void
  ) {
    self.model = model
    self.provider = provider
    self.now = now
    self.onOpenSource = onOpenSource
    self.onOpenAPIKey = onOpenAPIKey
    _isVisible = State(initialValue: ProviderVisibility.isVisible(provider))
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        SettingsSection(title: "Overview") {
          SettingsListRow(
            title: "Show in Overview",
            leading: {
              ProviderBrandIcon(
                provider: provider, size: QuotaDesign.Layout.settingsIconColumnWidth)
            },
            trailing: {
              Toggle("Show in Overview", isOn: visibilityBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(QuotaPalette.accent)
                .accessibilityLabel("Show \(provider.displayName) in Overview")
                .accessibilityHint("Show or hide this agent in Overview")
            }
          )
        }

        SettingsSection(title: "Accounts") {
          accountsContent
        }
        .zIndex(expandedOverviewMenuKey == nil ? 0 : 10)

        SettingsSection(title: "Sign-in") {
          signInContent
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
    .scrollClipDisabled()
  }

  // MARK: Accounts

  @ViewBuilder
  private var accountsContent: some View {
    let items = model.overviewItems(for: provider)
    if items.isEmpty {
      Text("No readings yet. Sign in below to start reporting.")
        .quotaSecondaryStyle()
        .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
        .frame(
          maxWidth: .infinity,
          minHeight: QuotaDesign.Layout.settingsRowHeight,
          alignment: .leading
        )
    } else {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(items.enumerated()), id: \.element.pinIdentityKey) { index, item in
          if index > 0 {
            Divider()
              .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
              .padding(.vertical, QuotaDesign.Spacing.xxs)
          }
          accountRow(item, accountIndex: index)
            .zIndex(expandedOverviewMenuKey == item.pinIdentityKey ? 10 : 0)
          ForEach(item.sources, id: \.sourceID) { source in
            sourceRow(item: item, source: source)
          }
        }
      }
    }
  }

  /// The account's masked label and, trailing, the menu that picks which of its sources
  /// Overview shows.
  private func accountRow(_ item: LocalServiceOverviewItem, accountIndex: Int) -> some View {
    let title =
      PlanDisplay.accountLabel(item.snapshot.account.label) ?? "Account \(accountIndex + 1)"
    return HStack(alignment: .center, spacing: QuotaDesign.Spacing.sm) {
      Text(title)
        .quotaFont(.settingsLabel)
        .fontWeight(.semibold)
        .foregroundStyle(QuotaPalette.ink)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
      sourceMenu(for: item)
        .layoutPriority(1)
    }
    .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
    .frame(minHeight: QuotaDesign.Layout.settingsRowHeight - QuotaDesign.Spacing.xxs)
    .accessibilityElement(children: .contain)
    .accessibilityLabel(title)
  }

  private func sourceRow(
    item: LocalServiceOverviewItem,
    source: LocalServiceOverviewSource
  ) -> some View {
    let isCurrent = source.sourceID == item.selectedSourceID
    let freshness = freshnessLabel(source)
    return Button {
      expandedOverviewMenuKey = nil
      onOpenSource(item, source)
    } label: {
      SettingsListRow(
        title: source.displayName,
        leading: {
          SettingsListLeadingIcon(
            systemImage: source.symbolName,
            foreground: isCurrent ? QuotaPalette.accent : QuotaPalette.body,
            filled: isCurrent
          )
        }
      ) {
        HStack(spacing: QuotaDesign.Spacing.xs) {
          Text(freshness)
            .quotaMetaStyle()
            .lineLimit(1)
            .layoutPriority(1)
          Image(systemName: "chevron.right")
            .quotaChevronStyle()
        }
      }
      .padding(.leading, QuotaDesign.Spacing.md)
    }
    .buttonStyle(QuotaListRowButtonStyle())
    .accessibilityLabel(source.displayName)
    .accessibilityValue(isCurrent ? "\(freshness). Showing on Overview" : freshness)
    .accessibilityHint("Opens \(source.displayName)")
  }

  private func sourceMenu(for item: LocalServiceOverviewItem) -> some View {
    let selectedFreshness = item.sources.first { $0.sourceID == item.selectedSourceID }
      .map(freshnessLabel) ?? ""
    let mode = item.sourcePin == nil ? "Automatic" : "Pinned"
    return QuotaChoiceMenu(
      valueTitle: item.sourcePin == nil ? "Automatic" : "Show: \(item.selectedSourceDisplayName)",
      options: sourceMenuOptions(for: item),
      selectedPin: item.sourcePin,
      isExpanded: expandedMenuBinding(for: item),
      onSelect: { pin in
        Task { await model.setOverviewSourcePin(item: item, pin: pin) }
      },
      accessibilityTitle: "Show from",
      accessibilityHint: "Chooses which source Overview shows"
    )
    .accessibilityValue("\(mode). \(item.selectedSourceDisplayName). \(selectedFreshness)")
  }

  private func sourceMenuOptions(for item: LocalServiceOverviewItem) -> [QuotaChoiceMenuOption] {
    [
      QuotaChoiceMenuOption(pin: nil, title: "Automatic", subtitle: "Newest live reading")
    ]
      // A source Relay named without its reading can be seen but not shown: pinning it would
      // put another device's numbers under this one's name.
      + item.sources.filter { $0.snapshot != nil }.map { source in
        QuotaChoiceMenuOption(pin: source.sourceID, title: source.displayName)
      }
  }

  private func expandedMenuBinding(for item: LocalServiceOverviewItem) -> Binding<Bool> {
    Binding(
      get: { expandedOverviewMenuKey == item.pinIdentityKey },
      set: { expandedOverviewMenuKey = $0 ? item.pinIdentityKey : nil }
    )
  }

  private func freshnessLabel(_ source: LocalServiceOverviewSource) -> String {
    FreshnessCopy.observation(
      state: source.isStale ? .stale : .available,
      observedAt: source.observedAt,
      now: now
    )
  }

  // MARK: Sign-in

  @ViewBuilder
  private var signInContent: some View {
    let rungs = model.signInRungs(for: provider)
    VStack(alignment: .leading, spacing: 0) {
      ForEach(rungs) { rung in
        switch rung.kind {
        case .apiKey:
          apiKeyRow(rung)
        case .cli(let command):
          verdictRow(rung, systemImage: "terminal")
          if !rung.isWorking, let command {
            QuotaCommandRow(command: command, copyLabel: "Copy sign-in command")
              .padding(.leading, QuotaDesign.Spacing.md)
              .padding(.bottom, QuotaDesign.Spacing.xxs)
          }
        case .application:
          verdictRow(rung, systemImage: "macwindow")
        case .browser:
          browserRow(rung)
        }
      }
    }
  }

  private func apiKeyRow(_ rung: SignInRung) -> some View {
    Button(action: onOpenAPIKey) {
      SettingsListRow(
        title: rung.title,
        subtitle: rung.detail,
        systemImage: "key",
        height: rung.detail == nil
          ? QuotaDesign.Layout.settingsRowHeight : QuotaDesign.Layout.settingsListRowHeight
      ) {
        HStack(spacing: QuotaDesign.Spacing.xs) {
          statusLabel(rung)
          Image(systemName: "chevron.right")
            .quotaChevronStyle()
        }
      }
    }
    .buttonStyle(QuotaListRowButtonStyle())
    .accessibilityLabel("\(rung.title). \(rung.statusTitle)")
    .accessibilityHint("Opens API key settings")
  }

  private func verdictRow(_ rung: SignInRung, systemImage: String) -> some View {
    SettingsListRow(
      title: rung.title,
      subtitle: rung.detail,
      systemImage: systemImage,
      height: rung.detail == nil
        ? QuotaDesign.Layout.settingsRowHeight : QuotaDesign.Layout.settingsListRowHeight
    ) {
      statusLabel(rung)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(rung.title). \(rung.statusTitle)")
  }

  private func statusLabel(_ rung: SignInRung) -> some View {
    Text(rung.statusTitle)
      .quotaFont(.meta)
      .foregroundStyle(
        rung.isWorking
          ? QuotaPalette.accent
          : rung.needsAttention ? QuotaPalette.warning : QuotaPalette.body
      )
      .lineLimit(1)
  }

  @ViewBuilder
  private func browserRow(_ rung: SignInRung) -> some View {
    let enabled = model.browserScanEnabled.contains(provider)
    let waiting = model.browserSessionWaitingProvider == provider
    SettingsListRow(
      title: rung.title,
      subtitle: rung.detail,
      systemImage: "safari",
      height: QuotaDesign.Layout.settingsListRowHeight
    ) {
      Toggle(
        rung.title,
        isOn: Binding(
          get: { enabled },
          set: { model.setBrowserScanEnabled(provider, enabled: $0) }
        )
      )
      .labelsHidden()
      .toggleStyle(.switch)
      .controlSize(.mini)
      .tint(QuotaPalette.accent)
      .disabled(waiting)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(rung.title)
    .accessibilityHint("Use sign-ins from browsers on this Mac")
    .disabled(waiting)

    if waiting, let activity = model.browserSessionActivityText {
      Text(activity)
        .quotaMetaStyle()
        .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
        .padding(.bottom, QuotaDesign.Spacing.xxs)
    }

    if enabled, let summary = model.browserAccessSummary {
      Button {
        model.showBrowserAccessGrants()
      } label: {
        SettingsListRow(
          title: BrowserSessionCopy.accessRowTitle,
          subtitle: summary,
          systemImage: "exclamationmark.triangle",
          height: QuotaDesign.Layout.settingsListRowHeight
        ) {
          Image(systemName: "chevron.right")
            .quotaChevronStyle()
        }
        .padding(.leading, QuotaDesign.Spacing.md)
      }
      .buttonStyle(QuotaListRowButtonStyle())
      .accessibilityLabel("\(BrowserSessionCopy.accessRowTitle). \(summary)")
      .accessibilityHint("Opens the Browser Access window")
    }

    if let denial = model.browserSessionAccessDenials[provider],
      !model.coversAccessDenial(denial)
    {
      Label(denial.message, systemImage: "exclamationmark.triangle")
        .quotaMetaStyle()
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
        .padding(.bottom, QuotaDesign.Spacing.xs)
        .accessibilityLabel("\(denial.browserName) cookies could not be read")
        .accessibilityValue(denial.message)
    } else if let message = model.browserSessionErrorMessages[provider] {
      Label(message, systemImage: "exclamationmark.circle")
        .quotaMetaStyle()
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
        .padding(.bottom, QuotaDesign.Spacing.xs)
    }
  }

  private var visibilityBinding: Binding<Bool> {
    Binding(
      get: { isVisible },
      set: { newValue in
        expandedOverviewMenuKey = nil
        ProviderVisibility.setVisible(provider, newValue)
        isVisible = newValue
      }
    )
  }
}
