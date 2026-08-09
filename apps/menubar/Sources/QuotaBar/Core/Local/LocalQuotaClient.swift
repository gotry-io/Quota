import Darwin
import Foundation

enum LocalQuotaClientError: LocalizedError {
  case helperMissing
  case launchFailed
  case invalidOutput
  case outputTooLarge
  case timedOut

  var errorDescription: String? {
    switch self {
    case .helperMissing:
      "The bundled QuotaCLI helper is missing. Reinstall QuotaBar."
    case .launchFailed:
      "QuotaCLI could not collect local provider quota."
    case .invalidOutput:
      "QuotaCLI returned data that QuotaBar could not read."
    case .outputTooLarge:
      "QuotaCLI returned more data than QuotaBar can safely read."
    case .timedOut:
      "QuotaCLI took too long to collect local provider quota."
    }
  }
}

protocol LocalQuotaCollecting: Sendable {
  func collect() async throws -> QuotaCollectionReport
}

protocol RelaySnapshotPushing: Sendable {
  var hasRelayCredential: Bool { get }
  func push() async throws
}

struct LocalQuotaClient: LocalQuotaCollecting, RelaySnapshotPushing {
  private static let defaultTimeout: Duration = .seconds(60)
  private static let defaultMaximumOutputBytes = 1_048_576
  private static let defaultTerminationGracePeriod: Duration = .milliseconds(250)

  private let executableURL: URL
  private let relayCredentialURL: URL
  private let timeout: Duration
  private let maximumOutputBytes: Int
  private let terminationGracePeriod: Duration

  init(
    executableURL: URL? = nil,
    relayCredentialURL: URL? = nil,
    bundle: Bundle = .main,
    timeout: Duration = LocalQuotaClient.defaultTimeout,
    maximumOutputBytes: Int = LocalQuotaClient.defaultMaximumOutputBytes,
    terminationGracePeriod: Duration = LocalQuotaClient.defaultTerminationGracePeriod
  ) throws {
    precondition(timeout > .zero)
    precondition(maximumOutputBytes > 0)
    precondition(terminationGracePeriod >= .zero)

    self.timeout = timeout
    self.maximumOutputBytes = maximumOutputBytes
    self.terminationGracePeriod = terminationGracePeriod
    self.relayCredentialURL = relayCredentialURL ?? Self.defaultRelayCredentialURL()

    if let executableURL {
      self.executableURL = executableURL
      return
    }

    let helperURL = bundle.bundleURL
      .appending(path: "Contents")
      .appending(path: "Helpers")
      .appending(path: "quotacli")
    guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
      throw LocalQuotaClientError.helperMissing
    }
    self.executableURL = helperURL
  }

  var hasRelayCredential: Bool {
    FileManager.default.fileExists(atPath: relayCredentialURL.path)
  }

  func collect() async throws -> QuotaCollectionReport {
    let result = try await run(
      arguments: ["status", "--provider", "all", "--format", "json"],
    )

    guard result.exitedNormally, result.status == 0 || result.status == 1 else {
      throw LocalQuotaClientError.launchFailed
    }

    do {
      let report = try QuotaWireCodec.makeDecoder().decode(
        QuotaCollectionReport.self,
        from: result.standardOutput
      )
      guard report.schemaVersion == 1 else {
        throw LocalQuotaClientError.invalidOutput
      }
      return report
    } catch let error as LocalQuotaClientError {
      throw error
    } catch {
      throw LocalQuotaClientError.invalidOutput
    }
  }

  func push() async throws {
    let result = try await run(arguments: ["relay", "push"])

    guard result.exitedNormally, result.status == 0 || result.status == 1 else {
      throw LocalQuotaClientError.launchFailed
    }
  }

  private static func defaultRelayCredentialURL() -> URL {
    if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
      return URL(fileURLWithPath: xdg, isDirectory: true)
        .appendingPathComponent("quotacli", isDirectory: true)
        .appendingPathComponent("device.json", isDirectory: false)
    }
    return FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent("quotacli", isDirectory: true)
      .appendingPathComponent("device.json", isDirectory: false)
  }

  private func run(arguments: [String]) async throws -> BoundedProcessResult {
    do {
      return try await BoundedProcessExecution(
        executableURL: executableURL,
        arguments: arguments,
        timeout: timeout,
        maximumOutputBytes: maximumOutputBytes,
        terminationGracePeriod: terminationGracePeriod
      ).run()
    } catch BoundedProcessError.timedOut {
      throw LocalQuotaClientError.timedOut
    } catch BoundedProcessError.outputTooLarge {
      throw LocalQuotaClientError.outputTooLarge
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw LocalQuotaClientError.launchFailed
    }
  }
}

private struct BoundedProcessResult: Sendable {
  let standardOutput: Data
  let status: Int32
  let exitedNormally: Bool
}

private enum BoundedProcessError: Error {
  case launchFailed
  case outputTooLarge
  case timedOut
}

private enum BoundedProcessStopReason {
  case cancelled
  case outputTooLarge
  case readFailed
  case timedOut
}

/// Runs one fixed executable without blocking the caller's cooperative executor.
///
/// Completion is delayed until both the process and its stdout pipe have closed. This guarantees
/// that timeout, cancellation, and output-limit failures cannot return while the helper is still
/// running. Mutable state is protected by `lock`; callbacks may arrive from unrelated queues.
private final class BoundedProcessExecution: @unchecked Sendable {
  private let executableURL: URL
  private let arguments: [String]
  private let timeout: Duration
  private let maximumOutputBytes: Int
  private let terminationGracePeriod: Duration

  private let lock = NSLock()
  private let process = Process()
  private let standardOutput = Pipe()

  private var continuation: CheckedContinuation<BoundedProcessResult, any Error>?
  private var output = Data()
  private var stopReason: BoundedProcessStopReason?
  private var processFinished = false
  private var readerFinished = false
  private var launched = false
  private var completed = false
  private var terminationStatus: Int32 = -1
  private var exitedNormally = false
  private var timeoutTask: Task<Void, Never>?
  private var forceKillTask: Task<Void, Never>?

  init(
    executableURL: URL,
    arguments: [String],
    timeout: Duration,
    maximumOutputBytes: Int,
    terminationGracePeriod: Duration
  ) {
    self.executableURL = executableURL
    self.arguments = arguments
    self.timeout = timeout
    self.maximumOutputBytes = maximumOutputBytes
    self.terminationGracePeriod = terminationGracePeriod
  }

  func run() async throws -> BoundedProcessResult {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        start(continuation: continuation)
      }
    } onCancel: {
      requestStop(.cancelled)
    }
  }

  private func start(
    continuation: CheckedContinuation<BoundedProcessResult, any Error>
  ) {
    let wasAlreadyCancelled = lock.withLock {
      self.continuation = continuation
      return stopReason == .cancelled
    }
    guard !wasAlreadyCancelled else {
      finishBeforeLaunch(throwing: CancellationError())
      return
    }

    process.executableURL = executableURL
    process.arguments = arguments
    process.standardOutput = standardOutput
    process.standardError = FileHandle.nullDevice
    installTerminationHandler()

    do {
      try process.run()
    } catch {
      finishBeforeLaunch(throwing: BoundedProcessError.launchFailed)
      return
    }

    let pendingStop = lock.withLock {
      launched = true
      return stopReason
    }

    startTimeout()
    startReadingStandardOutput()

    if pendingStop != nil {
      terminateProcess()
    }
  }

  private func startTimeout() {
    let task = Task.detached { [weak self, timeout] in
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      self?.requestStop(.timedOut)
    }
    lock.withLock {
      timeoutTask = task
    }
  }

  private func startReadingStandardOutput() {
    DispatchQueue.global(qos: .utility).async { [self] in
      var readFailed = false
      do {
        while let chunk = try standardOutput.fileHandleForReading.read(upToCount: 64 * 1024),
          !chunk.isEmpty
        {
          receive(chunk)
        }
      } catch {
        readFailed = true
      }
      readerDidFinish(readFailed: readFailed)
    }
  }

  private func receive(_ chunk: Data) {
    let exceededLimit = lock.withLock {
      guard stopReason == nil else {
        return false
      }
      guard output.count <= maximumOutputBytes - chunk.count else {
        stopReason = .outputTooLarge
        return true
      }
      output.append(chunk)
      return false
    }

    if exceededLimit {
      terminateProcess()
    }
  }

  private func readerDidFinish(readFailed: Bool) {
    let (completion, shouldTerminate) = lock.withLock {
      readerFinished = true
      if readFailed, stopReason == nil {
        stopReason = .readFailed
      }
      return (takeCompletionIfReady(), readFailed && launched && !processFinished)
    }
    if shouldTerminate {
      terminateProcess()
    }
    resume(completion)
  }

  private func installTerminationHandler() {
    process.terminationHandler = { [weak self] process in
      guard let self else { return }
      let completion = lock.withLock {
        processFinished = true
        terminationStatus = process.terminationStatus
        exitedNormally = process.terminationReason == .exit
        return takeCompletionIfReady()
      }
      resume(completion)
    }
  }

  private func requestStop(_ reason: BoundedProcessStopReason) {
    let shouldTerminate = lock.withLock {
      guard !completed else {
        return false
      }
      if stopReason == nil {
        stopReason = reason
      }
      return launched && !processFinished
    }

    if shouldTerminate {
      terminateProcess()
    }
  }

  private func terminateProcess() {
    let processIdentifier = process.processIdentifier
    guard processIdentifier > 0 else {
      return
    }

    Darwin.kill(processIdentifier, SIGTERM)

    let task = Task.detached { [weak self, terminationGracePeriod, processIdentifier] in
      if terminationGracePeriod > .zero {
        do {
          try await Task.sleep(for: terminationGracePeriod)
        } catch {
          return
        }
      }
      guard let self else {
        return
      }
      let stillRunning = self.lock.withLock {
        self.launched && !self.processFinished && !self.completed
      }
      if stillRunning {
        Darwin.kill(processIdentifier, SIGKILL)
      }
    }
    lock.withLock {
      forceKillTask?.cancel()
      forceKillTask = task
    }
  }

  private func finishBeforeLaunch(throwing error: any Error) {
    let completion: (CheckedContinuation<BoundedProcessResult, any Error>, any Error)? =
      lock
      .withLock {
        guard !completed else {
          return nil
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        guard let continuation else {
          return nil
        }
        let resolvedError: any Error =
          if stopReason == .cancelled {
            CancellationError()
          } else {
            error
          }
        return (continuation, resolvedError)
      }
    standardOutput.fileHandleForReading.closeFile()
    standardOutput.fileHandleForWriting.closeFile()
    if let completion {
      completion.0.resume(throwing: completion.1)
    }
  }

  private struct Completion {
    let continuation: CheckedContinuation<BoundedProcessResult, any Error>
    let result: Result<BoundedProcessResult, any Error>
    let timeoutTask: Task<Void, Never>?
    let forceKillTask: Task<Void, Never>?
  }

  private func takeCompletionIfReady() -> Completion? {
    guard processFinished, readerFinished, !completed, let continuation else {
      return nil
    }

    completed = true
    self.continuation = nil
    let result: Result<BoundedProcessResult, any Error>
    switch stopReason {
    case .cancelled:
      result = .failure(CancellationError())
    case .outputTooLarge:
      result = .failure(BoundedProcessError.outputTooLarge)
    case .readFailed:
      result = .failure(BoundedProcessError.launchFailed)
    case .timedOut:
      result = .failure(BoundedProcessError.timedOut)
    case nil:
      result = .success(
        BoundedProcessResult(
          standardOutput: output,
          status: terminationStatus,
          exitedNormally: exitedNormally
        )
      )
    }

    return Completion(
      continuation: continuation,
      result: result,
      timeoutTask: timeoutTask,
      forceKillTask: forceKillTask
    )
  }

  private func resume(_ completion: Completion?) {
    guard let completion else {
      return
    }
    completion.timeoutTask?.cancel()
    completion.forceKillTask?.cancel()
    completion.continuation.resume(with: completion.result)
  }
}
