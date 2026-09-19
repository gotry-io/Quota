import Foundation
import QuotaAccount
import QuotaPresentation
import QuotaProviderSessions
import QuotaRelay
import QuotaWire

#if DEBUG
final class FixtureActivityLoader: ActivityLoading, @unchecked Sendable {
  let days: [UsageActivityDay]
  let populatedAgents: [UsageAgentUsage]
  let usage: AccountUsage
  let now: Date

  init(
    days: [UsageActivityDay],
    populatedAgents: [UsageAgentUsage],
    usage: AccountUsage,
    now: Date
  ) {
    self.days = days
    self.populatedAgents = populatedAgents
    self.usage = usage
    self.now = now
  }

  func fetchUsageActivity(
    from: String,
    to: String,
    detail: ActivityDetail?,
    timeZone: String?
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
      return .activity(
        AccountUsageActivityResponse(
          days: [day],
          hoursOfDay: detail == .hours ? hours : nil,
          weekdayHours: detail == .hours ? weekdayHours : nil
        )
      )
    }
    return .activity(
      AccountUsageActivityResponse(
        days: days,
        hoursOfDay: detail == .hours ? hours : nil,
        weekdayHours: detail == .hours ? weekdayHours : nil
      )
    )
  }

  func fetchUsagePeriod(
    from: String,
    to: String,
    timezone: String,
    breakdown: Bool
  ) async -> AccountPeriodResult {
    await MainActor.run {
      let calendar = Calendar.current
      let period: UsagePeriod
      if let range = UsagePeriodSelection.today.range(today: now, calendar: calendar),
        range.from == from, range.to == to
      {
        period = usage.today
      } else if let range = UsagePeriodSelection.last7Days.range(today: now, calendar: calendar),
        range.from == from, range.to == to
      {
        period = usage.last7Days
      } else if let range = UsagePeriodSelection.last30Days.range(
        today: now, calendar: calendar),
        range.from == from, range.to == to
      {
        period = usage.last30Days
      } else {
        period = VisualFixtureContent.periodUsage(fromDays: days, from: from, to: to)
      }
      let response = VisualFixtureContent.accountPeriodResponse(
        from: from,
        to: to,
        timezone: timezone,
        usage: period,
        days: days
      )
      if breakdown { return .period(response) }
      return .period(
        AccountUsagePeriodResponse(
          request: response.request,
          bounds: response.bounds,
          totals: response.totals,
          cost: response.cost,
          cacheSaved: response.cacheSaved,
          days: response.days,
          agents: nil,
          coverage: response.coverage,
          revision: response.revision
        )
      )
    }
  }

  private var hours: [QuotaWire.UsageHourOfDay] {
    let weights = [0, 0, 0, 0, 0, 1, 3, 6, 9, 12, 14, 13, 8, 11, 15, 13, 10, 7, 5, 4, 3, 2, 1, 0]
    let sum = weights.reduce(0, +)
    let total = days.reduce(0) { $0 + $1.totals.totalTokens }
    return weights.enumerated().map { hour, weight in
      QuotaWire.UsageHourOfDay(hour: hour, totalTokens: sum > 0 ? total * weight / sum : 0, costMicrousd: nil)
    }
  }

  private var weekdayHours: [[Int]] {
    let weights = [0.15, 1.0, 1.1, 1.05, 0.95, 0.55, 0.2]
    return weights.map { weight in
      hours.map { Int(Double($0.totalTokens) * weight) }
    }
  }
}

/// Transport that fails if any network call is attempted during a visual fixture session.
final class FixtureBlockedHTTPTransport: HTTPTransport, @unchecked Sendable {
  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    throw HTTPTransportError.unavailable
  }
}

@MainActor
final class FixtureBlockedAuthenticator: BrowserSessionAuthenticating {
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

#endif
