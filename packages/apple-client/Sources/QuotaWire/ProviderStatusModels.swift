import Foundation
import QuotaPresentation

/// One row of public `GET /api/v2/providers/status` ([ADR 0044](../../../../docs/decisions/0044-relay-publishes-provider-status.md)).
public struct ProviderStatusEntry: Equatable, Sendable {
  public var id: ProviderID
  public var indicator: ProviderServiceStatusIndicator
  public var description: String
  public var checkedAt: Date

  public init(
    id: ProviderID,
    indicator: ProviderServiceStatusIndicator,
    description: String,
    checkedAt: Date
  ) {
    self.id = id
    self.indicator = indicator
    self.description = description
    self.checkedAt = checkedAt
  }
}

/// `{ providers: [{ id, indicator, description, checked_at }] }`. `unknown` indicators are dropped
/// rather than failing the whole body: that row is a failed poll, not a refused catalog.
public struct ProviderStatusResponse: Equatable, Sendable {
  public var providers: [ProviderStatusEntry]

  public init(providers: [ProviderStatusEntry]) {
    self.providers = providers
  }
}

extension ProviderStatusResponse: Decodable {
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let raw = try container.decode([RawEntry].self, forKey: .providers)
    providers = raw.compactMap(\.entry)
  }

  private enum CodingKeys: String, CodingKey {
    case providers
  }

  private struct RawEntry: Decodable {
    var id: ProviderID
    var indicator: String
    var description: String
    var checkedAt: Date

    var entry: ProviderStatusEntry? {
      guard let indicator = ProviderServiceStatusIndicator(rawValue: indicator) else {
        return nil
      }
      return ProviderStatusEntry(
        id: id,
        indicator: indicator,
        description: description,
        checkedAt: checkedAt
      )
    }
  }
}
