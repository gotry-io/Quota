import Darwin
import Foundation
import Testing

@testable import QuotaBar

@Suite(.serialized)
struct LocalQuotaClientTests {
  @Test(arguments: [Int32(0), Int32(1)])
  func relayPushAcceptsDocumentedExitCodes(exitCode: Int32) async throws {
    let helper = try TemporaryHelper(
      body: """
        test "$1" = relay
        test "$2" = push
        exit \(exitCode)
        """
    )
    defer { helper.remove() }
    let client = try LocalQuotaClient(executableURL: helper.url, timeout: .seconds(2))

    try await client.push()
  }

  @Test
  func relayPushRejectsUnexpectedExitCodes() async throws {
    let helper = try TemporaryHelper(body: "exit 2")
    defer { helper.remove() }
    let client = try LocalQuotaClient(executableURL: helper.url, timeout: .seconds(2))

    do {
      try await client.push()
      Issue.record("Expected an unsupported helper exit code to fail.")
    } catch LocalQuotaClientError.launchFailed {
      // Expected.
    }
  }

  @Test(arguments: [Int32(0), Int32(1)])
  func acceptsDocumentedExitCodes(exitCode: Int32) async throws {
    let helper = try TemporaryHelper(
      body: """
        printf '%s' '{"schema_version":1,"captured_at":"2026-08-02T01:00:00Z","results":[]}'
        exit \(exitCode)
        """
    )
    defer { helper.remove() }
    let client = try LocalQuotaClient(executableURL: helper.url, timeout: .seconds(2))

    let report = try await client.collect()

    #expect(report.schemaVersion == 1)
    #expect(report.results.isEmpty)
  }

  @Test
  func rejectsOtherExitCodes() async throws {
    let helper = try TemporaryHelper(
      body: """
        printf '%s' '{"schema_version":1,"captured_at":"2026-08-02T01:00:00Z","results":[]}'
        exit 2
        """
    )
    defer { helper.remove() }
    let client = try LocalQuotaClient(executableURL: helper.url, timeout: .seconds(2))

    do {
      _ = try await client.collect()
      Issue.record("Expected an unsupported helper exit code to fail.")
    } catch LocalQuotaClientError.launchFailed {
      // Expected.
    }
  }

  @Test
  func capsStandardOutput() async throws {
    let helper = try TemporaryHelper(
      body: """
        /usr/bin/yes x | /usr/bin/head -c 1048577
        """
    )
    defer { helper.remove() }
    let client = try LocalQuotaClient(
      executableURL: helper.url,
      timeout: .seconds(2),
      terminationGracePeriod: .milliseconds(50)
    )

    do {
      _ = try await client.collect()
      Issue.record("Expected oversized stdout to fail.")
    } catch LocalQuotaClientError.outputTooLarge {
      // Expected.
    }
  }

  @Test
  func timesOutAndForceKillsAnUncooperativeHelper() async throws {
    let helper = try TemporaryHelper { pidFileURL in
      """
      echo $$ > '\(TemporaryHelper.shellEscaped(pidFileURL.path))'
      trap '' TERM
      while :; do :; done
      """
    }
    defer { helper.remove() }
    let client = try LocalQuotaClient(
      executableURL: helper.url,
      timeout: .seconds(2),
      terminationGracePeriod: .milliseconds(50)
    )
    let task = Task {
      try await client.collect()
    }
    let processIdentifier = try await helper.waitForProcessIdentifier()

    do {
      _ = try await task.value
      Issue.record("Expected the helper to time out.")
    } catch LocalQuotaClientError.timedOut {
      // Expected.
    }

    let signalResult = Darwin.kill(processIdentifier, 0)
    let signalError = errno
    #expect(signalResult == -1)
    #expect(signalError == ESRCH)
  }

  @Test
  func cancellingCollectionTerminatesTheHelperAndPreservesCancellation() async throws {
    let helper = try TemporaryHelper { pidFileURL in
      """
      echo $$ > '\(TemporaryHelper.shellEscaped(pidFileURL.path))'
      trap '' TERM
      while :; do :; done
      """
    }
    defer { helper.remove() }
    let client = try LocalQuotaClient(
      executableURL: helper.url,
      timeout: .seconds(5),
      terminationGracePeriod: .milliseconds(50)
    )
    let task = Task {
      try await client.collect()
    }

    let processIdentifier = try await helper.waitForProcessIdentifier()
    task.cancel()

    do {
      _ = try await task.value
      Issue.record("Expected collection cancellation to propagate.")
    } catch is CancellationError {
      // Expected.
    }

    let signalResult = Darwin.kill(processIdentifier, 0)
    let signalError = errno
    #expect(signalResult == -1)
    #expect(signalError == ESRCH)
  }
}

private struct TemporaryHelper {
  let directoryURL: URL
  let url: URL
  let pidFileURL: URL

  init(body: String) throws {
    try self.init { _ in body }
  }

  init(body: (URL) -> String) throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appending(path: "QuotaBarTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    url = directoryURL.appending(path: "helper")
    pidFileURL = directoryURL.appending(path: "pid")

    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    try Data("#!/bin/sh\n\(body(pidFileURL))\n".utf8).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }

  func waitForProcessIdentifier() async throws -> Int32 {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(3))
    while clock.now < deadline {
      do {
        let contents = try String(contentsOf: pidFileURL, encoding: .utf8)
        if contents.hasSuffix("\n") {
          let processIdentifier = contents.trimmingCharacters(in: .whitespacesAndNewlines)
          if !processIdentifier.isEmpty {
            return try #require(Int32(processIdentifier))
          }
        }
      } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        // The helper has not created the file yet.
      }
      try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The helper did not write its process identifier.")
    throw CancellationError()
  }

  static func shellEscaped(_ value: String) -> String {
    value.replacingOccurrences(of: "'", with: "'\\''")
  }
}
