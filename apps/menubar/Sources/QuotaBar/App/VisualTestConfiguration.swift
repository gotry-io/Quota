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
    case agents
    case providerCodex = "provider-codex"
    case providerOpenRouter = "provider-openrouter"
    case providerCursor = "provider-cursor"
    case devices
    case usage
    case support

    fileprivate var path: [MenuBarRoute] {
      switch self {
      case .overview: []
      case .settings: [.settings]
      case .agents: [.settings, .agents]
      case .providerCodex: [.settings, .agents, .provider(.codex)]
      case .providerOpenRouter: [.settings, .agents, .provider(.openrouter)]
      case .providerCursor: [.settings, .agents, .provider(.cursor)]
      case .devices: [.settings, .devices]
      case .usage: [.settings, .usage]
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
      localUsage: localUsageReport(at: date, summary: accountSummary.usage),
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
          message: "5 subscriptions shown · 3 read on this Mac · 2 from the account.",
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

  /// The Overview the service would return for this Account, resolved by the shared rule so
  /// a visual fixture shows what the panel actually shows rather than one row per upload.
  private func overviewItems(
    summary: AccountSummary,
    now: Date
  ) -> [LocalServiceOverviewItem] {
    func displayName(_ deviceID: String) -> String {
      summary.devices.first { $0.deviceID == deviceID }?.displayName ?? "Account device"
    }
    return AccountQuotaSubscriptions.resolve(summary.quota, now: now).map { subscription in
      let sources = subscription.sources.map { source in
        LocalServiceOverviewSource(
          sourceID: "device:\(source.deviceID)",
          kind: .device,
          deviceID: source.deviceID,
          displayName: displayName(source.deviceID),
          observedAt: source.observedAt,
          isStale: source.isStale
        )
      }
      let selectedSourceID = "device:\(subscription.selectedDeviceID)"
      return LocalServiceOverviewItem(
        identity: LocalServiceOverviewIdentity(
          provider: subscription.reading.provider,
          fingerprint: subscription.identity.fingerprint,
          scope: subscription.identity.sourceID == nil ? .global : .source,
          sourceID: subscription.identity.sourceID.map { "device:\($0)" }
        ),
        snapshot: subscription.reading,
        sources: sources,
        selectedSourceID: selectedSourceID,
        selectedSourceDisplayName: displayName(subscription.selectedDeviceID),
        isStale: subscription.isStale
      )
    }
  }

  private func localUsageReport(
    at date: Date,
    summary: AccountUsageSummary
  ) -> LocalUsageReport {
    let coverage = [
      LocalUsageCoverage(
        agent: .codex,
        startAt: "2026-08-02T00:00:00Z",
        endAt: "2026-08-03T00:00:00Z",
        status: summary.coverage == .partial ? .partial : .complete
      )
    ]
    return LocalUsageReport(
      generatedAt: date,
      aggregationTimezone: "UTC",
      range: summary.range,
      status: summary.coverage == .partial ? .partial : .complete,
      modelCatalogRevision: "visual-model-catalog",
      coverage: coverage
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
    let observations = snapshots.enumerated().map { index, snapshot in
      AccountQuotaObservation(
        deviceID: index == 2 ? travelID : studioID,
        snapshot: snapshot,
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
          deviceID: studioID,
          displayName: "Studio Mac",
          platform: .macos,
          deviceGeneration: 3,
          status: .active,
          createdAt: date.addingTimeInterval(-30 * 86_400),
          lastLoginAt: date.addingTimeInterval(-5 * 86_400),
          lastSeenAt: date.addingTimeInterval(-45),
          signedOutAt: nil
        ),
        AccountDevice(
          deviceID: travelID,
          displayName: "Travel Mac",
          platform: .macos,
          deviceGeneration: 2,
          status: .offline,
          createdAt: date.addingTimeInterval(-20 * 86_400),
          lastLoginAt: date.addingTimeInterval(-10 * 86_400),
          lastSeenAt: date.addingTimeInterval(-3 * 86_400),
          signedOutAt: nil
        ),
      ],
      quota: observations,
      usage: visualUsageSummary(at: date, studioID: studioID, travelID: travelID)
    )
  }

  private func visualUsageSummary(
    at date: Date,
    studioID: String,
    travelID: String
  ) -> AccountUsageSummary {
    let totals = UsageTokenTotals(
      inputTokens: 1_420_500,
      cacheReadTokens: 480_000,
      cacheWrite5mTokens: 20_000,
      cacheWrite1hTokens: 0,
      cacheWriteInferredTokens: 0,
      outputTokens: 284_120,
      reasoningTokens: 92_400,
      requests: 164,
      webSearchRequests: 8,
      webFetchRequests: 3,
      sourceCostMicrousd: nil,
      sourceCostCoveredRequests: 0
    )
    let cost = UsageCostOutcome(
      mode: .calculate,
      basis: .calculated,
      status: .partial,
      amountMicrousd: "1489234",
      catalogRevision: "pricing_2026_08_01",
      calculatedRows: 162,
      reportedRows: 0,
      unpricedRows: 2,
      assumptions: [.agentDefaultChannel, .modelAlias],
      unpriced: [
        UsageUnpricedItem(
          billingChannel: .unknown,
          model: "custom-model",
          reason: .unknownModel,
          rows: 2
        )
      ]
    )
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .iso8601)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    let to = formatter.string(from: date)
    let from = formatter.string(from: date.addingTimeInterval(-6 * 86_400))
    let summary = AccountUsageSummary(
      range: UsageDateRange(from: from, to: to),
      totals: totals,
      cost: cost,
      coverage: .partial,
      breakdowns: [
        UsageBreakdown(
          dimension: .model,
          key: "gpt-5",
          totals: UsageTokenTotals(
            inputTokens: 1_120_000,
            cacheReadTokens: 400_000,
            cacheWrite5mTokens: 10_000,
            cacheWrite1hTokens: 0,
            cacheWriteInferredTokens: 0,
            outputTokens: 240_000,
            reasoningTokens: 80_000,
            requests: 132,
            webSearchRequests: 6,
            webFetchRequests: 2,
            sourceCostMicrousd: nil,
            sourceCostCoveredRequests: 0
          ),
          cost: UsageCostOutcome(
            mode: .calculate,
            basis: .calculated,
            status: .complete,
            amountMicrousd: "1200000",
            catalogRevision: "pricing_2026_08_01",
            calculatedRows: 1,
            reportedRows: 0,
            unpricedRows: 0,
            assumptions: [.modelAlias],
            unpriced: []
          )
        ),
        UsageBreakdown(
          dimension: .model,
          key: "claude-sonnet-4",
          totals: UsageTokenTotals(
            inputTokens: 300_500,
            cacheReadTokens: 80_000,
            cacheWrite5mTokens: 10_000,
            cacheWrite1hTokens: 0,
            cacheWriteInferredTokens: 0,
            outputTokens: 44_120,
            reasoningTokens: 12_400,
            requests: 32,
            webSearchRequests: 2,
            webFetchRequests: 1,
            sourceCostMicrousd: nil,
            sourceCostCoveredRequests: 0
          ),
          cost: UsageCostOutcome(
            mode: .calculate,
            basis: .calculated,
            status: .complete,
            amountMicrousd: "289234",
            catalogRevision: "pricing_2026_08_01",
            calculatedRows: 1,
            reportedRows: 0,
            unpricedRows: 0,
            assumptions: [.modelAlias],
            unpriced: []
          )
        ),
      ]
    )
    return AccountUsageSummary(
      range: summary.range,
      totals: summary.totals,
      cost: summary.cost,
      modelCatalogRevision: summary.modelCatalogRevision,
      coverage: summary.coverage,
      breakdowns: summary.breakdowns,
      agents: summary.breakdowns.enumerated().map { index, breakdown in
        let totals = UsageSummaryTotals(breakdown.totals)
        let provider = index == 0 ? InferenceProvider.openai : .anthropic
        let client = index == 0 ? BillingAgent.codex : .claudeCode
        let model = LocalUsageModelSummary(
          model: breakdown.key,
          totals: totals,
          cost: breakdown.cost
        )
        return LocalUsageAgentSummary(
          agent: client,
          totals: totals,
          cost: breakdown.cost,
          providers: [
            LocalUsageProviderSummary(
              provider: provider,
              totals: totals,
              cost: breakdown.cost,
              models: [model]
            )
          ]
        )
      },
      breakdownsTruncated: summary.breakdownsTruncated
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
