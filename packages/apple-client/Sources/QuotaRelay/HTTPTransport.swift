import Foundation
import QuotaWire

public protocol HTTPTransport: Sendable {
  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public enum HTTPTransportError: Error, Sendable, Equatable {
  case timeout
  case redirectRefused
  case responseTooLarge
  case unavailable
}

final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

public final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
  private let session: URLSession
  private let delegate: RedirectRefusingDelegate
  private let maximumResponseBytes: Int

  public convenience init(timeout: TimeInterval = 20) {
    self.init(configuration: .ephemeral, timeout: timeout)
  }

  public init(
    configuration: URLSessionConfiguration,
    timeout: TimeInterval = 20,
    maximumResponseBytes: Int = WireCodec.maximumResponseBytes
  ) {
    let configuration = configuration.copy() as! URLSessionConfiguration
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    configuration.httpMaximumConnectionsPerHost = 4
    let delegate = RedirectRefusingDelegate()
    self.delegate = delegate
    self.maximumResponseBytes = maximumResponseBytes
    self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
  }

  deinit {
    session.invalidateAndCancel()
  }

  public func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    do {
      return try await receiveBoundedResponse(for: request)
    } catch let error as HTTPTransportError {
      throw error
    } catch let error as URLError where error.code == .timedOut {
      throw HTTPTransportError.timeout
    } catch let error as URLError {
      if error.code == .httpTooManyRedirects {
        throw HTTPTransportError.redirectRefused
      }
      throw HTTPTransportError.unavailable
    } catch {
      throw HTTPTransportError.unavailable
    }
  }

  private func receiveBoundedResponse(for request: URLRequest) async throws -> (
    Data, HTTPURLResponse
  ) {
    let (bytes, response) = try await session.bytes(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw HTTPTransportError.unavailable
    }
    if (300...399).contains(http.statusCode) {
      bytes.task.cancel()
      throw HTTPTransportError.redirectRefused
    }
    if let expected = contentLength(http), expected > maximumResponseBytes {
      bytes.task.cancel()
      throw HTTPTransportError.responseTooLarge
    }

    var data = Data()
    if let expected = contentLength(http), expected > 0 {
      data.reserveCapacity(min(expected, maximumResponseBytes))
    }
    for try await byte in bytes {
      data.append(byte)
      if data.count > maximumResponseBytes {
        bytes.task.cancel()
        throw HTTPTransportError.responseTooLarge
      }
    }
    return (data, http)
  }

  private func contentLength(_ response: HTTPURLResponse) -> Int? {
    guard let value = response.value(forHTTPHeaderField: "Content-Length"),
      let length = Int(value)
    else {
      return nil
    }
    return length
  }
}
