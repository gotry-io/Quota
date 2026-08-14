@preconcurrency import Foundation

enum LocalServiceClientError: LocalizedError, Equatable {
  case serviceMissing
  case launchFailed
  case connectionClosed
  case requestTimedOut
  case invalidMessage
  case messageTooLarge
  case remote(LocalServiceRemoteError)

  var errorDescription: String? {
    switch self {
    case .serviceMissing:
      "The bundled local service is missing. Reinstall QuotaBar."
    case .launchFailed, .connectionClosed, .requestTimedOut:
      "QuotaBar's local service is unavailable."
    case .invalidMessage, .messageTooLarge:
      "QuotaBar's local service returned invalid data. Reinstall or update QuotaBar."
    case .remote(let error):
      switch error.code {
      case .deviceDeleted:
        "This device was removed. Sign in again to reconnect it."
      case .staleGeneration, .authenticationRequired:
        "The account session ended. Sign in again to continue syncing."
      default:
        switch error.recoveryAction {
        case .login:
          "Sign in to continue."
        case .configureProvider:
          "Configure this provider to continue."
        case .upgrade:
          "Update QuotaBar to continue."
        case .reinstall:
          "Reinstall QuotaBar to repair its local service."
        case .retry:
          "The request could not be completed. Try again."
        case .none:
          "The request could not be completed."
        }
      }
    }
  }
}

protocol LocalServiceServing: Sendable {
  var events: AsyncStream<LocalServiceEvent> { get }

  func state() async throws -> LocalServiceState
  func diagnose() async throws -> LocalServiceDiagnosticReport
  func refresh() async throws -> LocalServiceRefreshResult
  func login() async throws -> LocalServiceLoginResult
  func cancelLogin() async throws
  func logout() async throws -> LocalServiceLogoutResult
  func setUsageUpload(enabled: Bool) async throws -> LocalServiceUsageUploadSetting
  func setProviderConfig(
    _ provider: ProviderID,
    apiKey: String,
    baseURL: String?
  ) async throws -> LocalServiceProviderConfig
  func removeProviderConfig(_ provider: ProviderID) async throws -> LocalServiceProviderConfig
  func validateProviderBrowserSession(
    _ provider: ProviderID, cookieHeader: String
  ) async throws -> LocalServiceProviderBrowserSessionCandidate
  func commitProviderBrowserSession(
    _ provider: ProviderID, cookieHeader: String
  ) async throws -> LocalServiceProviderBrowserSession
  func removeProviderBrowserSession(
    _ provider: ProviderID
  ) async throws -> LocalServiceProviderBrowserSession
  func shutdown() async
}

actor LocalServiceClient: LocalServiceServing {
  nonisolated let events: AsyncStream<LocalServiceEvent>

  private static let maximumLineBytes = 1_048_576
  private static let defaultRequestTimeoutNanoseconds: UInt64 = 15_000_000_000

  private let executableURL: URL
  private let requestTimeoutNanoseconds: UInt64
  private let eventContinuation: AsyncStream<LocalServiceEvent>.Continuation
  private var process: Process?
  private var standardInput: FileHandle?
  private var standardOutput: FileHandle?
  private var readerTask: Task<Void, Never>?
  private var receiveBuffer = Data()
  private var connectionGeneration = 0
  private var pending: [String: CheckedContinuation<Data, any Error>] = [:]

  init(
    executableURL: URL? = nil,
    bundle: Bundle = .main,
    requestTimeoutNanoseconds: UInt64 = LocalServiceClient.defaultRequestTimeoutNanoseconds
  ) throws {
    let stream = AsyncStream<LocalServiceEvent>.makeStream()
    events = stream.stream
    eventContinuation = stream.continuation
    self.requestTimeoutNanoseconds = requestTimeoutNanoseconds

    if let executableURL {
      self.executableURL = executableURL
      return
    }

    let serviceURL = bundle.bundleURL
      .appending(path: "Contents")
      .appending(path: "Helpers")
      .appending(path: "quota-service")
    guard FileManager.default.isExecutableFile(atPath: serviceURL.path) else {
      throw LocalServiceClientError.serviceMissing
    }
    self.executableURL = serviceURL
  }

  deinit {
    eventContinuation.finish()
    readerTask?.cancel()
    try? standardInput?.close()
    try? standardOutput?.close()
    if process?.isRunning == true {
      process?.terminate()
    }
  }

  func state() async throws -> LocalServiceState {
    let state: LocalServiceState = try await request(
      operation: "get_state", payload: EmptyPayload())
    guard state.isValid else {
      throw LocalServiceClientError.invalidMessage
    }
    return state
  }

  func diagnose() async throws -> LocalServiceDiagnosticReport {
    let report: LocalServiceDiagnosticReport = try await request(
      operation: "diagnose", payload: EmptyPayload())
    guard report.isValid else {
      throw LocalServiceClientError.invalidMessage
    }
    return report
  }

  func refresh() async throws -> LocalServiceRefreshResult {
    try await request(operation: "refresh", payload: EmptyPayload())
  }

  func login() async throws -> LocalServiceLoginResult {
    try await request(operation: "login", payload: EmptyPayload())
  }

  func cancelLogin() async throws {
    let _: LocalServiceLoginResult = try await request(
      operation: "cancel_login",
      payload: EmptyPayload()
    )
  }

  func logout() async throws -> LocalServiceLogoutResult {
    try await request(operation: "logout", payload: EmptyPayload())
  }

  func setUsageUpload(enabled: Bool) async throws -> LocalServiceUsageUploadSetting {
    try await request(
      operation: "set_usage_upload",
      payload: SetUsageUploadPayload(enabled: enabled)
    )
  }

  func setProviderConfig(
    _ provider: ProviderID,
    apiKey: String,
    baseURL: String?
  ) async throws -> LocalServiceProviderConfig {
    try await request(
      operation: "set_provider_config",
      payload: SetProviderConfigPayload(
        provider: provider.rawValue,
        apiKey: apiKey,
        baseURL: baseURL
      )
    )
  }

  func removeProviderConfig(_ provider: ProviderID) async throws -> LocalServiceProviderConfig {
    try await request(
      operation: "remove_provider_config",
      payload: ProviderPayload(provider: provider.rawValue)
    )
  }

  func validateProviderBrowserSession(
    _ provider: ProviderID, cookieHeader: String
  ) async throws -> LocalServiceProviderBrowserSessionCandidate {
    let candidate: LocalServiceProviderBrowserSessionCandidate = try await request(
      operation: "validate_provider_browser_session",
      payload: ProviderBrowserSessionPayload(provider: provider.rawValue, cookieHeader: cookieHeader)
    )
    guard candidate.isValid else { throw LocalServiceClientError.invalidMessage }
    return candidate
  }

  func commitProviderBrowserSession(
    _ provider: ProviderID, cookieHeader: String
  ) async throws -> LocalServiceProviderBrowserSession {
    let session: LocalServiceProviderBrowserSession = try await request(
      operation: "commit_provider_browser_session",
      payload: ProviderBrowserSessionPayload(provider: provider.rawValue, cookieHeader: cookieHeader)
    )
    guard session.isValid, session.configured else { throw LocalServiceClientError.invalidMessage }
    return session
  }

  func removeProviderBrowserSession(
    _ provider: ProviderID
  ) async throws -> LocalServiceProviderBrowserSession {
    let session: LocalServiceProviderBrowserSession = try await request(
      operation: "remove_provider_browser_session",
      payload: ProviderPayload(provider: provider.rawValue)
    )
    guard session.isValid, !session.configured else { throw LocalServiceClientError.invalidMessage }
    return session
  }

  func shutdown() async {
    do {
      let _: EmptyResult = try await request(operation: "shutdown", payload: EmptyPayload())
    } catch {
      // Closing stdin below is the authoritative app-lifetime shutdown signal.
    }
    closeConnection(terminate: true, error: LocalServiceClientError.connectionClosed)
  }

  private func request<Result: Decodable, Payload: Encodable>(
    operation: String,
    payload: Payload
  ) async throws -> Result {
    try startIfNeeded()
    let requestID = UUID().uuidString.lowercased()
    let message = RequestEnvelope(
      type: "request",
      requestID: requestID,
      operation: operation,
      payload: payload
    )
    var data = try QuotaWireCodec.makeEncoder().encode(message)
    guard data.count <= Self.maximumLineBytes else {
      throw LocalServiceClientError.messageTooLarge
    }
    data.append(0x0A)

    let timeoutNanoseconds = requestTimeoutNanoseconds
    let timeoutTask = Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: timeoutNanoseconds)
      } catch {
        return
      }
      await self?.expire(requestID: requestID)
    }
    defer { timeoutTask.cancel() }

    guard let standardInput else {
      closeConnection(terminate: true, error: LocalServiceClientError.connectionClosed)
      throw LocalServiceClientError.connectionClosed
    }
    do {
      // This actor cannot receive the helper response until the waiter is registered below and
      // request suspends, so a failed write never creates a continuation to clean up.
      try standardInput.write(contentsOf: data)
    } catch {
      closeConnection(terminate: true, error: LocalServiceClientError.connectionClosed)
      throw LocalServiceClientError.connectionClosed
    }
    let resultData = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Data, any Error>) in
      pending[requestID] = continuation
    }

    do {
      return try QuotaWireCodec.makeDecoder().decode(Result.self, from: resultData)
    } catch {
      throw LocalServiceClientError.invalidMessage
    }
  }

  private func startIfNeeded() throws {
    if process?.isRunning == true { return }

    let process = Process()
    let input = Pipe()
    let output = Pipe()
    process.executableURL = executableURL
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      throw LocalServiceClientError.launchFailed
    }

    connectionGeneration += 1
    let generation = connectionGeneration
    self.process = process
    standardInput = input.fileHandleForWriting
    let outputHandle = output.fileHandleForReading
    standardOutput = outputHandle
    receiveBuffer.removeAll(keepingCapacity: true)
    readerTask = Task.detached(priority: .utility) {
      [weak self, handle = outputHandle] in
      let descriptor = handle.fileDescriptor
      var buffer = [UInt8](repeating: 0, count: 65_536)
      while !Task.isCancelled {
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
          guard let base = raw.baseAddress else { return -1 }
          return Darwin.read(descriptor, base, raw.count)
        }
        if count <= 0 { break }
        await self?.receive(Data(buffer.prefix(count)), generation: generation)
      }
      await self?.readerClosed(generation: generation)
    }
  }

  private func receive(_ chunk: Data, generation: Int) {
    guard generation == connectionGeneration else { return }
    receiveBuffer.append(chunk)

    while let newline = receiveBuffer.firstIndex(of: 0x0A) {
      let line = Data(receiveBuffer[..<newline])
      receiveBuffer.removeSubrange(...newline)
      guard !line.isEmpty, line.count <= Self.maximumLineBytes else {
        closeConnection(terminate: true, error: LocalServiceClientError.invalidMessage)
        return
      }
      do {
        try receiveLine(line)
      } catch {
        closeConnection(terminate: true, error: LocalServiceClientError.invalidMessage)
        return
      }
    }

    guard receiveBuffer.count <= Self.maximumLineBytes else {
      closeConnection(terminate: true, error: LocalServiceClientError.messageTooLarge)
      return
    }
  }

  private func receiveLine(_ line: Data) throws {
    guard
      let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
      let type = object["type"] as? String
    else {
      throw LocalServiceClientError.invalidMessage
    }

    switch type {
    case "response":
      let keys = Set(object.keys)
      guard
        keys == ["type", "request_id", "result"]
          || keys == ["type", "request_id", "error"]
      else {
        throw LocalServiceClientError.invalidMessage
      }
      // Old-process replies are filtered by connectionGeneration. An unknown ID in the active
      // generation therefore violates the private protocol; fail closed and wake every waiter.
      guard let requestID = object["request_id"] as? String, pending[requestID] != nil else {
        throw LocalServiceClientError.invalidMessage
      }
      let response: Result<Data, any Error>
      if let errorObject = object["error"] {
        let errorData = try JSONSerialization.data(withJSONObject: errorObject)
        let remoteError = try QuotaWireCodec.makeDecoder().decode(
          LocalServiceRemoteError.self,
          from: errorData
        )
        response = .failure(LocalServiceClientError.remote(remoteError))
      } else if let resultObject = object["result"] {
        response = .success(try JSONSerialization.data(withJSONObject: resultObject))
      } else {
        throw LocalServiceClientError.invalidMessage
      }
      guard let continuation = pending.removeValue(forKey: requestID) else {
        throw LocalServiceClientError.invalidMessage
      }
      switch response {
      case .success(let data):
        continuation.resume(returning: data)
      case .failure(let error):
        continuation.resume(throwing: error)
      }
    case "event":
      guard Set(object.keys) == ["type", "event", "revision", "changed_components"] else {
        throw LocalServiceClientError.invalidMessage
      }
      let event = try QuotaWireCodec.makeDecoder().decode(LocalServiceEvent.self, from: line)
      guard event.event == "state_changed", event.revision >= 0,
        !event.changedComponents.isEmpty,
        Set(event.changedComponents.map(\.rawValue)).count == event.changedComponents.count
      else {
        throw LocalServiceClientError.invalidMessage
      }
      eventContinuation.yield(event)
    default:
      throw LocalServiceClientError.invalidMessage
    }
  }

  private func readerClosed(generation: Int) {
    guard generation == connectionGeneration else { return }
    closeConnection(terminate: false, error: LocalServiceClientError.connectionClosed)
  }

  private func expire(requestID: String) {
    guard pending[requestID] != nil else { return }
    closeConnection(terminate: true, error: LocalServiceClientError.requestTimedOut)
  }

  private func closeConnection(terminate: Bool, error: any Error) {
    connectionGeneration += 1
    readerTask?.cancel()
    readerTask = nil
    try? standardInput?.close()
    try? standardOutput?.close()
    standardInput = nil
    standardOutput = nil
    receiveBuffer.removeAll(keepingCapacity: false)
    if terminate, process?.isRunning == true {
      process?.terminate()
    }
    process = nil
    let continuations = pending.values
    pending.removeAll()
    for continuation in continuations {
      continuation.resume(throwing: error)
    }
  }
}

private struct RequestEnvelope<Payload: Encodable>: Encodable {
  let type: String
  let requestID: String
  let operation: String
  let payload: Payload
}

private struct EmptyPayload: Encodable {}
private struct EmptyResult: Decodable {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([])
  }
}
private struct ProviderPayload: Encodable { let provider: String }
private struct SetUsageUploadPayload: Encodable { let enabled: Bool }
private struct SetProviderConfigPayload: Encodable {
  let provider: String
  let apiKey: String
  let baseURL: String?
}
private struct ProviderBrowserSessionPayload: Encodable {
  let provider: String
  let cookieHeader: String
}
