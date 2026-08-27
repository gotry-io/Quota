#if DEBUG
  import QuotaPresentation
  import QuotaWire
  import SwiftUI

  enum VisualTestDataSource: String {
    case fixture
    case live
  }

  enum VisualTestFixture: String {
    case loading
    case content
    case cachedRefreshError = "cached-refresh-error"
    case empty
    case unavailable
    case cacheRebuilding = "cache-rebuilding"

    @MainActor
    fileprivate func makeModel(referenceDate: Date) -> MenuBarViewModel {
      switch self {
      case .loading:
        MenuBarViewModel(
          visualTestState: nil,
          errorMessage: nil,
          lastCheckedAt: nil
        )
      case .content, .cachedRefreshError:
        MenuBarViewModel(
          visualTestState: contentVisualState(at: referenceDate),
          errorMessage: self == .cachedRefreshError
            ? "Sync failed. Showing the last known result."
            : nil,
          lastCheckedAt: referenceDate.addingTimeInterval(
            self == .cachedRefreshError ? -180 : -30
          )
        )
      case .empty:
        MenuBarViewModel(
          visualTestState: signedOutVisualState(at: referenceDate),
          errorMessage: nil,
          lastCheckedAt: referenceDate.addingTimeInterval(-30)
        )
      case .unavailable:
        MenuBarViewModel(
          visualTestState: nil,
          errorMessage: "The bundled local service could not be started.",
          lastCheckedAt: nil
        )
      case .cacheRebuilding:
        MenuBarViewModel(
          visualTestState: rebuildingVisualState(at: referenceDate),
          errorMessage: nil,
          lastCheckedAt: referenceDate.addingTimeInterval(-30)
        )
      }
    }

  }

  enum VisualTestRoute: String {
    case overview
    case settings
    case account
    case agents
    case providerCodex = "provider-codex"
    case providerOpenRouter = "provider-openrouter"
    case providerCursor = "provider-cursor"
    case devices
    case usage
    case menuBarStyle = "menu-bar-style"
    case menuBarProvider = "menu-bar-provider"
    case support

    fileprivate var path: [MenuBarRoute] {
      switch self {
      case .overview: []
      case .settings: [.settings]
      case .account: [.settings, .account]
      case .agents: [.settings, .agents]
      case .providerCodex: [.settings, .agents, .provider(.codex)]
      case .providerOpenRouter: [.settings, .agents, .provider(.openrouter)]
      case .providerCursor: [.settings, .agents, .provider(.cursor)]
      case .devices: [.settings, .account, .devices]
      case .usage: [.settings, .usage]
      case .menuBarStyle: [.settings, .menuBarStyle]
      case .menuBarProvider: [.settings, .menuBarProvider]
      case .support: [.settings, .support]
      }
    }
  }

  enum VisualTestAppearance: String {
    case system
    case light
    case dark

    fileprivate var colorScheme: ColorScheme? {
      switch self {
      case .system: nil
      case .light: .light
      case .dark: .dark
      }
    }
  }

  enum VisualTestTextSize: String {
    case standard
    case extraLarge = "extra-large"
    case accessibility

    fileprivate var dynamicTypeSize: DynamicTypeSize {
      switch self {
      case .standard: .large
      case .extraLarge: .xxxLarge
      case .accessibility: .accessibility3
      }
    }
  }

  struct VisualTestConfiguration {
    let dataSource: VisualTestDataSource
    let fixture: VisualTestFixture
    let route: VisualTestRoute
    let appearance: VisualTestAppearance
    let textSize: VisualTestTextSize
    let referenceDate: Date

    init?(
      arguments: [String],
      referenceDate: Date = Date(timeIntervalSince1970: 1_785_752_430)
    ) {
      guard
        let dataSource: VisualTestDataSource = Self.argument(
          "--data-source",
          in: arguments,
          default: .fixture
        ),
        let fixture: VisualTestFixture = Self.argument(
          "--fixture",
          in: arguments,
          default: .content
        ),
        let route: VisualTestRoute = Self.argument(
          "--route",
          in: arguments,
          default: .overview
        ),
        let appearance: VisualTestAppearance = Self.argument(
          "--appearance",
          in: arguments,
          default: .system
        ),
        let textSize: VisualTestTextSize = Self.argument(
          "--text-size",
          in: arguments,
          default: .standard
        )
      else { return nil }

      self.dataSource = dataSource
      self.fixture = fixture
      self.route = route
      self.appearance = appearance
      self.textSize = textSize
      self.referenceDate = referenceDate
    }

    var initialPath: [MenuBarRoute] { route.path }
    var colorScheme: ColorScheme? { appearance.colorScheme }
    var dynamicTypeSize: DynamicTypeSize { textSize.dynamicTypeSize }
    var performsInitialRefresh: Bool { dataSource == .live }

    @MainActor
    func makeModel() -> MenuBarViewModel {
      switch dataSource {
      case .fixture: fixture.makeModel(referenceDate: referenceDate)
      case .live: MenuBarViewModel()
      }
    }

    @MainActor
    func makeSupportModel() -> SupportPageModel {
      guard dataSource == .fixture else { return SupportPageModel() }
      switch fixture {
      case .loading:
        return SupportPageModel(isLoading: true)
      case .content:
        return SupportPageModel(report: supportVisualReport(at: referenceDate))
      case .cachedRefreshError:
        return SupportPageModel(
          report: supportVisualReport(at: referenceDate),
          errorMessage: "The latest check failed. Showing the last report."
        )
      case .empty:
        return SupportPageModel(report: signedOutSupportVisualReport(at: referenceDate))
      case .unavailable:
        return SupportPageModel(errorMessage: "The bundled local service could not be started.")
      case .cacheRebuilding:
        return SupportPageModel(report: supportVisualReport(at: referenceDate))
      }
    }

    func prepareEnvironment() {
      ProviderDisplayOrder.reset()
      for provider in ProviderID.allCases {
        ProviderVisibility.setVisible(provider, provider.defaultVisible)
      }
    }

    private static func argument<Value: RawRepresentable>(
      _ flag: String,
      in arguments: [String],
      default defaultValue: Value
    ) -> Value? where Value.RawValue == String {
      guard let index = arguments.firstIndex(of: flag) else { return defaultValue }
      let valueIndex = arguments.index(after: index)
      guard valueIndex < arguments.endIndex else { return nil }
      return Value(rawValue: arguments[valueIndex])
    }

  }

  /// The panel a Mac shows right after its cache was thrown away: quota still reads, and the
  /// notice says local Usage history is on its way back.
  private func rebuildingVisualState(at date: Date) -> MenuBarVisualState {
    var state = contentVisualState(at: date)
    state.cache = LocalServiceCacheState(
      rebuilding: true,
      resetAt: date.addingTimeInterval(-14)
    )
    return state
  }

  private func contentVisualState(at date: Date) -> MenuBarVisualState {
    let report = contentReport(at: date)
    let accountSummary = contentAccountSummary(at: date, report: report)
    return MenuBarVisualState(
      report: report,
      localUsage: localUsageReport(at: date, partial: accountSummary.usage.today.partial),
      accountSummary: accountSummary,
      authStatus: .signedIn,
      overview: overviewItems(summary: accountSummary, now: date)
    )
  }

  private func supportVisualReport(at date: Date) -> LocalServiceDiagnosticReport {
    LocalServiceDiagnosticReport(
      generatedAt: date,
      client: LocalServiceDiagnosticClient(name: "QuotaBar", version: "Visual QA"),
      summary: LocalServiceDiagnosticSummary(operation: .healthy, attention: .none),
      surfaces: [
        LocalServiceDiagnosticSurface(
          id: "quota_overview", status: .ok, data: .current, lastSuccessAt: date,
          message: "5 subscriptions shown, all current.",
          recovery: .none),
        LocalServiceDiagnosticSurface(
          id: "usage_this_device", status: .ok, data: .current, lastSuccessAt: date,
          message: "128 records read from 4 agents.", recovery: .none),
        LocalServiceDiagnosticSurface(
          id: "usage_account", status: .ok, data: .current, lastSuccessAt: date,
          message: "Usage from this Mac is part of your account totals.", recovery: .none),
        LocalServiceDiagnosticSurface(
          id: "account", status: .ok, data: .current, lastSuccessAt: date,
          message: "Signed in · 2 devices.", recovery: .none),
      ],
      sources: [
        LocalServiceDiagnosticSource(
          subject: "provider:codex", sourceID: "oauth", status: .ok, lastAttemptAt: date,
          lastSuccessAt: date, message: "Quota was read on this Mac.", recovery: .none),
        LocalServiceDiagnosticSource(
          subject: "agent:claude_code", status: .ok, lastAttemptAt: date, lastSuccessAt: date,
          message: "Usage records were read on this Mac.", recovery: .none),
      ],
      recent: [
        LocalServiceDiagnosticAttempt(
          kind: .refresh, subject: nil, startedAt: date.addingTimeInterval(-30),
          durationMs: 2_400, outcome: .success, code: nil)
      ]
    )
  }

  private func signedOutSupportVisualReport(at date: Date) -> LocalServiceDiagnosticReport {
    let report = supportVisualReport(at: date)
    return LocalServiceDiagnosticReport(
      generatedAt: report.generatedAt,
      client: report.client,
      summary: LocalServiceDiagnosticSummary(operation: .healthy, attention: .required),
      surfaces: report.surfaces,
      sources: [
        LocalServiceDiagnosticSource(
          subject: "provider:codex",
          sourceID: "chatgpt_usage_api",
          status: .degraded,
          lastAttemptAt: date,
          code: "auth_required",
          message:
            "The saved sign-in expired or was rejected. Open Codex to refresh the sign-in.",
          recovery: .configureProvider
        )
      ],
      recent: report.recent
    )
  }

  private func signedOutVisualState(at date: Date) -> MenuBarVisualState {
    MenuBarVisualState(
      report: QuotaCollectionReport(
        capturedAt: date,
        results: [
          failureResult(
            provider: .codex,
            outcome: .authRequired,
            message: "Run `codex` to sign in."
          ),
          failureResult(
            provider: .claude,
            outcome: .authRequired,
            message: "Run `claude auth login`."
          ),
          failureResult(
            provider: .grok,
            outcome: .unavailable,
            message: "Grok quota is temporarily unavailable."
          ),
        ]
      ),
      localUsage: unavailableLocalUsage(at: date),
      accountSummary: nil,
      authStatus: .signedOut,
      overview: []
    )
  }

  /// The Overview the service would return for this Account.
  ///
  /// Relay resolves an account's readings into one row per subscription, so a fixture shows
  /// those rows rather than one per upload.
  private func overviewItems(
    summary: AccountSummary,
    now: Date
  ) -> [LocalServiceOverviewItem] {
    func displayName(_ deviceID: String) -> String {
      summary.devices.first { $0.id == deviceID }?.displayName ?? "Account device"
    }
    return summary.subscriptions.map { subscription in
      let isStale = subscription.snapshot.isStale(now: now)
      let sources = subscription.sources.map { source in
        LocalServiceOverviewSource(
          sourceID: "device:\(source.deviceID)",
          kind: .device,
          deviceID: source.deviceID,
          displayName: displayName(source.deviceID),
          observedAt: source.observedAt,
          isStale: source.observedAt != subscription.snapshot.observedAt || isStale
        )
      }
      let selectedDeviceID = subscription.sources
        .first { $0.observedAt == subscription.snapshot.observedAt }?
        .deviceID ?? subscription.sources.first?.deviceID ?? "unknown"
      return LocalServiceOverviewItem(
        identity: LocalServiceOverviewIdentity(
          provider: subscription.snapshot.provider,
          fingerprint: subscription.snapshot.account.fingerprint,
          scope: subscription.snapshot.account.fingerprintScope == .source ? .source : .global,
          sourceID: subscription.snapshot.account.fingerprintScope == .source
            ? "device:\(selectedDeviceID)" : nil
        ),
        snapshot: subscription.snapshot,
        sources: sources,
        selectedSourceID: "device:\(selectedDeviceID)",
        selectedSourceDisplayName: displayName(selectedDeviceID),
        isStale: isStale
      )
    }
  }

  private func localUsageReport(at date: Date, partial: Bool) -> LocalUsageReport {
    LocalUsageReport(
      generatedAt: date,
      aggregationTimezone: "UTC",
      range: UsageDateRange(from: "2026-08-02", to: "2026-08-02"),
      status: partial ? .partial : .complete,
      modelCatalogRevision: "visual-model-catalog",
      coverage: [
        LocalUsageCoverage(
          agent: .codex,
          startAt: "2026-08-02T00:00:00Z",
          endAt: "2026-08-03T00:00:00Z",
          status: partial ? .partial : .complete
        )
      ]
    )
  }

  private func unavailableLocalUsage(at date: Date) -> LocalUsageReport {
    LocalUsageReport(
      generatedAt: date,
      aggregationTimezone: nil,
      range: UsageDateRange(from: "2026-07-03", to: "2026-08-01"),
      status: .unavailable,
      modelCatalogRevision: nil,
      coverage: []
    )
  }

  private func contentReport(at date: Date) -> QuotaCollectionReport {
    QuotaCollectionReport(
      capturedAt: date,
      results: [
        successResult(
          provider: .codex,
          snapshots: [
            snapshot(
              provider: .codex,
              fingerprint: "visual_personal",
              label: "pe***@example.com",
              plan: "Plus",
              windows: [
                window(
                  id: "five_hour",
                  title: "5 hour",
                  usedPercent: 32,
                  resetsAt: date.addingTimeInterval(2_700)
                ),
                window(
                  id: "weekly",
                  title: "Weekly",
                  usedPercent: 16,
                  resetsAt: date.addingTimeInterval(4 * 86_400)
                ),
              ],
              observedAt: date.addingTimeInterval(-90)
            )
          ]
        ),
        successResult(
          provider: .claude,
          snapshots: [
            snapshot(
              provider: .claude,
              fingerprint: "visual_claude",
              label: "Team workspace",
              plan: "Max",
              windows: [
                window(
                  id: "session",
                  title: "Session",
                  usedPercent: 47,
                  resetsAt: date.addingTimeInterval(7_200)
                )
              ],
              observedAt: date.addingTimeInterval(-120)
            )
          ]
        ),
        successResult(
          provider: .grok,
          snapshots: [
            snapshot(
              provider: .grok,
              fingerprint: "visual_grok",
              label: nil,
              plan: "SuperGrok",
              windows: [
                window(
                  id: "monthly",
                  title: "Monthly",
                  usedPercent: 73,
                  resetsAt: date.addingTimeInterval(12 * 86_400)
                )
              ],
              observedAt: date.addingTimeInterval(-180)
            )
          ]
        ),
      ]
    )
  }

  private func contentAccountSummary(
    at date: Date,
    report: QuotaCollectionReport
  ) -> AccountSummary {
    let studioID = "device_visual_studio_mac_01"
    let travelID = "device_visual_travel_mac_02"
    let snapshots = report.results.flatMap(\.snapshots)
    let subscriptions = snapshots.enumerated().map { index, snapshot in
      let deviceID = index == 2 ? travelID : studioID
      let scope = snapshot.account.fingerprintScope == .source ? "source" : "global"
      return QuotaSubscription(
        key: "\(snapshot.provider.rawValue)|\(snapshot.account.fingerprint)|\(scope)|",
        provider: snapshot.provider,
        snapshot: snapshot,
        sources: [
          QuotaSubscriptionSource(deviceID: deviceID, observedAt: snapshot.observedAt)
        ]
      )
    }
    return AccountSummary(
      account: QuotaUserAccount(
        accountID: "account_visual_octocat",
        displayLabel: "octocat",
        createdAt: date.addingTimeInterval(-30 * 86_400)
      ),
      devices: [
        AccountDevice(
          id: studioID,
          displayName: "Studio Mac",
          platform: .macos,
          lastSeenAt: date.addingTimeInterval(-45),
          lastObservedAt: date.addingTimeInterval(-60)
        ),
        AccountDevice(
          id: travelID,
          displayName: "Travel Mac",
          platform: .macos,
          lastSeenAt: date.addingTimeInterval(-3 * 86_400),
          lastObservedAt: date.addingTimeInterval(-3 * 86_400)
        ),
      ],
      subscriptions: subscriptions,
      usage: visualAccountUsage(),
      pricingRevision: "pricing_2026_08_01",
      modelCatalogRevision: "visual-model-catalog"
    )
  }

  /// A managed period states totals and cost at the period and at the model leaf; the panel
  /// folds what it shows in between.
  private func visualAccountUsage() -> AccountUsage {
    let totals = UsageSummaryTotals(
      totalTokens: 1_704_620,
      inputTokens: 1_420_500,
      outputTokens: 284_120,
      cacheReadInputTokens: 480_000,
      cacheWriteInputTokens: 20_000,
      reasoningTokens: 92_400,
      messages: 164
    )
    let cost = UsageCostOutcome(
      mode: .calculate,
      basis: .calculated,
      status: .partial,
      amountMicrousd: "1489234",
      catalogRevision: "pricing_2026_08_01",
      calculatedRows: 2,
      reportedRows: 0,
      unpricedRows: 1,
      assumptions: [.modelAlias],
      unpriced: [
        UsageUnpricedItem(
          billingChannel: .anthropicDirect,
          model: "claude-opus-4",
          reason: .unknownModel,
          rows: 1
        )
      ]
    )
    let model = { (name: String, provider: InferenceProvider, amount: String) in
      UsageModelUsage(
        model: name,
        totals: UsageSummaryTotals(
          totalTokens: 852_310,
          inputTokens: 710_250,
          outputTokens: 142_060,
          cacheReadInputTokens: 240_000,
          cacheWriteInputTokens: 10_000,
          reasoningTokens: 46_200,
          messages: 82
        ),
        cost: UsageCostOutcome(
          mode: .calculate,
          basis: .calculated,
          status: .complete,
          amountMicrousd: amount,
          catalogRevision: "pricing_2026_08_01",
          calculatedRows: 1,
          reportedRows: 0,
          unpricedRows: 0,
          assumptions: [.modelAlias],
          unpriced: []
        )
      )
    }
    let period = QuotaWire.UsagePeriod(
      totals: totals,
      cost: cost,
      partial: true,
      agents: [
        UsageAgentUsage(
          agent: .codex,
          providers: [
            UsageProviderUsage(provider: .openai, models: [model("gpt-5", .openai, "1200000")])
          ]
        ),
        UsageAgentUsage(
          agent: .claudeCode,
          providers: [
            UsageProviderUsage(
              provider: .anthropic,
              models: [model("claude-sonnet-4", .anthropic, "289234")]
            )
          ]
        ),
      ]
    )
    return AccountUsage(
      today: period,
      last7Days: period,
      last30Days: period,
      all: period
    )
  }

  private func successResult(
    provider: ProviderID,
    snapshots: [QuotaSnapshot]
  ) -> QuotaCollectionResult {
    QuotaCollectionResult(
      provider: provider,
      outcome: .success,
      snapshots: snapshots,
      source: nil,
      message: nil,
      sources: [
        QuotaCollectionSource(sourceID: "browser_session", outcome: .success, category: .success)
      ],
      accessDenied: nil
    )
  }

  private func failureResult(
    provider: ProviderID,
    outcome: CollectionOutcome,
    message: String
  ) -> QuotaCollectionResult {
    QuotaCollectionResult(
      provider: provider,
      outcome: outcome,
      snapshots: [],
      source: nil,
      message: message,
      // A Mac whose stored sign-ins were rejected, not one that never had them.
      sources: [
        QuotaCollectionSource(
          sourceID: "browser_session",
          outcome: outcome,
          category: CollectionSourceCategory(rawValue: outcome.rawValue) ?? .error
        )
      ],
      accessDenied: nil
    )
  }

  private func snapshot(
    provider: ProviderID,
    fingerprint: String,
    label: String?,
    plan: String?,
    windows: [QuotaWindow],
    observedAt: Date
  ) -> QuotaSnapshot {
    QuotaSnapshot(
      provider: provider,
      account: QuotaAccount(
        fingerprint: fingerprint,
        label: label,
        plan: plan,
        fingerprintScope: .global
      ),
      windows: windows,
      status: .available,
      observedAt: observedAt
    )
  }

  private func window(
    id: String,
    title: String,
    usedPercent: Double,
    resetsAt: Date?
  ) -> QuotaWindow {
    QuotaWindow(
      id: id,
      title: title,
      usedPercent: usedPercent,
      resetsAt: resetsAt,
      durationSeconds: nil
    )
  }
#endif
