import Foundation
import QuotaAccount
import QuotaRelay
import QuotaWire

/// Launch-argument visual fixtures for deterministic simulator screenshots.
/// Parser is always available for unit tests; UI state application is DEBUG-only.
enum VisualFixture: String, CaseIterable, Sendable {
  case signedOut = "signed-out"
  case content
  case cachedError = "cached-error"
  case empty

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
      case .content:
        model.phase = .signedIn
        model.summary = VisualFixtureContent.summary(at: now)
        model.fetchedAt = now.addingTimeInterval(-90)
        model.fromCache = false
        model.isRefreshing = false
        model.banner = nil
        model.expiredMessage = nil
      case .cachedError:
        model.phase = .signedIn
        model.summary = VisualFixtureContent.summary(at: now)
        model.fetchedAt = now.addingTimeInterval(-180)
        model.fromCache = true
        model.isRefreshing = false
        model.banner = AppModel.Banner(
          kind: .offlineCached,
          text: "Showing saved account data. Could not refresh.",
          symbolName: "icloud.slash"
        )
        model.expiredMessage = nil
      case .empty:
        model.phase = .signedIn
        model.summary = VisualFixtureContent.emptySummary(at: now)
        model.fetchedAt = now.addingTimeInterval(-60)
        model.fromCache = false
        model.isRefreshing = false
        model.banner = nil
        model.expiredMessage = nil
      }
    }
  }

  @MainActor
  enum VisualFixtureContent {
    static func summary(at date: Date) -> AccountSummary {
      let deviceID = "device_visual_fixture_01"
      let observations = [
        observation(
          provider: .codex,
          deviceID: deviceID,
          fingerprint: "visual_codex",
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
          observedAt: date.addingTimeInterval(-90),
        ),
        observation(
          provider: .claude,
          deviceID: deviceID,
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
          observedAt: date.addingTimeInterval(-120),
        ),
        observation(
          provider: .grok,
          deviceID: deviceID,
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
            deviceID: deviceID,
            displayName: "Studio Mac",
            platform: .macos,
            deviceGeneration: 3,
            status: .active,
            createdAt: date.addingTimeInterval(-30 * 86_400),
            lastLoginAt: date.addingTimeInterval(-5 * 86_400),
            lastSeenAt: date.addingTimeInterval(-45),
            signedOutAt: nil
          )
        ],
        quota: observations,
        usage: usageSummary(at: date)
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
        quota: [],
        usage: emptyUsageSummary(at: date)
      )
    }

    private static func usageSummary(at date: Date) -> AccountUsageSummary {
      let day = calendarDay(date)
      return AccountUsageSummary(
        range: UsageDateRange(from: day, to: day),
        totals: UsageTokenTotals(
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
        ),
        cost: UsageCostOutcome(
          mode: .calculate,
          basis: .calculated,
          status: .complete,
          amountMicrousd: "1489234",
          catalogRevision: "pricing_visual_fixture",
          calculatedRows: 164,
          reportedRows: 0,
          unpricedRows: 0,
          assumptions: [.agentDefaultChannel],
          unpriced: []
        ),
        coverage: .complete,
        breakdowns: []
      )
    }

    private static func emptyUsageSummary(at date: Date) -> AccountUsageSummary {
      let day = calendarDay(date)
      return AccountUsageSummary(
        range: UsageDateRange(from: day, to: day),
        totals: UsageTokenTotals(
          inputTokens: 0,
          cacheReadTokens: 0,
          cacheWrite5mTokens: 0,
          cacheWrite1hTokens: 0,
          cacheWriteInferredTokens: 0,
          outputTokens: 0,
          reasoningTokens: 0,
          requests: 0,
          webSearchRequests: 0,
          webFetchRequests: 0,
          sourceCostMicrousd: nil,
          sourceCostCoveredRequests: 0
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
        coverage: .complete,
        breakdowns: []
      )
    }

    private static func observation(
      provider: ProviderID,
      deviceID: String,
      fingerprint: String,
      label: String?,
      plan: String?,
      windows: [QuotaWindow],
      observedAt: Date
    ) -> AccountQuotaObservation {
      AccountQuotaObservation(
        deviceID: deviceID,
        snapshot: QuotaSnapshot(
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

    private static func calendarDay(_ date: Date) -> String {
      let formatter = DateFormatter()
      formatter.calendar = Calendar(identifier: .iso8601)
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "yyyy-MM-dd"
      return formatter.string(from: date)
    }
  }

  extension AppModel {
    /// Build a model preloaded with a visual fixture. Does not touch network or Keychain.
    /// Pass an explicit `now` (e.g. `VisualFixture.referenceDate` in tests, `Date()` at launch).
    static func visualFixture(
      _ fixture: VisualFixture,
      now: Date
    ) -> AppModel {
      let model = AppModel(
        account: AccountClient(
          relay: RelayClient(transport: FixtureBlockedHTTPTransport()),
          sessionStore: MemoryAccountSessionStore(),
          summaryStore: MemoryAccountSummaryStore(),
          now: { now }
        ),
        authenticator: FixtureBlockedAuthenticator(),
        widgetPublisher: NoOpWidgetSnapshotPublisher()
      )
      fixture.apply(to: model, now: now)
      return model
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
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
      throw AuthorizationError.cancelled
    }
  }
#endif
