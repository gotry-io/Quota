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
    case repairingDurable = "repairing-durable"
    case repairingDerived = "repairing-derived"
    case stuck
    case failed

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
      case .repairingDurable, .repairingDerived, .stuck, .failed:
        MenuBarViewModel(
          visualTestState: contentVisualState(at: referenceDate).withRepair(repairSession(at: referenceDate)),
          errorMessage: nil,
          lastCheckedAt: referenceDate.addingTimeInterval(-30)
        )
      }
    }

    fileprivate func repairSession(at date: Date) -> LocalServiceRepairSession {
      switch self {
      case .repairingDurable:
        LocalServiceRepairSession(
          status: .repairing,
          severity: .durable,
          phase: .preservingAccount,
          title: "Repairing local data",
          guidance: "Keep QuotaBar open. You can close this menu.",
          activity: "Copying account",
          startedAt: date.addingTimeInterval(-14),
          heartbeatAt: date.addingTimeInterval(-2),
          progressCurrent: 3,
          progressTotal: 7,
          stuck: false,
          blocksQuit: true,
          recoveryAction: nil
        )
      case .repairingDerived:
        LocalServiceRepairSession(
          status: .repairing,
          severity: .derived,
          phase: .reindexingUsage,
          title: "Rebuilding Usage history",
          guidance: "Quota and Account stay available. Usage history is catching up.",
          activity: "Scanning local logs",
          startedAt: date.addingTimeInterval(-14),
          heartbeatAt: date.addingTimeInterval(-2),
          progressCurrent: 12,
          progressTotal: 40,
          stuck: false,
          blocksQuit: false,
          recoveryAction: nil
        )
      case .stuck:
        LocalServiceRepairSession(
          status: .stuck,
          severity: .durable,
          phase: .preservingAccount,
          title: "Repairing local data",
          guidance: "Repair stopped responding. You can retry.",
          activity: "Copying account",
          startedAt: date.addingTimeInterval(-60),
          heartbeatAt: date.addingTimeInterval(-50),
          progressCurrent: 3,
          progressTotal: 7,
          stuck: true,
          blocksQuit: false,
          recoveryAction: .retry
        )
      case .failed:
        LocalServiceRepairSession(
          status: .failed,
          severity: .durable,
          phase: .rebuildingStorage,
          title: "Repairing local data",
          guidance: "Reinstall QuotaBar to repair local data.",
          activity: "Rebuilding storage",
          startedAt: date.addingTimeInterval(-90),
          heartbeatAt: date.addingTimeInterval(-80),
          progressCurrent: nil,
          progressTotal: nil,
          stuck: true,
          blocksQuit: false,
          recoveryAction: .reinstall
        )
      default:
        .idle
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
    case diagnostics
    case repair

    fileprivate var path: [MenuBarRoute] {
      switch self {
      case .overview, .repair: []
      case .settings: [.settings]
      case .agents: [.settings, .agents]
      case .providerCodex: [.settings, .agents, .provider(.codex)]
      case .providerOpenRouter: [.settings, .agents, .provider(.openrouter)]
      case .providerCursor: [.settings, .agents, .provider(.cursor)]
      case .devices: [.settings, .devices]
      case .usage: [.settings, .usage]
      case .support: [.settings, .support]
      case .diagnostics: [.settings, .support, .diagnostics]
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
    func makeDiagnosticsModel() -> DiagnosticsPageModel {
      guard dataSource == .fixture else { return DiagnosticsPageModel() }
      switch fixture {
      case .loading:
        return DiagnosticsPageModel(isLoading: true)
      case .content:
        return DiagnosticsPageModel(report: diagnosticVisualReport(at: referenceDate))
      case .cachedRefreshError:
        return DiagnosticsPageModel(
          report: diagnosticVisualReport(at: referenceDate),
          errorMessage: "The latest check failed. Showing the last diagnostics report."
        )
      case .empty:
        return DiagnosticsPageModel(report: signedOutDiagnosticVisualReport(at: referenceDate))
      case .unavailable:
        return DiagnosticsPageModel(errorMessage: "The bundled local service could not be started.")
      case .repairingDurable, .repairingDerived, .stuck, .failed:
        return DiagnosticsPageModel(report: diagnosticVisualReport(at: referenceDate))
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

  private func diagnosticVisualReport(at date: Date) -> LocalServiceDiagnosticReport {
    LocalServiceDiagnosticReport(
      schemaVersion: 2,
      summary: LocalServiceDiagnosticSummary(
        operation: .healthy, data: .current, attention: .none),
      refresh: LocalServiceDiagnosticRefresh(
        phase: .idle, asOf: date, startedAt: nil, nextDueAt: date.addingTimeInterval(300)),
      generatedAt: date,
      client: LocalServiceDiagnosticClient(name: "QuotaBar", version: "Visual QA"),
      surfaces: [
        LocalServiceDiagnosticSurface(
          name: "quota_overview", operation: .healthy, data: .current, source: nil,
          metrics: ["items": 5, "this_device_sources": 3, "account_sources": 2]),
        LocalServiceDiagnosticSurface(
          name: "usage_this_device", operation: .healthy, data: .current, source: .thisDevice,
          metrics: ["records": 128, "files": 4, "partial_hours": 0]),
        LocalServiceDiagnosticSurface(
          name: "usage_account", operation: .healthy, data: .current, source: .account,
          metrics: ["enabled": 1, "periods": 4]),
        LocalServiceDiagnosticSurface(
          name: "account", operation: .healthy, data: .current, source: .account,
          metrics: ["signed_in": 1, "devices": 2]),
      ],
      checks: [],
      findings: []
    )
  }

  private func signedOutDiagnosticVisualReport(at date: Date) -> LocalServiceDiagnosticReport {
    let report = diagnosticVisualReport(at: date)
    return LocalServiceDiagnosticReport(
      schemaVersion: report.schemaVersion,
      summary: LocalServiceDiagnosticSummary(
        operation: .healthy, data: .current, attention: .optional),
      refresh: report.refresh,
      generatedAt: report.generatedAt,
      client: report.client,
      surfaces: report.surfaces,
      checks: [],
      findings: [
        LocalServiceDiagnosticFinding(
          component: "quota_collection",
          source: .thisDevice,
          subject: "provider:codex",
          code: "auth_required",
          severity: .info,
          impact: .none,
          recovery: .login,
          count: 1,
          observedAt: date,
          message: "An opportunistically discovered local source could not be collected."
        )
      ]
    )
  }

  private func signedOutVisualState(at date: Date) -> MenuBarVisualState {
    MenuBarVisualState(
      report: QuotaCollectionReport(
        protocolVersion: 2,
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
      coverage: coverage,
      coverageTruncated: nil
    )
  }

  private func unavailableLocalUsage(at date: Date) -> LocalUsageReport {
    LocalUsageReport(
      generatedAt: date,
      aggregationTimezone: nil,
      range: UsageDateRange(from: "2026-07-03", to: "2026-08-01"),
      status: .unavailable,
      modelCatalogRevision: nil,
      coverage: [],
      coverageTruncated: nil
    )
  }

  private func contentReport(at date: Date) -> QuotaCollectionReport {
    QuotaCollectionReport(
      protocolVersion: 2,
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
      sources: 1
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
      sources: 1
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
