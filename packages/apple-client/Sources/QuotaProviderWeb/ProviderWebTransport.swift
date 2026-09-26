import Foundation
import os

/// One HTTP exchange, with the response body already bounded.
public struct ProviderWebResponse: Equatable, Sendable {
  public let status: Int
  public let body: Data
  /// The `Retry-After` header as sent, when there was one. Only a 429 reads it.
  public let retryAfter: String?

  public init(status: Int, body: Data, retryAfter: String? = nil) {
    self.status = status
    self.body = body
    self.retryAfter = retryAfter
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

/// A body the session refused to finish reading because it crossed the cap.
/// `ProviderWebHTTP` maps this to `.error`, the one category an over-limit body has.
enum ProviderWebTransportError: Error, Equatable, Sendable {
  case bodyTooLarge
}

/// `URLSession` with the rules a cookie request needs: no redirect is followed, no cookie store
/// of the process is consulted or written, and a body larger than the limit is refused rather
/// than buffered. The cap is counted while bytes arrive; the task is cancelled as soon as it is
/// crossed, and a declared length over the limit is refused without reading.
public final class URLSessionProviderWebTransport: ProviderWebTransport, @unchecked Sendable {
  private let session: URLSession
  private let delegate: BodyBoundDelegate

  public convenience init() {
    self.init(configuration: .ephemeral)
  }

  init(
    configuration: URLSessionConfiguration,
    bodyLimit: Int = ProviderWebLimits.bodyLimit
  ) {
    let configuration = configuration.copy() as! URLSessionConfiguration
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let delegate = BodyBoundDelegate(bodyLimit: bodyLimit)
    self.delegate = delegate
    session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
  }

  deinit {
    session.invalidateAndCancel()
  }

  public func send(_ request: URLRequest) async throws -> ProviderWebResponse {
    try await delegate.send(request, on: session)
  }
}

/// Per-task running count so a large body is cancelled while it arrives, not after
/// `URLSession` has already assembled it.
private final class BodyBoundDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private struct Receive {
    let continuation: CheckedContinuation<ProviderWebResponse, Error>
    let bodyLimit: Int
    var data = Data()
    var status: Int?
    var retryAfter: String?
    var settled = false
  }

  private let bodyLimit: Int
  private let lock = OSAllocatedUnfairLock<[Int: Receive]>(initialState: [:])

  init(bodyLimit: Int) {
    self.bodyLimit = bodyLimit
  }

  func send(_ request: URLRequest, on session: URLSession) async throws -> ProviderWebResponse {
    let task = session.dataTask(with: request)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.withLock { state in
          state[task.taskIdentifier] = Receive(
            continuation: continuation, bodyLimit: bodyLimit)
        }
        task.resume()
        if Task.isCancelled {
          task.cancel()
        }
      }
    } onCancel: {
      task.cancel()
    }
  }

  /// A redirect is never followed: the cookie is scoped to the host it was signed in at, and a
  /// hop this library cannot see is a hop that could spend it somewhere else. The 3xx is handed
  /// back instead, and the caller reads it the way the service does.
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    guard let http = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      settle(dataTask, .failure(URLError(.badServerResponse)))
      return
    }
    if (300..<400).contains(http.statusCode) {
      completionHandler(.cancel)
      settle(dataTask, .success(ProviderWebResponse(status: http.statusCode, body: Data())))
      return
    }
    if exceedsBodyLimit(http) {
      completionHandler(.cancel)
      settle(dataTask, .failure(ProviderWebTransportError.bodyTooLarge))
      return
    }
    lock.withLock { state in
      if var receive = state[dataTask.taskIdentifier] {
        receive.status = http.statusCode
        receive.retryAfter = http.value(forHTTPHeaderField: "Retry-After")
        let expected = http.expectedContentLength
        if expected > 0 {
          receive.data.reserveCapacity(min(Int(expected), receive.bodyLimit))
        }
        state[dataTask.taskIdentifier] = receive
      }
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let overLimit = lock.withLock { state -> Bool in
      let id = dataTask.taskIdentifier
      guard state[id]?.settled == false else { return false }
      state[id]!.data.append(data)
      return state[id]!.data.count > state[id]!.bodyLimit
    }
    if overLimit {
      dataTask.cancel()
      settle(dataTask, .failure(ProviderWebTransportError.bodyTooLarge))
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    if let error {
      settle(task, .failure(error))
      return
    }
    let response = lock.withLock { state -> ProviderWebResponse? in
      guard let receive = state[task.taskIdentifier], !receive.settled,
        let status = receive.status
      else { return nil }
      return ProviderWebResponse(
        status: status, body: receive.data, retryAfter: receive.retryAfter)
    }
    if let response {
      settle(task, .success(response))
    }
  }

  private func settle(_ task: URLSessionTask, _ result: Result<ProviderWebResponse, Error>) {
    let continuation = lock.withLock { state -> CheckedContinuation<ProviderWebResponse, Error>? in
      guard var receive = state[task.taskIdentifier], !receive.settled else { return nil }
      receive.settled = true
      state[task.taskIdentifier] = receive
      return receive.continuation
    }
    guard let continuation else { return }
    continuation.resume(with: result)
    lock.withLock { state in
      state.removeValue(forKey: task.taskIdentifier)
      return
    }
  }

  private func exceedsBodyLimit(_ response: HTTPURLResponse) -> Bool {
    if let length = declaredLength(response), length > Int64(bodyLimit) {
      return true
    }
    return false
  }

  private func declaredLength(_ response: HTTPURLResponse) -> Int64? {
    if response.expectedContentLength >= 0 {
      return response.expectedContentLength
    }
    if let value = response.value(forHTTPHeaderField: "Content-Length"),
      let length = Int64(value)
    {
      return length
    }
    switch response.allHeaderFields["Content-Length"] {
    case let value as String:
      return Int64(value)
    case let value as Int:
      return Int64(value)
    case let value as Int64:
      return value
    case let value as NSNumber:
      return value.int64Value
    default:
      return nil
    }
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
    } catch ProviderWebTransportError.bodyTooLarge {
      throw ProviderWebError(.error, source)
    } catch {
      throw ProviderWebError(.unavailable, source)
    }
    if (300..<400).contains(response.status) {
      throw ProviderWebError(redirect, source)
    }
    guard (200..<300).contains(response.status) else {
      throw ProviderWebError(
        Self.category(of: response.status),
        source,
        rateLimit: response.status == 429
          ? ProviderRateLimit(retryAfterSeconds: Self.retryAfterSeconds(response.retryAfter))
          : nil
      )
    }
    return response.body
  }

  /// `Retry-After` in delta-seconds, the form the providers send. An HTTP-date, a negative value,
  /// or anything else is no number at all, and the backoff falls back to its own schedule.
  static func retryAfterSeconds(_ value: String?) -> Int? {
    guard let value, let seconds = Int(value.trimmingCharacters(in: .whitespaces)), seconds >= 0
    else { return nil }
    return seconds
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
