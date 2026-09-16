import QuotaPresentation
import QuotaWire
import SwiftUI

/// Dashboard window root: sidebar of shown providers, Quota cards in the detail column.
struct DashboardView: View {
  @Bindable var model: MenuBarViewModel
  var nowOverride: Date? = nil

  @State private var dashboard: DashboardModel
  @AppStorage(ResetCopyStylePreference.storageKey) private var resetCopyStyle =
    ResetCopyStylePreference.fallback

  init(
    model: MenuBarViewModel,
    now: Date? = nil,
    initialSelection: ProviderID? = nil,
    defaults: UserDefaults = .standard
  ) {
    self.model = model
    nowOverride = now
    _dashboard = State(
      initialValue: DashboardModel(
        model: model, defaults: defaults, selection: initialSelection)
    )
  }

  var body: some View {
    @Bindable var dashboard = dashboard
    // A minute is enough: the header copy is relative time, and every tick refolds the series.
    TimelineView(.periodic(from: .now, by: 60)) { context in
      let now = nowOverride ?? context.date
      NavigationSplitView {
        VStack(alignment: .leading, spacing: 0) {
          sidebarRow(
            title: "All providers",
            provider: nil,
            selected: dashboard.selection == nil
          ) {
            dashboard.selection = nil
          }
          ForEach(dashboard.sidebarProviders, id: \.self) { provider in
            sidebarRow(
              title: provider.displayName,
              provider: provider,
              selected: dashboard.selection == provider
            ) {
              dashboard.selection = provider
            }
          }
          Spacer(minLength: 0)
        }
        .padding(.top, QuotaDesign.Spacing.sm)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationSplitViewColumnWidth(
          min: QuotaDesign.Layout.windowSidebarWidth,
          ideal: QuotaDesign.Layout.windowSidebarWidth,
          max: QuotaDesign.Layout.windowSidebarWidth
        )
      } detail: {
        quotaDetail(now: now, dashboard: dashboard)
      }
      .navigationSplitViewStyle(.balanced)
      .toolbar {
        ToolbarItem(placement: .principal) {
          Picker("Range", selection: $dashboard.range) {
            ForEach(DashboardRange.allCases) { range in
              Text(range.label).tag(range)
            }
          }
          .pickerStyle(.segmented)
          .frame(maxWidth: 240)
          .accessibilityLabel("History range")
        }
        if dashboard.showsUsageSourcePicker {
          ToolbarItem {
            Picker("Usage source", selection: $dashboard.usageSource) {
              Text("Account").tag(UsageSource.account)
              Text("This Mac").tag(UsageSource.local)
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Usage source")
            .accessibilityValue(dashboard.usageSource == .account ? "Account" : "This Mac")
          }
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            guard !model.isRefreshing else { return }
            dashboard.refresh()
          } label: {
            Group {
              if model.isRefreshing {
                ProgressView()
                  .controlSize(.mini)
              } else {
                Image(systemName: "arrow.clockwise")
              }
            }
            .frame(
              width: QuotaDesign.Layout.minimumInteractiveDimension,
              height: QuotaDesign.Layout.minimumInteractiveDimension
            )
            .contentShape(Rectangle())
          }
          .disabled(model.isRefreshing)
          .accessibilityLabel(refreshActionLabel(now: now))
          .help(refreshActionLabel(now: now))
        }
      }
    }
    .frame(
      minWidth: QuotaDesign.Layout.dashboardWindowMinSize.width,
      minHeight: QuotaDesign.Layout.dashboardWindowMinSize.height
    )
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear { dashboard.loadHistory() }
  }

  private func sidebarRow(
    title: String,
    provider: ProviderID?,
    selected: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: QuotaDesign.Spacing.iconLabel) {
        if let provider {
          ProviderBrandIcon(
            provider: provider, size: QuotaDesign.Layout.settingsIconColumnWidth)
        }
        Text(title)
          .quotaSettingsLabelStyle()
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
      .frame(
        maxWidth: .infinity,
        minHeight: QuotaDesign.Layout.settingsListRowHeight,
        alignment: .leading
      )
      .background {
        RoundedRectangle(
          cornerRadius: QuotaDesign.Layout.rowCornerRadius,
          style: .continuous
        )
        .fill(selected ? QuotaPalette.rowHoverFill : Color.clear)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(QuotaListRowButtonStyle())
    .padding(.horizontal, QuotaDesign.Spacing.xxs)
    .accessibilityLabel(title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  @ViewBuilder
  private func quotaDetail(now: Date, dashboard: DashboardModel) -> some View {
    let providers = dashboard.displayedProviders(now: now)
    ScrollView {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.section) {
        ForEach(providers) { provider in
          quotaCard(provider, now: now)
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  @ViewBuilder
  private func quotaCard(_ provider: DashboardProvider, now: Date) -> some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.sm) {
      Text(headerLine(provider, now: now))
        .quotaFont(.settingsLabel)
        .foregroundStyle(QuotaPalette.ink)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityAddTraits(.isHeader)

      if let empty = provider.empty {
        emptyState(empty)
      } else {
        DashboardQuotaChart(series: provider.series, now: now)
      }
    }
    .padding(QuotaDesign.Layout.groupContentInset)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quotaGroupSurface()
    .accessibilityElement(children: .contain)
    .accessibilityLabel(headerLine(provider, now: now))
  }

  @ViewBuilder
  private func emptyState(_ empty: DashboardEmptyState) -> some View {
    switch empty {
    case .rebuilding:
      CacheRebuildNotice()
    case .notSignedIn(let line):
      Text(line)
        .quotaSecondaryStyle()
        .fixedSize(horizontal: false, vertical: true)
    case .noHistory:
      Text("No history yet")
        .quotaSecondaryStyle()
    }
  }

  private func headerLine(_ provider: DashboardProvider, now: Date) -> String {
    var parts = [provider.provider.displayName]
    if let pace = provider.pacePhrase {
      parts.append(pace)
    }
    if let resetsAt = provider.resetsAt,
      let reset = FreshnessCopy.resetCopy(
        resetsAt: resetsAt, now: now, style: resetCopyStyle.style)
    {
      parts.append(reset)
    }
    if let peak = provider.peak {
      parts.append(peak)
    }
    return parts.joined(separator: " · ")
  }

  private func refreshActionLabel(now: Date) -> String {
    "Refresh all quota. \(FreshnessCopy.updated(since: model.lastCheckedAt, now: now))"
  }
}
