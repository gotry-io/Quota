import Foundation
import QuotaWire

enum QuotaObservationSource: Equatable, Hashable, Sendable {
  case local
  case device(deviceID: String)
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
