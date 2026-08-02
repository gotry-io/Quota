import Foundation

enum RelayClientError: Error {
  case invalidResponse
  case unsupportedProtocol
}

actor RelayClient {
  private let session: URLSession

  init(session: URLSession = .shared) {
    self.session = session
  }

  func discover(baseURL: URL) async throws -> RelayInfo {
    let discoveryURL = baseURL.appending(path: ".well-known/quotabar-relay")
    let (data, response) = try await session.data(from: discoveryURL)

    guard let httpResponse = response as? HTTPURLResponse,
      httpResponse.statusCode == 200
    else {
      throw RelayClientError.invalidResponse
    }

    let relayInfo = try QuotaWireCodec.makeDecoder().decode(RelayInfo.self, from: data)
    guard relayInfo.apiVersions.contains(1), relayInfo.capabilities.persistentSnapshots else {
      throw RelayClientError.unsupportedProtocol
    }

    return relayInfo
  }
}
