import Foundation
import QuotaProviderStatus
import QuotaRelay

struct RelayProviderStatusCatalog: ProviderStatusCatalogFetching {
  let relay: RelayClient

  func fetchReadings() async throws -> [ProviderStatusReading] {
    let response = try await relay.fetchProviderStatus()
    return response.providers.map {
      ProviderStatusReading(
        provider: $0.id,
        indicator: $0.indicator,
        description: $0.description,
        checkedAt: $0.checkedAt
      )
    }
  }
}
