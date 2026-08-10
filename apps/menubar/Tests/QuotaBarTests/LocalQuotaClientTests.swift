import Darwin
import Foundation
import Testing

@testable import QuotaBar

@Suite(.serialized)
struct LocalQuotaClientTests {
  @Test
  func invokesOnlyTheFourFixedJSONCommands() async throws {
    let helper = try TemporaryHelper(
      body: """
        case "$1" in
          sync)
            test "$2" = --format && test "$3" = json && test -z "$4" || exit 2
            printf '%s' '\(signedOutSyncJSON)'
            ;;
          login)
            test "$2" = --format && test "$3" = json && test -z "$4" || exit 2
            printf '%s' '\(signedInAuthJSON)'
            ;;
          logout)
            test "$2" = --format && test "$3" = json && test -z "$4" || exit 2
            printf '%s' '\(signedOutAuthJSON)'
            ;;
          account)
            test "$2" = summary && test "$3" = --format && test "$4" = json && test -z "$5" || exit 2
            printf '%s' '\(accountSummaryJSON)'
            ;;
          *) exit 2 ;;
        esac
        """
    )
    defer { helper.remove() }
    let client = try LocalQuotaClient(
      executableURL: helper.url,
      commandTimeout: .seconds(2),
      loginTimeout: .seconds(2)
    )

    #expect(try await client.sync().status == .signedOut)
    #expect(try await client.login().status == .signedIn)
    #expect(try await client.logout().status == .signedOut)
    #expect(try await client.accountSummary().protocolVersion == 2)
  }

  @Test(arguments: [Int32(0), Int32(1)])
  func syncAcceptsDocumentedJSONExitCodes(exitCode: Int32) async throws {
    let helper = try TemporaryHelper(
      body: """
        printf '%s' '\(signedOutSyncJSON)'
        exit \(exitCode)
        """
    )
    defer { helper.remove() }
    let client = try LocalQuotaClient(executableURL: helper.url, commandTimeout: .seconds(2))

    #expect(try await client.sync().localReport.schemaVersion == 2)
  }

  @Test
  func rejectsUnexpectedExitCodesAndInvalidJSON() async throws {
    let failedHelper = try TemporaryHelper(body: "exit 2")
    defer { failedHelper.remove() }
    let failedClient = try LocalQuotaClient(
      executableURL: failedHelper.url,
      commandTimeout: .seconds(2)
    )
    await #expect(throws: LocalQuotaClientError.commandFailed) {
      _ = try await failedClient.sync()
    }

    let invalidHelper = try TemporaryHelper(body: "printf '%s' '{}'")
    defer { invalidHelper.remove() }
    let invalidClient = try LocalQuotaClient(
      executableURL: invalidHelper.url,
      commandTimeout: .seconds(2)
    )
    await #expect(throws: LocalQuotaClientError.invalidOutput) {
      _ = try await invalidClient.sync()
    }
  }

  @Test
  func capsStandardOutput() async throws {
    let helper = try TemporaryHelper(body: "/usr/bin/yes x | /usr/bin/head -c 1048577")
    defer { helper.remove() }
    let client = try LocalQuotaClient(
      executableURL: helper.url,
      commandTimeout: .seconds(2),
      terminationGracePeriod: .milliseconds(50)
    )

    await #expect(throws: LocalQuotaClientError.outputTooLarge) {
      _ = try await client.sync()
    }
  }

  @Test
  func syncTimesOutAndForceKillsAnUncooperativeHelper() async throws {
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
      commandTimeout: .seconds(1),
      terminationGracePeriod: .milliseconds(50)
    )
    let task = Task { try await client.sync() }
    let processIdentifier = try await helper.waitForProcessIdentifier()

    await #expect(throws: LocalQuotaClientError.timedOut) {
      _ = try await task.value
    }
    assertProcessNoLongerExists(processIdentifier)
  }

  @Test
  func loginUsesItsIndependentInteractiveTimeout() async throws {
    let helper = try TemporaryHelper(
      body: """
        /bin/sleep 0.2
        printf '%s' '\(signedInAuthJSON)'
        """
    )
    defer { helper.remove() }
    let client = try LocalQuotaClient(
      executableURL: helper.url,
      commandTimeout: .milliseconds(50),
      loginTimeout: .seconds(2)
    )

    #expect(try await client.login().status == .signedIn)
  }

  @Test
  func cancellingLoginTerminatesTheHelperAndPreservesCancellation() async throws {
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
      commandTimeout: .seconds(2),
      loginTimeout: .seconds(5),
      terminationGracePeriod: .milliseconds(50)
    )
    let task = Task { try await client.login() }
    let processIdentifier = try await helper.waitForProcessIdentifier()
    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    assertProcessNoLongerExists(processIdentifier)
  }
}

private let signedOutSyncJSON =
  #"{"schema_version":2,"status":"signed_out","local_report":{"protocol_version":2,"captured_at":"2026-08-02T01:00:00Z","results":[]},"local_usage":{"protocol_version":2,"generated_at":"2026-08-02T01:00:00Z","aggregation_timezone":null,"range":{"from":"2026-07-04","to":"2026-08-02"},"status":"unavailable","totals":null,"cost":null,"coverage":[],"breakdowns":[]},"account_summary":null}"#

private let signedInAuthJSON =
  #"{"schema_version":1,"status":"signed_in","account_id":"account_test","device_id":"device_test","device_generation":1}"#

private let signedOutAuthJSON = #"{"schema_version":1,"status":"signed_out"}"#

private let accountSummaryJSON =
  #"{"protocol_version":2,"generated_at":"2026-08-02T01:00:00Z","account":{"account_id":"account_test","display_label":"octocat","created_at":"2026-08-01T00:00:00Z"},"devices":[],"quota":[],"usage":{"range":{"from":"2026-08-01","to":"2026-08-02"},"totals":{"input_tokens":0,"cache_read_tokens":0,"cache_write_5m_tokens":0,"cache_write_1h_tokens":0,"cache_write_inferred_tokens":0,"output_tokens":0,"reasoning_tokens":0,"requests":0,"web_search_requests":0,"web_fetch_requests":0,"source_cost_microusd":null,"source_cost_covered_requests":0},"cost":{"mode":"calculate","basis":"none","status":"complete","amount_microusd":null,"catalog_revision":null,"calculated_rows":0,"reported_rows":0,"unpriced_rows":0,"assumptions":[],"unpriced":[]},"coverage":[],"breakdowns":[]}}"#

private func assertProcessNoLongerExists(_ processIdentifier: Int32) {
  let signalResult = Darwin.kill(processIdentifier, 0)
  let signalError = errno
  #expect(signalResult == -1)
  #expect(signalError == ESRCH)
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
          if !processIdentifier.isEmpty { return try #require(Int32(processIdentifier)) }
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
