@preconcurrency import Foundation
import QuotaWire

enum LocalServiceClientError: LocalizedError, Equatable {
  case serviceMissing
  case launchFailed
  case connectionClosed
  case invalidMessage
  case messageTooLarge
  case remote(LocalServiceRemoteError)

  var errorDescription: String? {
    switch self {
    case .serviceMissing:
      "The bundled local service is missing. Reinstall QuotaBar."
    case .launchFailed, .connectionClosed:
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

/// How long the client waits on the helper. Requests themselves are never on a clock: only the
/// helper's own start and its answers to `ping` are.
struct LocalServiceClientTimings: Sendable {
  /// How long one launch has to announce `ready` before that start counts as failed.
  var ready: Duration = .seconds(60)
  /// How long a request may be outstanding before liveness pings begin, and the cadence of the
  /// pings after that.
  var ping: Duration = .seconds(5)
  /// How long a helper asked to exit has before it is killed.
  var termination: Duration = .seconds(2)
}

protocol LocalServiceServing: Sendable {
  var events: AsyncStream<LocalServiceEvent> { get }

  func state() async throws -> LocalServiceState
  func diagnose() async throws -> LocalServiceDiagnosticReport
  func recheckDiagnostics() async throws -> LocalServiceRefreshResult
  func resetCache() async throws
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
  /// The other answer a sign-in attempt can end with: macOS refused the cookie store, so there
  /// is no session to commit and the service records why.
  func reportProviderBrowserAccessDenied(
    _ provider: ProviderID, browserName: String, reason: BrowserAccessDenialReason
  ) async throws -> LocalServiceProviderBrowserSession
  func removeProviderBrowserSession(
    _ provider: ProviderID
  ) async throws -> LocalServiceProviderBrowserSession
  func shutdown() async
}

extension LocalServiceServing {
  func recheckDiagnostics() async throws -> LocalServiceRefreshResult {
    try await refresh()
  }
}

actor LocalServiceClient: LocalServiceServing {
  nonisolated let events: AsyncStream<LocalServiceEvent>

  private static let maximumLineBytes = 1_048_576
  /// Two consecutive pings with no answer. At the default cadence that is ten seconds of silence
  /// from an operation the helper answers without taking a lock, so it is not working: it is gone.
  private static let missedPingLimit = 2

  private let executableURL: URL
  private let timings: LocalServiceClientTimings
  private let eventContinuation: AsyncStream<LocalServiceEvent>.Continuation
  private var process: Process?
  private var standardInput: FileHandle?
  private var readerTask: Task<Void, Never>?
  private var stoppingTask: Task<Void, Never>?
  private var receiveBuffer = Data()
  private var connectionGeneration = 0
  private var pending: [String: CheckedContinuation<Data, any Error>] = [:]
  private var readyWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
  /// Requests whose caller went away while the helper still held them. The helper answers every
  /// request it was handed, so the id outlives the waiter just long enough for that answer to be
  /// dropped rather than read as a reply to a request nobody made — which is a protocol
  /// violation, and would close a connection that is working perfectly well.
  private var cancelledRequests: Set<String> = []
  private var isReady = false
  private var isRetriedStart = false
  private var readyTask: Task<Void, Never>?
  private var livenessTask: Task<Void, Never>?
  private var outstandingPings: Set<String> = []
  private var missedPings = 0

  init(
    executableURL: URL? = nil,
    bundle: Bundle = .main,
    timings: LocalServiceClientTimings = LocalServiceClientTimings()
  ) throws {
    let stream = AsyncStream<LocalServiceEvent>.makeStream()
    events = stream.stream
    eventContinuation = stream.continuation
    self.timings = timings

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

  func recheckDiagnostics() async throws -> LocalServiceRefreshResult {
    try await request(operation: "recheck_diagnostics", payload: EmptyPayload())
  }

  func resetCache() async throws {
    let _: EmptyResult = try await request(operation: "reset_cache", payload: EmptyPayload())
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
      payload: CommitProviderBrowserSessionPayload(
        provider: provider.rawValue, cookieHeader: cookieHeader, accessDenied: nil)
    )
    guard session.isValid, session.configured else { throw LocalServiceClientError.invalidMessage }
    return session
  }

  func reportProviderBrowserAccessDenied(
    _ provider: ProviderID, browserName: String, reason: BrowserAccessDenialReason
  ) async throws -> LocalServiceProviderBrowserSession {
    let session: LocalServiceProviderBrowserSession = try await request(
      operation: "commit_provider_browser_session",
      payload: CommitProviderBrowserSessionPayload(
        provider: provider.rawValue,
        cookieHeader: nil,
        // The browser's display name is all that travels: the store's path stays on this side.
        accessDenied: BrowserAccessDeniedPayload(
          browser: browserName, reason: reason.rawValue)
      )
    )
    guard session.isValid else { throw LocalServiceClientError.invalidMessage }
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
    if isReady, process != nil {
      do {
        let _: EmptyResult = try await request(operation: "shutdown", payload: EmptyPayload())
      } catch {
        // Closing stdin below is the authoritative app-lifetime shutdown signal.
      }
    }
    await close(error: LocalServiceClientError.connectionClosed)
  }

  private func request<Result: Decodable, Payload: Encodable>(
    operation: String,
    payload: Payload
  ) async throws -> Result {
    try await connect()
    let requestID = UUID().uuidString.lowercased()
    let data = try frame(requestID: requestID, operation: operation, payload: payload)
    try write(data)
    let resultData = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Data, any Error>) in
        // This actor cannot deliver the helper's response until the waiter is registered here, so
        // the write above never leaves a continuation behind when it fails.
        guard !Task.isCancelled else {
          cancelledRequests.insert(requestID)
          continuation.resume(throwing: CancellationError())
          return
        }
        pending[requestID] = continuation
        startLivenessMonitor()
      }
    } onCancel: {
      Task { await self.cancelRequest(requestID) }
    }

    do {
      return try QuotaWireCodec.makeDecoder().decode(Result.self, from: resultData)
    } catch {
      throw LocalServiceClientError.invalidMessage
    }
  }

  /// Lets go of a request whose caller was cancelled. The request itself cannot be recalled —
  /// the helper has it — so the waiter is what goes, and the answer is expected and discarded.
  private func cancelRequest(_ requestID: String) {
    guard let continuation = pending.removeValue(forKey: requestID) else { return }
    cancelledRequests.insert(requestID)
    continuation.resume(throwing: CancellationError())
  }

  private func frame<Payload: Encodable>(
    requestID: String,
    operation: String,
    payload: Payload
  ) throws -> Data {
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
    return data
  }

  /// Writes one framed line. A helper that is gone is discovered by its reader hitting end of
  /// file or by an unanswered ping, so a failed write only has to report itself.
  private func write(_ data: Data) throws {
    guard let standardInput else {
      throw LocalServiceClientError.connectionClosed
    }
    do {
      try standardInput.write(contentsOf: data)
    } catch {
      throw LocalServiceClientError.connectionClosed
    }
  }

  /// Makes sure a helper is running and has finished opening its local state. Requests wait here
  /// instead of racing the open, and QuotaBar shows its loading state while they do.
  private func connect() async throws {
    try await startIfNeeded()
    if isReady { return }
    let waiterID = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        guard !Task.isCancelled else {
          continuation.resume(throwing: CancellationError())
          return
        }
        readyWaiters[waiterID] = continuation
      }
    } onCancel: {
      Task { await self.cancelReadyWaiter(waiterID) }
    }
  }

  /// A caller that stopped waiting for the helper to open. Nothing was written on its behalf, so
  /// the waiter is all there is to remove.
  private func cancelReadyWaiter(_ waiterID: UUID) {
    readyWaiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
  }

  private func startIfNeeded() async throws {
    if let stoppingTask {
      await stoppingTask.value
    }
    if let process, !process.isRunning {
      await close(error: LocalServiceClientError.connectionClosed)
    }
    guard process == nil else { return }
    try launch(isRetriedStart: false)
  }

  private func launch(isRetriedStart: Bool) throws {
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
    self.isRetriedStart = isRetriedStart
    isReady = false
    let inputHandle = input.fileHandleForWriting
    // Once the helper exits this pipe has no reader, and a write to it raises SIGPIPE, which
    // terminates the process before `write` can report `EPIPE`. `write` maps that `EPIPE` to
    // `connectionClosed`, so the descriptor has to opt out of the signal for its `catch` to run.
    _ = fcntl(inputHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
    standardInput = inputHandle
    receiveBuffer.removeAll(keepingCapacity: true)
    readerTask = Task.detached(priority: .utility) {
      [weak self, handle = output.fileHandleForReading] in
      let descriptor = handle.fileDescriptor
      var buffer = [UInt8](repeating: 0, count: 65_536)
      while true {
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
          guard let base = raw.baseAddress else { return -1 }
          return Darwin.read(descriptor, base, raw.count)
        }
        if count <= 0 { break }
        await self?.receive(Data(buffer.prefix(count)), generation: generation)
      }
      // The helper's exit is what ends that read, including when it had to be killed. Closing
      // the descriptor here rather than from the actor keeps it from being reused by the next
      // helper's pipes while this thread is still blocked on it.
      try? handle.close()
      await self?.readerClosed(generation: generation)
    }
    armReadyTimeout(generation: generation)
  }

  private func armReadyTimeout(generation: Int) {
    readyTask?.cancel()
    let limit = timings.ready
    readyTask = Task { [weak self] in
      do {
        try await Task.sleep(for: limit)
      } catch {
        return
      }
      await self?.readyTimedOut(generation: generation)
    }
  }

  /// A helper that never announces itself gets one more start. QuotaBar reports the service as
  /// unavailable only after a second silent one.
  private func readyTimedOut(generation: Int) async {
    guard generation == connectionGeneration, !isReady else { return }
    guard !isRetriedStart else {
      await close(error: LocalServiceClientError.launchFailed)
      return
    }
    await close(error: LocalServiceClientError.connectionClosed, keepingReadyWaiters: true)
    // A request that arrived while the silent helper was being stopped may already have started
    // its own; that one owns the connection, and the waiters kept above are waiting on it.
    guard process == nil else { return }
    do {
      try launch(isRetriedStart: true)
    } catch {
      resumeReadyWaiters(throwing: LocalServiceClientError.launchFailed)
    }
  }

  private func markReady() {
    isReady = true
    isRetriedStart = false
    readyTask?.cancel()
    readyTask = nil
    resumeReadyWaiters(throwing: nil)
  }

  private func resumeReadyWaiters(throwing error: (any Error)?) {
    let waiters = Array(readyWaiters.values)
    readyWaiters.removeAll()
    for continuation in waiters {
      if let error {
        continuation.resume(throwing: error)
      } else {
        continuation.resume()
      }
    }
  }

  /// Starts asking whether the helper is alive once a request has been outstanding for one
  /// interval. A helper that keeps answering keeps its request, however long that request takes.
  private func startLivenessMonitor() {
    guard livenessTask == nil else { return }
    let generation = connectionGeneration
    let interval = timings.ping
    livenessTask = Task { [weak self] in
      while true {
        do {
          try await Task.sleep(for: interval)
        } catch {
          return
        }
        guard let self, await self.checkLiveness(generation: generation) else { return }
      }
    }
  }

  /// One liveness round. Returns false when this monitor has nothing left to watch.
  private func checkLiveness(generation: Int) async -> Bool {
    guard generation == connectionGeneration else { return false }
    guard !pending.isEmpty else {
      livenessTask = nil
      outstandingPings.removeAll()
      missedPings = 0
      return false
    }
    if !outstandingPings.isEmpty {
      missedPings += 1
      if missedPings >= Self.missedPingLimit {
        await close(error: LocalServiceClientError.connectionClosed)
        return false
      }
    }
    sendPing()
    return true
  }

  private func sendPing() {
    let requestID = UUID().uuidString.lowercased()
    guard
      let data = try? frame(requestID: requestID, operation: "ping", payload: EmptyPayload())
    else { return }
    outstandingPings.insert(requestID)
    try? write(data)
  }

  private func receive(_ chunk: Data, generation: Int) async {
    guard generation == connectionGeneration else { return }
    receiveBuffer.append(chunk)

    while let newline = receiveBuffer.firstIndex(of: 0x0A) {
      let line = Data(receiveBuffer[..<newline])
      receiveBuffer.removeSubrange(...newline)
      guard !line.isEmpty, line.count <= Self.maximumLineBytes else {
        await closeFromReader(error: LocalServiceClientError.invalidMessage)
        return
      }
      do {
        try receiveLine(line)
      } catch {
        await closeFromReader(error: LocalServiceClientError.invalidMessage)
        return
      }
    }

    guard receiveBuffer.count <= Self.maximumLineBytes else {
      await closeFromReader(error: LocalServiceClientError.messageTooLarge)
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
      guard let requestID = object["request_id"] as? String else {
        throw LocalServiceClientError.invalidMessage
      }
      // A ping only has to come back. Whether the helper answered it with a result or an error
      // is not what liveness asked.
      if outstandingPings.remove(requestID) != nil {
        missedPings = 0
        return
      }
      // A request whose caller was cancelled is still answered, because the helper was already
      // holding it. That answer is expected and has nowhere to go.
      if cancelledRequests.remove(requestID) != nil { return }
      guard pending[requestID] != nil else {
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
      guard let name = object["event"] as? String else {
        throw LocalServiceClientError.invalidMessage
      }
      if name == "ready" {
        guard
          Set(object.keys) == ["type", "event", "ipc_version"],
          object["ipc_version"] as? Int == LocalServiceState.supportedIPCVersion,
          !isReady
        else {
          throw LocalServiceClientError.invalidMessage
        }
        markReady()
        return
      }
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

  private func readerClosed(generation: Int) async {
    guard generation == connectionGeneration else { return }
    await closeFromReader(error: LocalServiceClientError.connectionClosed)
  }

  /// Ends the connection and reports `error` to everyone waiting on it. The helper is stopped
  /// first, so the next request cannot start a second one while this one is still dying.
  private func close(error: any Error, keepingReadyWaiters: Bool = false) async {
    await finish(
      detach(keepingReadyWaiters: keepingReadyWaiters),
      error: error,
      waitingForReader: true
    )
  }

  /// The same, from inside the reader task, which therefore must not be waited for.
  private func closeFromReader(error: any Error) async {
    await finish(detach(), error: error, waitingForReader: false)
  }

  /// What one connection leaves behind once nothing on the actor can reach it any more.
  private struct ClosedConnection {
    let process: Process?
    let reader: Task<Void, Never>?
    let pending: [CheckedContinuation<Data, any Error>]
    let readyWaiters: [CheckedContinuation<Void, any Error>]
  }

  private func detach(keepingReadyWaiters: Bool = false) -> ClosedConnection {
    connectionGeneration += 1
    isReady = false
    readyTask?.cancel()
    readyTask = nil
    livenessTask?.cancel()
    livenessTask = nil
    outstandingPings.removeAll()
    // Nothing this connection was still expected to answer can arrive over the next one.
    cancelledRequests.removeAll()
    missedPings = 0
    receiveBuffer.removeAll(keepingCapacity: false)
    try? standardInput?.close()
    standardInput = nil
    let closed = ClosedConnection(
      process: process,
      reader: readerTask,
      pending: Array(pending.values),
      readyWaiters: keepingReadyWaiters ? [] : Array(readyWaiters.values)
    )
    process = nil
    readerTask = nil
    pending.removeAll()
    if !keepingReadyWaiters {
      readyWaiters.removeAll()
    }
    return closed
  }

  private func finish(
    _ closed: ClosedConnection,
    error: any Error,
    waitingForReader: Bool
  ) async {
    if let process = closed.process {
      let grace = timings.termination
      let stopping = Task { await Self.stop(process, after: grace) }
      stoppingTask = stopping
      await stopping.value
      if stoppingTask == stopping {
        stoppingTask = nil
      }
    }
    // The exit above closed the helper's end of the pipe, which is what ends the reader's
    // blocking read. Waiting for it here proves no thread is left on that descriptor — but only
    // a helper that really is gone can end it, so a survivor is never waited for.
    if waitingForReader, closed.process?.isRunning != true {
      await closed.reader?.value
    }
    for continuation in closed.pending {
      continuation.resume(throwing: error)
    }
    for continuation in closed.readyWaiters {
      continuation.resume(throwing: error)
    }
  }

  /// Asks the helper to exit, insists if it will not, and waits for it to be reaped. Running off
  /// the actor's task keeps the grace period intact even when the caller was cancelled on its way
  /// here.
  private nonisolated static func stop(_ process: Process, after grace: Duration) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.global(qos: .userInitiated).async {
        if process.isRunning {
          process.terminate()
          waitForExit(of: process, upTo: grace)
        }
        if process.isRunning {
          kill(process.processIdentifier, SIGKILL)
          waitForExit(of: process, upTo: grace)
        }
        continuation.resume()
      }
    }
  }

  /// `Process.waitUntilExit` runs the calling thread's run loop, and a dispatch worker's run loop
  /// never receives the child's termination, so it can block for the process lifetime. Foundation
  /// reaps the child on its own thread, so observing that is both correct and bounded.
  private nonisolated static func waitForExit(of process: Process, upTo limit: Duration) {
    let deadline = Date().addingTimeInterval(limit.timeInterval)
    while process.isRunning, Date() < deadline {
      usleep(5_000)
    }
  }
}

extension Duration {
  fileprivate var timeInterval: TimeInterval {
    TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
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

/// One sign-in attempt's answer: the session a browser released, or the reason it released
/// nothing. Exactly one of the two is present, and the service refuses a payload that names
/// both or neither.
private struct CommitProviderBrowserSessionPayload: Encodable {
  let provider: String
  let cookieHeader: String?
  let accessDenied: BrowserAccessDeniedPayload?
}

private struct BrowserAccessDeniedPayload: Encodable {
  let browser: String
  let reason: String
}
