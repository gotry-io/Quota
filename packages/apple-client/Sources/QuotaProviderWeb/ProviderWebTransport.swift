import Foundation

/// One HTTP exchange, with the response body already bounded.
public struct ProviderWebResponse: Equatable, Sendable {
  public let status: Int
  public let body: Data

  public init(status: Int, body: Data) {
    self.status = status
    self.body = body
  }
}

/// The one way this library reaches a provider. Injected so a test answers with a canned
/// exchange instead of the network, and so the app decides which `URLSession` is spent.
public protocol ProviderWebTransport: Sendable {
  func send(_ request: URLRequest) async throws -> ProviderWebResponse
}

public enum ProviderWebLimits {
  /// The same bounds the Rust collectors use, so neither device gives up on a provider the
  /// other would have waited for.
  public static let requestTimeout: TimeInterval = 20
  public static let validationTimeout: TimeInterval = 10
  public static let bodyLimit = 1_048_576
}

/// `URLSession` with the rules a cookie request needs: no redirect is followed, no cookie store
/// of the process is consulted or written, and a body larger than the limit is refused rather
/// than buffered.
public final class URLSessionProviderWebTransport: NSObject, ProviderWebTransport,
  URLSessionTaskDelegate, @unchecked Sendable
{
  private let session: URLSession

  public override init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    session = URLSession(configuration: configuration)
    super.init()
  }

  public func send(_ request: URLRequest) async throws -> ProviderWebResponse {
    let (data, response) = try await session.data(for: request, delegate: self)
    guard let http = response as? HTTPURLResponse else {
      throw URLError(.badServerResponse)
    }
    return ProviderWebResponse(status: http.statusCode, body: data)
  }

  /// A redirect is never followed: the cookie is scoped to the host it was signed in at, and a
  /// hop this library cannot see is a hop that could spend it somewhere else. The 3xx is handed
  /// back instead, and the caller reads it the way the service does.
  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

/// The request shapes both collectors and the shared rules that classify what comes back.
struct ProviderWebHTTP: Sendable {
  let transport: any ProviderWebTransport
  let userAgent: String

  /// A GET whose credential is the session itself, so a redirect means the session was not
  /// accepted rather than the host being unreachable.
  func getJSONSession(
    _ url: URL,
    headers: [(String, String)],
    timeout: TimeInterval,
    source: String
  ) async throws -> JSONValue {
    let body = try await send(
      url, method: "GET", body: nil, headers: headers, timeout: timeout,
      redirect: .authRequired, source: source)
    return json(body)
  }

  func getJSON(
    _ url: URL,
    headers: [(String, String)],
    timeout: TimeInterval,
    source: String
  ) async throws -> JSONValue {
    let body = try await send(
      url, method: "GET", body: nil, headers: headers, timeout: timeout,
      redirect: .unavailable, source: source)
    return json(body)
  }

  func postBytes(
    _ url: URL,
    headers: [(String, String)],
    body: Data,
    timeout: TimeInterval,
    source: String
  ) async throws -> Data {
    try await send(
      url, method: "POST", body: body, headers: headers, timeout: timeout,
      redirect: .authRequired, source: source)
  }

  /// A body this library cannot read is read as `null`, the way `serde_json` does for the
  /// service, so a provider that answers HTML with a 200 is a mapping failure and not a crash.
  private func json(_ body: Data) -> JSONValue {
    JSONValue(data: body) ?? .null
  }

  private func send(
    _ url: URL,
    method: String,
    body: Data?,
    headers: [(String, String)],
    timeout: TimeInterval,
    redirect: ProviderWebErrorCategory,
    source: String
  ) async throws -> Data {
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.httpMethod = method
    request.httpBody = body
    request.httpShouldHandleCookies = false
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
    let response: ProviderWebResponse
    do {
      response = try await transport.send(request)
    } catch {
      throw ProviderWebError(.unavailable, source)
    }
    if (300..<400).contains(response.status) {
      throw ProviderWebError(redirect, source)
    }
    if response.body.count > ProviderWebLimits.bodyLimit {
      throw ProviderWebError(.error, source)
    }
    guard (200..<300).contains(response.status) else {
      throw ProviderWebError(Self.category(of: response.status), source)
    }
    return response.body
  }

  /// The service's `http_category`, restated here because this is its own trust boundary.
  static func category(of status: Int) -> ProviderWebErrorCategory {
    switch status {
    case 401, 403: .authRequired
    case 404, 501: .unsupported
    case 408, 429, 500...599: .unavailable
    default: .error
    }
  }
}
