import QuotaPresentation
import QuotaWire
import SwiftUI

/// Main window root: one sidebar of Quota and Settings groups, detail per `MainPage`.
struct MainWindowView: View {
  @Bindable var model: MenuBarViewModel
  var pageOverride: MainPage? = nil
  var expandsDiagnostics: Bool = false
  var initialAgentsProvider: ProviderID? = nil
  /// Visual QA passes the fixture clock so quota charts and the Menu Bar preview match.
  var nowOverride: Date? = nil

  @State private var dashboard: DashboardModel
  @State private var diagnostics: DiagnosticsPageModel
  @AppStorage(MainPage.storageKey) private var storedPage = MainPage.quota
  @AppStorage(ResetCopyStylePreference.storageKey) private var resetCopyStyle =
    ResetCopyStylePreference.fallback

  init(
    model: MenuBarViewModel,
    pageOverride: MainPage? = nil,
    diagnostics: DiagnosticsPageModel? = nil,
    expandsDiagnostics: Bool = false,
    initialAgentsProvider: ProviderID? = nil,
    now: Date? = nil,
    initialSelection: ProviderID? = nil,
    initialUsageSource: UsageSource = .account,
    defaults: UserDefaults = .standard
  ) {
    self.model = model
    self.pageOverride = pageOverride
    self.expandsDiagnostics = expandsDiagnostics
    self.initialAgentsProvider = initialAgentsProvider
    nowOverride = now
    _dashboard = State(
      initialValue: DashboardModel(
        model: model,
        defaults: defaults,
        selection: initialSelection,
        usageSource: initialUsageSource
      )
    )
    _diagnostics = State(initialValue: diagnostics ?? DiagnosticsPageModel())
  }

  private var page: MainPage { pageOverride ?? storedPage }

  var body: some View {
    @Bindable var dashboard = dashboard
    NavigationSplitView(columnVisibility: .constant(.all)) {
      VStack(alignment: .leading, spacing: QuotaDesign.Spacing.md) {
        sidebarSection("Quota", items: MainPage.quotaGroup)
        sidebarSection("Settings", items: MainPage.settingsGroup)
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
      if let nowOverride {
        detail(now: nowOverride, dashboard: dashboard)
      } else {
        TimelineView(.periodic(from: .now, by: 60)) { context in
          detail(now: context.date, dashboard: dashboard)
        }
      }
    }
    .toolbar {
      if page.isQuotaGroup {
        ToolbarItem {
          Picker("Provider", selection: $dashboard.selection) {
            Text("All providers").tag(Optional<ProviderID>.none)
            ForEach(dashboard.sidebarProviders, id: \.self) { provider in
              Label {
                Text(provider.displayName)
              } icon: {
                ProviderBrandIcon(
                  provider: provider, size: QuotaDesign.Layout.settingsIconColumnWidth)
              }
              .tag(Optional(provider))
            }
          }
          .pickerStyle(.menu)
          .accessibilityLabel("Provider")
          .accessibilityValue(dashboard.selection?.displayName ?? "All providers")
        }
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
        .accessibilityLabel(refreshActionLabel(now: nowOverride ?? Date()))
        .help(refreshActionLabel(now: nowOverride ?? Date()))
      }
    }
    .frame(
      minWidth: QuotaDesign.Layout.mainWindowMinSize.width,
      minHeight: QuotaDesign.Layout.mainWindowMinSize.height
    )
    .background(Color(nsColor: .windowBackgroundColor))
    .sheet(
      item: Binding(
        get: { model.browserSessionPopup },
        set: { newValue in
          if newValue == nil {
            model.cancelProviderBrowserSessionFlow()
          }
        }
      )
    ) { popup in
      browserSessionSheet(popup)
    }
    .onAppear { dashboard.loadHistory() }
  }

  private func sidebarSection(_ title: String, items: [MainPage]) -> some View {
    VStack(alignment: .leading, spacing: QuotaDesign.Spacing.xxs) {
      Text(title)
        .quotaSectionHeaderStyle()
        .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
      ForEach(items) { item in
        sidebarRow(item)
      }
    }
  }

  private func sidebarRow(_ item: MainPage) -> some View {
    let selected = page == item
    return Button {
      guard pageOverride == nil else { return }
      storedPage = item
    } label: {
      HStack(spacing: QuotaDesign.Spacing.iconLabel) {
        Label(item.title, systemImage: item.systemImage)
          .labelStyle(.titleAndIcon)
          .quotaSettingsLabelStyle()
          .lineLimit(1)
        Spacer(minLength: 0)
        if item == .agents {
          Text(model.agentsSidebarBadge())
            .quotaMetaStyle()
            .lineLimit(1)
        }
      }
      .padding(.horizontal, QuotaDesign.Layout.groupContentInset)
      .frame(
        maxWidth: .infinity,
        minHeight: QuotaDesign.Layout.settingsRowHeight,
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
    .accessibilityLabel(item.title)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }

  @ViewBuilder
  private func browserSessionSheet(_ popup: ProviderBrowserSessionPopup) -> some View {
    switch popup {
    case .consent(let provider):
      if let spec = provider.browserSession {
        QuotaConfirmationPopup(
          title: BrowserSessionCopy.consentTitle(provider: provider),
          message: BrowserSessionCopy.scanConsentMessage(provider: provider, spec: spec),
          confirmTitle: BrowserSessionCopy.consentConfirmTitle,
          style: .sheet,
          onCancel: model.cancelProviderBrowserSessionFlow,
          onConfirm: model.confirmProviderBrowserSessionConsent
        )
      }
    }
  }

  @ViewBuilder
  private func detail(now: Date, dashboard: DashboardModel) -> some View {
    switch page {
    case .quota:
      DashboardView(dashboard: dashboard, now: now)
    case .today:
      ScrollView {
        DashboardTodayTable(
          rows: dashboard.todayRows(now: now, resetStyle: resetCopyStyle.style)
        )
        .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
        .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    case .usage:
      ScrollView {
        DashboardUsageView(dashboard: dashboard, now: now)
          .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
          .padding(.vertical, QuotaDesign.Layout.pageVerticalPadding)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    case .account:
      AccountSettingsView(model: model)
    case .notifications:
      NotificationsSettingsView(model: model)
    case .general:
      GeneralSettingsView(model: model)
    case .support:
      SettingsSupportView(
        model: model,
        diagnostics: diagnostics,
        expandsDiagnostics: expandsDiagnostics
      )
    case .agents:
      AgentsSettingsView(model: model, initialProvider: initialAgentsProvider)
    case .menuBar:
      MenuBarSettingsView(model: model, now: now)
    }
  }

  private func refreshActionLabel(now: Date) -> String {
    "Refresh all quota. \(FreshnessCopy.updated(since: model.lastCheckedAt, now: now))"
  }
}
