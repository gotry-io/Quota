import QuotaAccount
import QuotaRelay

/// The activity and period reads Usage asks for. Implementations keep the answer in memory;
/// nothing here writes a disk cache. Period 304/ETag lives on `AccountClient`.
protocol ActivityLoading: Sendable {
  func fetchUsageActivity(
    from: String,
    to: String,
    detail: ActivityDetail?,
    timeZone: String?
  ) async -> AccountActivityResult

  func fetchUsagePeriod(
    from: String,
    to: String,
    timezone: String,
    breakdown: Bool,
    modelSeries: Bool
  ) async -> AccountPeriodResult
}

struct AccountClientActivityLoading: ActivityLoading {
  let client: AccountClient

  func fetchUsageActivity(
    from: String,
    to: String,
    detail: ActivityDetail?,
    timeZone: String?
  ) async -> AccountActivityResult {
    await client.fetchUsageActivity(from: from, to: to, detail: detail, timeZone: timeZone)
  }

  func fetchUsagePeriod(
    from: String,
    to: String,
    timezone: String,
    breakdown: Bool,
    modelSeries: Bool
  ) async -> AccountPeriodResult {
    await client.fetchUsagePeriod(
      from: from,
      to: to,
      timezone: timezone,
      breakdown: breakdown,
      modelSeries: modelSeries
    )
  }
}
