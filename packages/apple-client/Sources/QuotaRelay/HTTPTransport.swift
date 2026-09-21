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

    let data: Data
    do {
      data = try await BoundedHTTPBody.collect(
        bytes, maximum: maximumResponseBytes, expected: contentLength(http))
    } catch BoundedHTTPBody.Overflow.tooLarge {
      throw HTTPTransportError.responseTooLarge
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

/// Bounded body from `URLSession.bytes`. Kept instead of `data(for:)` so a body over the cap
/// is cancelled while it arrives. `AsyncBytes` is still `UInt8`; we restore `reserveCapacity`
/// from Content-Length and append in 16 KiB batches so the buffer is not grown a byte at a time.
enum BoundedHTTPBody {
  static let chunkSize = 16 * 1024

  enum Overflow: Error {
    case tooLarge
  }

  static func collect(
    _ bytes: URLSession.AsyncBytes, maximum: Int, expected: Int? = nil
  ) async throws -> Data {
    var data = Data()
    if let expected, expected > 0 {
      data.reserveCapacity(min(expected, maximum))
    }
    var chunk = [UInt8]()
    chunk.reserveCapacity(min(chunkSize, maximum))
    for try await byte in bytes {
      chunk.append(byte)
      if chunk.count >= chunkSize {
        data.append(contentsOf: chunk)
        chunk.removeAll(keepingCapacity: true)
        if data.count > maximum {
          bytes.task.cancel()
          throw Overflow.tooLarge
        }
      }
    }
    if !chunk.isEmpty {
      data.append(contentsOf: chunk)
    }
    if data.count > maximum {
      bytes.task.cancel()
      throw Overflow.tooLarge
    }
    return data
  }
}
