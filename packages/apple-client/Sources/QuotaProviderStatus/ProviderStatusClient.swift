import Foundation
import QuotaPresentation
import QuotaWire

public struct ProviderStatusReading: Sendable, Equatable {
  public var provider: ProviderID
  public var indicator: ProviderServiceStatusIndicator
  public var description: String
  public var checkedAt: Date

  public init(
    provider: ProviderID,
    indicator: ProviderServiceStatusIndicator,
    description: String,
    checkedAt: Date
  ) {
    self.provider = provider
    self.indicator = indicator
    self.description = description
    self.checkedAt = checkedAt
  }
}

public protocol ProviderStatusServing: Sendable {
  func refresh() async -> [ProviderStatusReading]
}

public struct IdleProviderStatusClient: ProviderStatusServing {
  public init() {}

  public func refresh() async -> [ProviderStatusReading] {
    []
  }
}

public protocol ProviderStatusTransport: Sendable {
  func getJSON(url: URL, userAgent: String) async throws -> Data
}

public enum ProviderStatusTransportError: Error, Sendable, Equatable {
  case timeout
  case redirectRefused
  case responseTooLarge
  case unavailable
}

/// Foundation-only Statuspage v2 client. Failures keep the last reading.
public actor ProviderStatusClient: ProviderStatusServing {
  public static let timeout: TimeInterval = 10
  public static let maximumResponseBytes = 64 * 1024

  private let transport: any ProviderStatusTransport
  private let userAgent: String
  private let now: @Sendable () -> Date
  private var lastGood: [ProviderID: ProviderStatusReading] = [:]

  public init(
    transport: (any ProviderStatusTransport)? = nil,
    userAgent: String = ProviderStatusClient.defaultUserAgent,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.transport = transport ?? URLSessionProviderStatusTransport()
    self.userAgent = userAgent
    self.now = now
  }

  public static var defaultUserAgent: String {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    return "Quota/\(version)"
  }

  public func refresh() async -> [ProviderStatusReading] {
    let checkedAt = now()
    for (provider, url) in ProviderStatusPages.endpoints {
      do {
        let data = try await transport.getJSON(url: url, userAgent: userAgent)
        if let reading = Self.parse(data, provider: provider, checkedAt: checkedAt) {
          lastGood[provider] = reading
        }
      } catch {
        continue
      }
    }
    return ProviderID.allCases.compactMap { lastGood[$0] }
  }

  public static func parse(
    _ data: Data,
    provider: ProviderID,
    checkedAt: Date
  ) -> ProviderStatusReading? {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let status = object["status"] as? [String: Any],
      let indicatorRaw = status["indicator"] as? String,
      let indicator = ProviderServiceStatusIndicator(rawValue: indicatorRaw),
      let description = status["description"] as? String
    else {
      return nil
    }
    return ProviderStatusReading(
      provider: provider,
      indicator: indicator,
      description: description,
      checkedAt: checkedAt
    )
  }
}

final class URLSessionProviderStatusTransport: ProviderStatusTransport, @unchecked Sendable {
  private let session: URLSession
  private let delegate: RedirectRefusingDelegate

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = ProviderStatusClient.timeout
    configuration.timeoutIntervalForResource = ProviderStatusClient.timeout
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    let delegate = RedirectRefusingDelegate()
    self.delegate = delegate
    self.session = URLSession(
      configuration: configuration, delegate: delegate, delegateQueue: nil)
  }

  deinit {
    session.invalidateAndCancel()
  }

  func getJSON(url: URL, userAgent: String) async throws -> Data {
    var request = URLRequest(url: url)
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    do {
      let (bytes, response) = try await session.bytes(for: request)
      guard let http = response as? HTTPURLResponse else {
        throw ProviderStatusTransportError.unavailable
      }
      if (300...399).contains(http.statusCode) {
        bytes.task.cancel()
        throw ProviderStatusTransportError.redirectRefused
      }
      if let length = contentLength(http), length > ProviderStatusClient.maximumResponseBytes {
        bytes.task.cancel()
        throw ProviderStatusTransportError.responseTooLarge
      }
      var data = Data()
      for try await byte in bytes {
        data.append(byte)
        if data.count > ProviderStatusClient.maximumResponseBytes {
          bytes.task.cancel()
          throw ProviderStatusTransportError.responseTooLarge
        }
      }
      guard (200..<300).contains(http.statusCode) else {
        throw ProviderStatusTransportError.unavailable
      }
      return data
    } catch let error as ProviderStatusTransportError {
      throw error
    } catch let error as URLError where error.code == .timedOut {
      throw ProviderStatusTransportError.timeout
    } catch {
      throw ProviderStatusTransportError.unavailable
    }
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
