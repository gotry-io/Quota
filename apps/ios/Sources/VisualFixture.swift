import Foundation
import QuotaAccount
import QuotaRelay
import QuotaWire

/// Launch-argument visual fixtures for deterministic simulator screenshots.
/// Parser is always available for unit tests; UI state application is DEBUG-only.
enum VisualFixture: String, CaseIterable, Sendable {
  case signedOut = "signed-out"
  case connecting
  case connectError = "connect-error"
  case expired
  case confirmAccount = "confirm-account"
  case connectRefreshFailed = "connect-refresh-failed"
  case loading
  case content
  case cachedError = "cached-error"
  case empty
  case noDevices = "no-devices"

  /// Parse `--visual-fixture <name>` from process arguments. Returns nil when absent or unknown.
  static func parse(arguments: [String]) -> VisualFixture? {
    guard let index = arguments.firstIndex(of: "--visual-fixture") else { return nil }
    let valueIndex = arguments.index(after: index)
    guard valueIndex < arguments.endIndex else { return nil }
    return VisualFixture(rawValue: arguments[valueIndex])
  }
}

#if DEBUG
  extension VisualFixture {
    /// Fixed reference instant for deterministic tests (2026-08-14T16:00:00Z).
    /// Runtime `--visual-fixture` launches pass `Date()` instead so ages and resets stay current.
    static let referenceDate = Date(timeIntervalSince1970: 1_786_723_200)

    @MainActor
    func apply(to model: AppModel, now: Date) {
      model.skipsRestore = true
      switch self {
      case .signedOut:
        model.phase = .signedOut
        model.summary = nil
        model.fetchedAt = nil
        model.fromCache = false
        model.isRefreshing = false
        model.banner = nil
        model.expiredMessage = nil
      case .connecting:
        model.phase = .connecting
        model.summary = nil
        model.fetchedAt = nil
        model.fromCache = false
        model.isRefreshing = false
        model.banner = nil
        model.expiredMessage = nil
      case .connectError:
        model.phase = .signedOut
        model.summary = nil
        model.fetchedAt = nil
        model.fromCache = false
        model.isRefreshing = false
        model.banner = AppModel.Banner(
          kind: .refreshFailed,
          text: AuthorizationError.genericConnectFailureMessage,
          symbolName: "exclamationmark.triangle"
        )
        model.expiredMessage = nil
      case .expired:
        model.phase = .signedOut
        model.summary = nil
        model.fetchedAt = nil
        model.fromCache = false
        model.isRefreshing = false
        model.banner = nil
        model.expiredMessage = "Session expired. Connect again."
      case .loading:
        model.phase = .launching
        model.summary = nil
        model.fetchedAt = nil
        model.fromCache = false
        model.isRefreshing = false
        model.banner = nil
        model.expiredMessage = nil
      case .confirmAccount:
        let summary = VisualFixtureContent.summary(at: now)
        model.phase = .confirmingAccount(label: summary.account.displayLabel ?? "octocat")
        model.summary = summary
        model.fetchedAt = now.addingTimeInterval(-90)
        model.fromCache = false
        model.isRefreshing = false
        model.banner = nil
        model.expiredMessage = nil
      case .connectRefreshFailed:
        model.phase = .pendingRefreshFailed
        model.summary = nil
        model.fetchedAt = nil
        model.fromCache = false
        model.isRefreshing = false
        model.banner = AppModel.Banner(
          kind: .refreshFailed,
          text: "Could not reach quota.gotry.io.",
          symbolName: "exclamationmark.triangle"
        )
        model.expiredMessage = nil
      case .content:
        model.phase = .signedIn
        model.summary = VisualFixtureContent.summary(at: now)
        model.fetchedAt = now.addingTimeInterval(-90)
        model.fromCache = false
        model.isRefreshing = false
        model.banner = nil
        model.expiredMessage = nil
        model.activityChart = .loaded(VisualFixtureContent.activityDays(ending: now))
      case .cachedError:
        model.phase = .signedIn
        model.summary = VisualFixtureContent.summary(at: now)
        model.fetchedAt = now.addingTimeInterval(-180)
        model.fromCache = true
        model.isRefreshing = false
        model.banner = AppModel.Banner(
          kind: .offlineCached,
          text: AppModel.Banner.cachedText,
          symbolName: "icloud.slash"
        )
        model.expiredMessage = nil
        model.activityChart = .loaded(VisualFixtureContent.activityDays(ending: now))
      case .empty, .noDevices:
        model.phase = .signedIn
        model.summary = VisualFixtureContent.emptySummary(at: now)
        model.fetchedAt = now.addingTimeInterval(-60)
        model.fromCache = false
        model.isRefreshing = false
        model.banner = nil
        model.expiredMessage = nil
        model.activityChart = .loaded([])
      }
    }
  }

  @MainActor
  enum VisualFixtureContent {
    static func summary(at date: Date) -> AccountSummary {
      let studioID = "device_visual_fixture_01"
      let kitchenID = "device_visual_fixture_02"
      let subscriptions = [
        codexSubscription(studioID: studioID, kitchenID: kitchenID, at: date),
        subscription(
          provider: .claude,
          deviceID: studioID,
          fingerprint: "visual_claude",
          label: "Team workspace",
          plan: "Max",
          windows: [
            window(
              id: "five_hour",
              title: "5 Hours",
              usedPercent: 47,
              resetsAt: date.addingTimeInterval(7_200)
            )
          ],
          observedAt: date.addingTimeInterval(-120),
        ),
        subscription(
          provider: .grok,
          deviceID: studioID,
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
          observedAt: date.addingTimeInterval(-180),
        ),
      ]

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
            lastObservedAt: date.addingTimeInterval(-90)
          ),
          AccountDevice(
            id: kitchenID,
            displayName: "Kitchen Mac",
            platform: .macos,
            lastSeenAt: date.addingTimeInterval(-300),
            lastObservedAt: date.addingTimeInterval(-360)
          ),
        ],
        subscriptions: subscriptions,
        usage: usage(),
        pricingRevision: "pricing_visual_fixture",
        modelCatalogRevision: "models_visual_fixture"
      )
    }

    static func emptySummary(at date: Date) -> AccountSummary {
      AccountSummary(
        account: QuotaUserAccount(
          accountID: "account_visual_empty",
          displayLabel: "octocat",
          createdAt: date.addingTimeInterval(-30 * 86_400)
        ),
        devices: [],
        subscriptions: [],
        usage: emptyUsage(),
        pricingRevision: "pricing_visual_fixture",
        modelCatalogRevision: "models_visual_fixture"
      )
    }

    private static func usage() -> AccountUsage {
      AccountUsage(
        today: period(
          input: 1_420_500,
          output: 284_120,
          cacheRead: 480_000,
          cacheWrite: 20_000,
          reasoning: 92_400,
          messages: 164,
          microusd: "1489234",
          scale: 1
        ),
        last7Days: period(
          input: 3_800_000,
          output: 760_000,
          cacheRead: 1_000_000,
          cacheWrite: 40_000,
          reasoning: 240_000,
          messages: 410,
          microusd: "3200000",
          scale: 3
        ),
        last30Days: period(
          input: 9_500_000,
          output: 1_900_000,
          cacheRead: 2_500_000,
          cacheWrite: 80_000,
          reasoning: 600_000,
          messages: 980,
          microusd: "8500000",
          scale: 8
        ),
        all: period(
          input: 18_000_000,
          output: 3_600_000,
          cacheRead: 5_000_000,
          cacheWrite: 150_000,
          reasoning: 1_100_000,
          messages: 1_800,
          microusd: "16200000",
          scale: 15
        )
      )
    }

    private static func period(
      input: Int,
      output: Int,
      cacheRead: Int,
      cacheWrite: Int,
      reasoning: Int,
      messages: Int,
      microusd: String,
      scale: Int
    ) -> UsagePeriod {
      UsagePeriod(
        totals: totals(
          input: input,
          output: output,
          cacheRead: cacheRead,
          cacheWrite: cacheWrite,
          reasoning: reasoning,
          messages: messages
        ),
        cost: completeCost(microusd: microusd, rows: messages),
        partial: false,
        agents: agents(scale: scale)
      )
    }

    static func dayAgents() -> [UsageAgentUsage] {
      agents(scale: 1)
    }

    private static func agents(scale: Int) -> [UsageAgentUsage] {
      [
        UsageAgentUsage(
          agent: .codex,
          providers: [
            UsageProviderUsage(
              provider: .openai,
              models: [
                model(
                  "gpt-4.1", input: 80_000, output: 16_000, messages: 12, microusd: 120_000,
                  scale: scale),
                model(
                  "gpt-4o", input: 60_000, output: 12_000, messages: 10, microusd: 90_000,
                  scale: scale),
                model(
                  "gpt-5", input: 200_000, output: 40_000, messages: 28, microusd: 400_000,
                  scale: scale),
                model(
                  "gpt-5-codex", input: 150_000, output: 30_000, messages: 20, microusd: 280_000,
                  scale: scale),
                model(
                  "o3", input: 40_000, output: 8_000, messages: 6, microusd: 70_000, scale: scale),
                model(
                  "o4-mini", input: 30_000, output: 6_000, messages: 5, microusd: 40_000,
                  scale: scale),
                model(
                  "other", input: 20_000, output: 4_000, messages: 4, microusd: 15_000, scale: scale
                ),
              ]
            )
          ]
        ),
        UsageAgentUsage(
          agent: .claudeCode,
          providers: [
            UsageProviderUsage(
              provider: .anthropic,
              models: [
                model(
                  "claude-sonnet-4", input: 100_000, output: 20_000, messages: 18,
                  microusd: 210_000,
                  scale: scale),
                model(
                  "claude-opus-4", input: 50_000, output: 10_000, messages: 8, microusd: 180_000,
                  scale: scale),
              ]
            )
          ]
        ),
        UsageAgentUsage(
          agent: .grok,
          providers: [
            UsageProviderUsage(
              provider: .xai,
              models: [
                model(
                  "grok-4", input: 90_000, output: 18_000, messages: 14, microusd: 95_000,
                  scale: scale),
                model(
                  "grok-3", input: 40_000, output: 8_000, messages: 7, microusd: 30_000,
                  scale: scale),
              ]
            )
          ]
        ),
      ]
    }

    private static func model(
      _ name: String,
      input: Int,
      output: Int,
      messages: Int,
      microusd: Int,
      scale: Int
    ) -> UsageModelUsage {
      let scaledInput = input * scale
      let scaledOutput = output * scale
      let scaledMessages = messages * scale
      return UsageModelUsage(
        model: name,
        totals: totals(
          input: scaledInput,
          output: scaledOutput,
          cacheRead: scaledInput / 4,
          cacheWrite: 0,
          reasoning: scaledOutput / 4,
          messages: scaledMessages
        ),
        cost: completeCost(microusd: String(microusd * scale), rows: scaledMessages)
      )
    }

    private static func totals(
      input: Int,
      output: Int,
      cacheRead: Int,
      cacheWrite: Int,
      reasoning: Int,
      messages: Int
    ) -> UsageSummaryTotals {
      UsageSummaryTotals(
        totalTokens: input + output,
        inputTokens: input,
        outputTokens: output,
        cacheReadInputTokens: cacheRead,
        cacheWriteInputTokens: cacheWrite,
        reasoningTokens: reasoning,
        messages: messages
      )
    }

    private static func completeCost(microusd: String, rows: Int) -> UsageCostOutcome {
      UsageCostOutcome(
        mode: .calculate,
        basis: .calculated,
        status: .complete,
        amountMicrousd: microusd,
        catalogRevision: "pricing_visual_fixture",
        calculatedRows: rows,
        reportedRows: 0,
        unpricedRows: 0,
        assumptions: [.agentDefaultChannel],
        unpriced: []
      )
    }

    static func activityDays(ending now: Date) -> [UsageActivityDay] {
      let today = UsageActivityCalendar.utcDay(from: now)
      func day(_ offset: Int, input: Int, output: Int, microusd: String, partial: Bool = false)
        -> UsageActivityDay
      {
        let date = UsageActivityCalendar.addDays(offset, to: today)
        return UsageActivityDay(
          date: date,
          totals: totals(
            input: input,
            output: output,
            cacheRead: input / 4,
            cacheWrite: 0,
            reasoning: output / 4,
            messages: 4
          ),
          cost: completeCost(microusd: microusd, rows: 4),
          partial: partial,
          agents: nil
        )
      }
      return [
        day(0, input: 90_000, output: 18_000, microusd: "95000"),
        day(-1, input: 40_000, output: 8_000, microusd: "30000", partial: true),
        day(-2, input: 10_000, output: 2_000, microusd: "8000"),
        day(-5, input: 200_000, output: 40_000, microusd: "400000"),
        day(-8, input: 5_000, output: 1_000, microusd: "4000"),
        day(-20, input: 80_000, output: 16_000, microusd: "120000"),
        day(-40, input: 30_000, output: 6_000, microusd: "40000"),
        day(-90, input: 150_000, output: 30_000, microusd: "280000"),
        day(-180, input: 20_000, output: 4_000, microusd: "15000"),
      ]
    }

    private static func emptyUsage() -> AccountUsage {
      let period = UsagePeriod(
        totals: UsageSummaryTotals(
          totalTokens: 0,
          inputTokens: 0,
          outputTokens: 0,
          cacheReadInputTokens: 0,
          cacheWriteInputTokens: 0,
          reasoningTokens: 0,
          messages: 0
        ),
        cost: UsageCostOutcome(
          mode: .calculate,
          basis: .none,
          status: .complete,
          amountMicrousd: nil,
          catalogRevision: nil,
          calculatedRows: 0,
          reportedRows: 0,
          unpricedRows: 0,
          assumptions: [],
          unpriced: []
        ),
        partial: false,
        agents: []
      )
      return AccountUsage(
        today: period,
        last7Days: period,
        last30Days: period,
        all: period
      )
    }

    /// Codex reports from two Macs so subscription detail can show per-device readings.
    /// Studio Mac is the selected source (newer); Kitchen Mac is the other reading.
    private static func codexSubscription(
      studioID: String,
      kitchenID: String,
      at date: Date
    ) -> QuotaSubscription {
      let studioObserved = date.addingTimeInterval(-90)
      let kitchenObserved = date.addingTimeInterval(-360)
      let studio = QuotaSnapshot(
        provider: .codex,
        account: QuotaAccount(
          fingerprint: "visual_codex",
          label: "pe***@example.com",
          plan: "Plus",
          fingerprintScope: .global
        ),
        windows: [
          window(
            id: "five_hour",
            title: "5 Hours",
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
        status: .available,
        observedAt: studioObserved
      )
      let kitchen = QuotaSnapshot(
        provider: .codex,
        account: QuotaAccount(
          fingerprint: "visual_codex",
          label: "pe***@example.com",
          plan: "Plus",
          fingerprintScope: .global
        ),
        windows: [
          window(
            id: "five_hour",
            title: "5 Hours",
            usedPercent: 41,
            resetsAt: date.addingTimeInterval(2_100)
          ),
          window(
            id: "weekly",
            title: "Weekly",
            usedPercent: 22,
            resetsAt: date.addingTimeInterval(4 * 86_400)
          ),
        ],
        status: .available,
        observedAt: kitchenObserved
      )
      return QuotaSubscription(
        key: "codex|visual_codex|global|",
        provider: .codex,
        snapshot: studio,
        sources: [
          QuotaSubscriptionSource(
            deviceID: kitchenID, observedAt: kitchenObserved, snapshot: kitchen),
          QuotaSubscriptionSource(deviceID: studioID, observedAt: studioObserved, snapshot: studio),
        ]
      )
    }

    private static func subscription(
      provider: ProviderID,
      deviceID: String,
      fingerprint: String,
      label: String?,
      plan: String?,
      windows: [QuotaWindow],
      observedAt: Date
    ) -> QuotaSubscription {
      let snapshot = QuotaSnapshot(
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
      return QuotaSubscription(
        key: "\(provider.rawValue)|\(fingerprint)|global|",
        provider: provider,
        snapshot: snapshot,
        sources: [
          QuotaSubscriptionSource(deviceID: deviceID, observedAt: observedAt, snapshot: snapshot)
        ]
      )
    }

    private static func window(
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

  }

  extension AppModel {
    /// Build a model preloaded with a visual fixture. Does not touch network or Keychain.
    /// Pass an explicit `now` (e.g. `VisualFixture.referenceDate` in tests, `Date()` at launch).
    static func visualFixture(
      _ fixture: VisualFixture,
      now: Date,
      selectionSaltStore: any SelectionSaltStore = InMemorySelectionSaltStore()
    ) -> AppModel {
      let days: [UsageActivityDay]
      switch fixture {
      case .content, .cachedError:
        days = VisualFixtureContent.activityDays(ending: now)
      case .signedOut, .connecting, .connectError, .expired, .confirmAccount, .connectRefreshFailed,
        .loading, .empty, .noDevices:
        days = []
      }
      let model = AppModel(
        account: AccountClient(
          relay: RelayClient(transport: FixtureBlockedHTTPTransport()),
          sessionStore: MemoryAccountSessionStore(),
          summaryStore: MemoryAccountSummaryStore(),
          now: { now }
        ),
        authenticator: FixtureBlockedAuthenticator(),
        widgetPublisher: NoOpWidgetSnapshotPublisher(),
        selectionSaltStore: selectionSaltStore,
        activity: FixtureActivityLoader(
          days: days,
          populatedAgents: VisualFixtureContent.dayAgents()
        ),
        now: { now }
      )
      fixture.apply(to: model, now: now)
      model.resolvePendingSubscriptionSelection()
      return model
    }
  }

  /// Answers the heatmap and a single-day `detail=agents` read without touching Relay.
  private final class FixtureActivityLoader: ActivityLoading, @unchecked Sendable {
    let days: [UsageActivityDay]
    let populatedAgents: [UsageAgentUsage]

    init(days: [UsageActivityDay], populatedAgents: [UsageAgentUsage]) {
      self.days = days
      self.populatedAgents = populatedAgents
    }

    func fetchUsageActivity(
      from: String,
      to: String,
      detail: ActivityDetail?
    ) async -> AccountActivityResult {
      if from == to {
        let base = days.first { $0.date == from } ?? UsageActivityChart.emptyDay(date: from)
        let agents: [UsageAgentUsage] =
          detail == .agents && base.totals.totalTokens > 0
          ? populatedAgents
          : (detail == .agents ? [] : (base.agents ?? []))
        let day = UsageActivityDay(
          date: base.date,
          totals: base.totals,
          cost: base.cost,
          partial: base.partial,
          agents: detail == .agents ? agents : nil
        )
        return .activity(AccountUsageActivityResponse(days: [day]))
      }
      return .activity(AccountUsageActivityResponse(days: days))
    }
  }

  /// Transport that fails if any network call is attempted during a visual fixture session.
  private final class FixtureBlockedHTTPTransport: HTTPTransport, @unchecked Sendable {
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
      throw HTTPTransportError.unavailable
    }
  }

  @MainActor
  private final class FixtureBlockedAuthenticator: BrowserSessionAuthenticating {
    func authenticate(
      url: URL,
      callbackScheme: String,
      prefersEphemeralWebBrowserSession: Bool
    ) async throws -> URL {
      throw AuthorizationError.cancelled
    }

    func present(
      url: URL,
      callbackScheme: String?,
      prefersEphemeralWebBrowserSession: Bool
    ) async throws {}
  }
#endif
