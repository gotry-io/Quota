import Foundation

enum QuotaObservationSource: Equatable, Hashable, Sendable {
  case local
  case device(deviceID: String)

  var stableID: String {
    switch self {
    case .local:
      "local"
    case .device(let deviceID):
      "device:\(Self.component(deviceID))"
    }
  }

  var isLocal: Bool {
    self == .local
  }

  private static func component(_ value: String) -> String {
    "\(value.utf8.count):\(value)"
  }
}

struct QuotaObservation: Equatable, Sendable {
  let snapshot: QuotaSnapshot
  let source: QuotaObservationSource
}

struct QuotaSubscriptionIdentity: Equatable, Hashable, Sendable {
  enum Scope: Equatable, Hashable, Sendable {
    case global
    case source(QuotaObservationSource)
  }

  let provider: ProviderID
  let fingerprint: String
  let scope: Scope
}

struct ResolvedQuotaSubscription: Equatable, Sendable {
  let identity: QuotaSubscriptionIdentity
  let sources: [QuotaObservationSource]
  let selectedSource: QuotaObservationSource
  let selectedSnapshot: QuotaSnapshot
  let isStale: Bool
}
