import Foundation
import QuotaAccount
import QuotaAlerts
import QuotaRelay
import QuotaWire
import Testing

@testable import Quota

@MainActor
final class UsageHarness {
  var signedIn = true
  var epoch = 0
  var sessionExpired = 0
  var notSignedIn = 0

  func model(
    loader: any ActivityLoading,
    budgetStore: UsageBudgetStore = UsageBudgetStore(),
    now: @escaping @Sendable () -> Date = { activityNow() }
  ) -> UsageModel {
    let usage = UsageModel(activity: loader, budgetStore: budgetStore, now: now)
    usage.isSignedIn = { [weak self] in self?.signedIn ?? false }
    usage.sessionEpoch = { [weak self] in self?.epoch ?? 0 }
    usage.onSessionExpired = { [weak self] in self?.sessionExpired += 1 }
    usage.onNotSignedIn = { [weak self] in self?.notSignedIn += 1 }
    return usage
  }
}

@MainActor
func makeActivityAppModel(
  loader: any ActivityLoading,
  session: Bool,
  now: @escaping @Sendable () -> Date = { activityNow() }
) -> AppModel {
  AppModel(
    account: AccountClient(
      relay: RelayClient(transport: EmptyHTTPTransport()),
      sessionStore: MemoryAccountSessionStore(
        session: session ? activitySession() : nil
      ),
      summaryStore: MemoryAccountSummaryStore(),
      now: now
    ),
    authenticator: CancelledAuthenticator(),
    activity: loader,
    now: now
  )
}

func activityNow() -> Date {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.date(from: "2026-08-14T16:00:00Z")!
}

func activitySession() -> AccountSession {
  AccountSession(
    accountID: "account_01",
    accessToken: "qia_synthetic_access_token",
    accessExpiresAt: activityNow(),
    refreshToken: "qiar_synthetic_refresh_token",
    refreshExpiresAt: activityNow().addingTimeInterval(8_000_000),
    activation: .active
  )
}

func emptyDay(_ date: String) -> UsageActivityDay {
  UsageActivityChart.emptyDay(date: date)
}

func rhythmResponse(tokensAtHour: Int) -> AccountUsageActivityResponse {
  AccountUsageActivityResponse(
    days: [],
    hoursOfDay: (0..<24).map { hour in
      UsageHourOfDay(
        hour: hour,
        totalTokens: hour == tokensAtHour ? 12 : 0,
        costMicrousd: nil
      )
    },
    weekdayHours: Array(repeating: Array(repeating: 0, count: 24), count: 7)
  )
}

final class TestClock: @unchecked Sendable {
  var now: Date
  init(_ now: Date) { self.now = now }
}

func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async {
  for _ in 0..<2_000 {
    if await condition() { return }
    try? await Task.sleep(for: .milliseconds(2))
  }
  Issue.record("timed out waiting")
}

actor GatedActivityLoader: ActivityLoading {
  struct Call: Equatable, Sendable {
    var from: String
    var to: String
    var detail: ActivityDetail?
    var timeZone: String?
  }

  struct PeriodCall: Equatable, Sendable {
    var from: String
    var to: String
    var timezone: String
    var breakdown: Bool
  }

  private var results: [AccountActivityResult]
  private var periodResults: [AccountPeriodResult]
  private(set) var calls: [Call] = []
  private(set) var periodCalls: [PeriodCall] = []
  private var permits = 0
  private var waiting: [CheckedContinuation<Void, Never>] = []

  init(
    results: [AccountActivityResult],
    periodResults: [AccountPeriodResult] = []
  ) {
    self.results = results
    self.periodResults = periodResults
  }

  func release() {
    if !waiting.isEmpty {
      waiting.removeFirst().resume()
    } else {
      permits += 1
    }
  }

  func fetchUsageActivity(
    from: String,
    to: String,
    detail: ActivityDetail?,
    timeZone: String?
  ) async -> AccountActivityResult {
    calls.append(Call(from: from, to: to, detail: detail, timeZone: timeZone))
    if permits > 0 {
      permits -= 1
    } else {
      await withCheckedContinuation { continuation in
        waiting.append(continuation)
      }
    }
    return results.isEmpty ? .failure(.relay(.unavailable)) : results.removeFirst()
  }

  func fetchUsagePeriod(
    from: String,
    to: String,
    timezone: String,
    breakdown: Bool
  ) async -> AccountPeriodResult {
    periodCalls.append(
      PeriodCall(from: from, to: to, timezone: timezone, breakdown: breakdown))
    if permits > 0 {
      permits -= 1
    } else {
      await withCheckedContinuation { continuation in
        waiting.append(continuation)
      }
    }
    return periodResults.isEmpty
      ? .failure(.relay(.unavailable)) : periodResults.removeFirst()
  }
}

actor ScriptedActivityLoader: ActivityLoading {
  struct Call: Equatable, Sendable {
    var from: String
    var to: String
    var detail: ActivityDetail?
    var timeZone: String?
  }

  struct PeriodCall: Equatable, Sendable {
    var from: String
    var to: String
    var timezone: String
    var breakdown: Bool
  }

  private var results: [AccountActivityResult]
  private var periodResults: [AccountPeriodResult]
  private(set) var calls: [Call] = []
  private(set) var periodCalls: [PeriodCall] = []

  init(
    results: [AccountActivityResult],
    periodResults: [AccountPeriodResult] = []
  ) {
    self.results = results
    self.periodResults = periodResults
  }

  func fetchUsageActivity(
    from: String,
    to: String,
    detail: ActivityDetail?,
    timeZone: String?
  ) async -> AccountActivityResult {
    calls.append(Call(from: from, to: to, detail: detail, timeZone: timeZone))
    return results.isEmpty ? .failure(.relay(.unavailable)) : results.removeFirst()
  }

  func fetchUsagePeriod(
    from: String,
    to: String,
    timezone: String,
    breakdown: Bool
  ) async -> AccountPeriodResult {
    periodCalls.append(
      PeriodCall(from: from, to: to, timezone: timezone, breakdown: breakdown))
    return periodResults.isEmpty
      ? .failure(.relay(.unavailable)) : periodResults.removeFirst()
  }
}

final class EmptyHTTPTransport: HTTPTransport, @unchecked Sendable {
  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    throw HTTPTransportError.unavailable
  }
}

@MainActor
final class CancelledAuthenticator: BrowserSessionAuthenticating {
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

  func cancelPresentation() {}
}
