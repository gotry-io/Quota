import QuotaPresentation
import QuotaWire
import SwiftUI

/// Main window root: Quota and Usage as top-level rows, then a Settings group.
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
    MainPage.migrateLegacyStoredPage(in: defaults)
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

  private var pageSelection: Binding<MainPage> {
    Binding(
      get: { pageOverride ?? storedPage },
      set: { newValue in
        guard pageOverride == nil else { return }
        storedPage = newValue
      }
    )
  }

  var body: some View {
    @Bindable var dashboard = dashboard
    NavigationSplitView(columnVisibility: .constant(.all)) {
      List(selection: pageSelection) {
        Section {
          ForEach(MainPage.quotaGroup + MainPage.usageGroup) { item in
            sidebarLabel(item).tag(item)
          }
        }
        Section("Settings") {
          ForEach(MainPage.settingsGroup) { item in
            sidebarLabel(item).tag(item)
          }
        }
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(
        min: QuotaDesign.Layout.windowSidebarWidth,
        ideal: QuotaDesign.Layout.windowSidebarWidth,
        max: QuotaDesign.Layout.windowSidebarMaxWidth
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
          Picker(selection: $dashboard.selection) {
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
          } label: {
            providerMenuLabel
          }
          .pickerStyle(.menu)
          .accessibilityLabel("Provider")
          .accessibilityValue(dashboard.selection?.displayName ?? "All providers")
        }
        QuotaToolbarSpacer.Fixed()
        ToolbarItem {
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
          QuotaToolbarSpacer.Fixed()
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
      QuotaToolbarSpacer.Flexible()
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
        get: { model.browserConnection.browserSessionPopup },
        set: { newValue in
          if newValue == nil {
            model.browserConnection.cancelProviderBrowserSessionFlow()
          }
        }
      )
    ) { popup in
      browserSessionSheet(popup)
    }
    .onAppear { dashboard.loadHistory() }
  }

  @ViewBuilder
  private var providerMenuLabel: some View {
    if let provider = dashboard.selection {
      ProviderBrandIcon(
        provider: provider,
        size: QuotaDesign.Layout.settingsIconColumnWidth
      )
    } else {
      BrandAssetIcon(
        assetName: QuotaBrandAssets.assetName,
        size: QuotaDesign.Layout.settingsIconColumnWidth
      )
    }
  }

  @ViewBuilder
  private func sidebarLabel(_ item: MainPage) -> some View {
    if item == .agents {
      Label(item.title, systemImage: item.systemImage)
        .badge(model.agentsSidebarBadge())
    } else {
      Label(item.title, systemImage: item.systemImage)
    }
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
          onCancel: model.browserConnection.cancelProviderBrowserSessionFlow,
          onConfirm: model.browserConnection.confirmProviderBrowserSessionConsent
        )
      }
    }
  }

  @ViewBuilder
  private func detail(now: Date, dashboard: DashboardModel) -> some View {
    switch page {
    case .quota:
      QuotaWindowScroll {
        DashboardView(dashboard: dashboard, now: now)
      }
    case .usage:
      QuotaWindowScroll {
        DashboardUsageView(dashboard: dashboard, now: now)
      }
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
