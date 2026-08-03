import Foundation

struct RelayHTTPResponse: Sendable {
  let statusCode: Int
  let body: Data
}

enum RelayHTTPTransportError: Error, Equatable, Sendable {
  case invalidResponse
  case responseTooLarge
}

protocol RelayHTTPTransport: Sendable {
  func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> RelayHTTPResponse
}

struct URLSessionRelayHTTPTransport: RelayHTTPTransport {
  private let session: URLSession

  init(session: URLSession = URLSession(configuration: .ephemeral)) {
    self.session = session
  }

  func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> RelayHTTPResponse {
    let delegate = RelayNoRedirectDelegate()
    let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
    guard let response = response as? HTTPURLResponse else {
      throw RelayHTTPTransportError.invalidResponse
    }
    if response.expectedContentLength > maximumResponseBytes {
      throw RelayHTTPTransportError.responseTooLarge
    }

    var data = Data()
    data.reserveCapacity(
      max(0, min(Int(response.expectedContentLength), maximumResponseBytes))
    )
    for try await byte in bytes {
      guard data.count < maximumResponseBytes else {
        throw RelayHTTPTransportError.responseTooLarge
      }
      data.append(byte)
    }
    return RelayHTTPResponse(statusCode: response.statusCode, body: data)
  }
}

private final class RelayNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
