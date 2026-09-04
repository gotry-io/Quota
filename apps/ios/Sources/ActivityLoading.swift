import QuotaAccount
import QuotaRelay

/// The one activity read Usage asks for. Implementations keep the answer in memory; nothing here
/// writes a disk cache.
protocol ActivityLoading: Sendable {
  func fetchUsageActivity(
    from: String,
    to: String,
    detail: ActivityDetail?
  ) async -> AccountActivityResult
}

struct AccountClientActivityLoading: ActivityLoading {
  let client: AccountClient

  func fetchUsageActivity(
    from: String,
    to: String,
    detail: ActivityDetail?
  ) async -> AccountActivityResult {
    await client.fetchUsageActivity(from: from, to: to, detail: detail)
  }
}
