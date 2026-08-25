import Foundation
import Testing

@testable import QuotaBar

@Suite(.serialized)
struct LocalServiceClientTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["QUOTA_LIVE_HELPER"] != nil))
  func decodesInstalledServiceStateBeforeAndAfterRefresh() async throws {
    guard
      let path = ProcessInfo.processInfo.environment["QUOTA_LIVE_HELPER"],
      !path.isEmpty
    else {
      return
    }
    let client = try LocalServiceClient(executableURL: URL(filePath: path))
    defer { Task { await client.shutdown() } }

    _ = try await client.state()
    let refresh = try await client.refresh()
    #expect(refresh.accepted || refresh.pending)

    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(15))
    while clock.now < deadline {
      let state = try await client.state()
      if state.revision > refresh.revision,
        !state.quota.refreshing,
        state.quota.value != nil
      {
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("The installed service did not complete a quota refresh")
  }

  @Test
  func keepsOneProcessForRequestsAndDeliversStateEvents() async throws {
    let service = try TemporaryService(
      python: #"""
        import json
        import os
        import sys

        revision = 0
        for line in sys.stdin:
            request = json.loads(line)
            revision += 1
            operation = request["operation"]
            if operation == "get_state":
                result = {
                    "ipc_version": 1,
                    "revision": revision,
                    "usage_upload_enabled": True,
                    "usage_periods": {"local": {}, "account": {}},
                    "quota": component("unavailable"),
                    "usage": component("unavailable"),
                    "account": component("signed_out", {
                        "auth_status": "signed_out",
                        "account_id": None,
                        "device_id": None,
                        "device_generation": None,
                        "account_summary": None,
                    }),
                    "pricing": component("unavailable"),
                    "providers": [],
                    "provider_browser_sessions": [],
                    "overview": [],
                    "cache": settled_cache(),
                }
            elif operation == "refresh":
                assert request["payload"] == {}
                result = {"accepted": True, "pending": False, "revision": revision}
            elif operation == "shutdown":
                result = {}
            else:
                result = {}
            print(json.dumps({
                "type": "response",
                "request_id": request["request_id"],
                "result": result,
            }), flush=True)
            if operation == "refresh":
                print(json.dumps({
                    "type": "event",
                    "event": "state_changed",
                    "revision": revision,
                    "changed_components": ["quota"],
                }), flush=True)
            if operation == "shutdown":
                break

        """#
    )
    defer { service.remove() }
    let client = try LocalServiceClient(executableURL: service.executableURL)
    var events = client.events.makeAsyncIterator()

    let first = try await client.state()
    let second = try await client.state()
    let refresh = try await client.refresh()
    let event = await events.next()

    #expect(first.revision == 1)
    #expect(second.revision == 2)
    #expect(refresh.accepted)
    #expect(!refresh.pending)
    #expect(event?.event == "state_changed")
    #expect(try service.launchCount() == 1)
    await client.shutdown()
  }

  @Test
  func decodesBoundedUnifiedDiagnosticReport() async throws {
    let service = try TemporaryService(
      python: #"""
        import json
        import sys

        request = json.loads(sys.stdin.readline())
        if request["operation"] == "diagnose":
            result = {
                "schema_version": 2,
                "summary": {"operation": "healthy", "data": "empty", "attention": "none"},
                "refresh": {"phase": "idle", "revision": 7, "as_of": "2026-08-11T00:00:00Z", "started_at": None, "next_due_at": None},
                "generated_at": "2026-08-11T00:00:00Z",
                "client": {"name": "QuotaBar", "version": "0.0.7"},
                "surfaces": [
                    {"name": "quota_overview", "operation": "healthy", "data": "empty", "source": None, "metrics": {}},
                    {"name": "usage_this_device", "operation": "healthy", "data": "empty", "source": "this_device", "metrics": {}},
                    {"name": "usage_account", "operation": "healthy", "data": "empty", "source": "account", "metrics": {}},
                    {"name": "account", "operation": "healthy", "data": "empty", "source": "account", "metrics": {}},
                ],
                "checks": [],
                "findings": [],
                "recent_activity": {"attempts": [], "history_truncated": False},
            }
        else:
            result = {}
        print(json.dumps({
            "type": "response",
            "request_id": request["request_id"],
            "result": result,
        }), flush=True)
        """#
    )
    defer { service.remove() }
    let client = try LocalServiceClient(executableURL: service.executableURL)
    let report = try await client.diagnose()
    #expect(report.summary.operation == .healthy)
    #expect(report.surfaces.count == 4)
    await client.shutdown()
  }

  @Test
  func mapsStableRemoteErrorsWithoutAcceptingPartialResults() async throws {
    let service = try TemporaryService(
      python: #"""
        import json
        import sys

        request = json.loads(sys.stdin.readline())
        print(json.dumps({
            "type": "response",
            "request_id": request["request_id"],
            "error": {"code": "network_error", "recovery_action": "retry"},
        }), flush=True)
        """#
    )
    defer { service.remove() }
    let client = try LocalServiceClient(executableURL: service.executableURL)

    await #expect(
      throws: LocalServiceClientError.remote(
        LocalServiceRemoteError(code: .networkError, recoveryAction: .retry)
      )
    ) {
      _ = try await client.state()
    }
  }

  @Test
  func decodesDeviceDisconnectReasonFromRemoteError() async throws {
    let service = try TemporaryService(
      python: #"""
        import json
        import sys

        request = json.loads(sys.stdin.readline())
        print(json.dumps({
            "type": "response",
            "request_id": request["request_id"],
            "error": {"code": "device_deleted", "recovery_action": "login"},
        }), flush=True)
        """#
    )
    defer { service.remove() }
    let client = try LocalServiceClient(executableURL: service.executableURL)
    let remoteError = LocalServiceRemoteError(code: .deviceDeleted, recoveryAction: .login)

    await #expect(throws: LocalServiceClientError.remote(remoteError)) {
      _ = try await client.state()
    }
    #expect(
      LocalServiceClientError.remote(remoteError).errorDescription
        == "This device was removed. Sign in again to reconnect it."
    )
  }

  @Test
  func malformedRemoteErrorClosesThePendingRequest() async throws {
    let service = try TemporaryService(
      python: #"""
        import json
        import sys

        request = json.loads(sys.stdin.readline())
        print(json.dumps({
            "type": "response",
            "request_id": request["request_id"],
            "error": {"code": "not_a_wire_code", "recovery_action": "retry"},
        }), flush=True)
        """#
    )
    defer { service.remove() }
    let client = try LocalServiceClient(executableURL: service.executableURL)

    await #expect(throws: LocalServiceClientError.invalidMessage) {
      _ = try await client.state()
    }
  }

  @Test
  func mismatchedResponseIDClosesAllPendingRequests() async throws {
    let service = try TemporaryService(
      python: #"""
        import json
        import sys

        json.loads(sys.stdin.readline())
        print(json.dumps({
            "type": "response",
            "request_id": "different-request",
            "result": {},
        }), flush=True)
        """#
    )
    defer { service.remove() }
    let client = try LocalServiceClient(executableURL: service.executableURL)

    await #expect(throws: LocalServiceClientError.invalidMessage) {
      _ = try await client.state()
    }
  }

  @Test
  func helperExitClosesConcurrentPendingRequests() async throws {
    let service = try TemporaryService(
      python: #"""
        import sys

        sys.stdin.readline()
        """#
    )
    defer { service.remove() }
    let client = try LocalServiceClient(executableURL: service.executableURL)

    async let first = stateError(from: client)
    async let second = stateError(from: client)
    let errors = await [first, second]
    #expect(errors.allSatisfy { $0 == .connectionClosed })
  }

  @Test
  func noSigpipeDescriptorsReportEPIPEOnceTheReaderIsGone() throws {
    // `startIfNeeded` sets this on the helper's stdin so that `request` can catch a broken pipe.
    var descriptors: [Int32] = [0, 0]
    try #require(pipe(&descriptors) == 0)
    defer { close(descriptors[1]) }
    try #require(fcntl(descriptors[1], F_SETNOSIGPIPE, 1) == 0)
    close(descriptors[0])

    // Without the option this write terminates the runner instead of returning.
    #expect(write(descriptors[1], "x", 1) == -1)
    #expect(errno == EPIPE)
  }

  @Test
  func timesOutAndRestartsAfterAStalledRequest() async throws {
    let service = try TemporaryService(
      python: #"""
        import json
        import sys
        import time

        if int(launch_count_path.read_text()) == 1:
            time.sleep(2)

        for line in sys.stdin:
            request = json.loads(line)
            print(json.dumps({
                "type": "response",
                "request_id": request["request_id"],
                "result": {
                    "ipc_version": 1,
                    "revision": 1,
                    "usage_upload_enabled": True,
                    "usage_periods": {"local": {}, "account": {}},
                    "quota": component("unavailable"),
                    "usage": component("unavailable"),
                    "account": component("signed_out", {
                        "auth_status": "signed_out",
                        "account_id": None,
                        "device_id": None,
                        "device_generation": None,
                        "account_summary": None,
                    }),
                    "pricing": component("unavailable"),
                    "providers": [],
                    "provider_browser_sessions": [],
                    "overview": [],
                    "cache": settled_cache(),
                },
            }), flush=True)
            break
        """#
    )
    defer { service.remove() }
    let client = try LocalServiceClient(
      executableURL: service.executableURL,
      requestTimeoutNanoseconds: 500_000_000
    )

    await #expect(throws: LocalServiceClientError.requestTimedOut) {
      _ = try await client.state()
    }
    _ = try await client.state()
    #expect(try service.launchCount() == 2)
    await client.shutdown()
  }
}

private func stateError(from client: LocalServiceClient) async -> LocalServiceClientError? {
  do {
    _ = try await client.state()
    return nil
  } catch let error as LocalServiceClientError {
    return error
  } catch {
    return .invalidMessage
  }
}

private struct TemporaryService {
  let directoryURL: URL
  let executableURL: URL
  let launchCountURL: URL

  init(python body: String) throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appending(path: "QuotaBarServiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    executableURL = directoryURL.appending(path: "quota-service")
    launchCountURL = directoryURL.appending(path: "launch-count")
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let script = """
      #!/usr/bin/env python3
      from pathlib import Path
      launch_count_path = Path(\(String(reflecting: launchCountURL.path)))
      count = int(launch_count_path.read_text()) if launch_count_path.exists() else 0
      launch_count_path.write_text(str(count + 1))
      def component(status, value=None):
          return {
              "status": status,
              "value": value,
              "updated_at": None,
              "last_error": None,
              "refreshing": False,
          }
      def settled_cache():
          return {"rebuilding": False, "reset_at": None}
      \(body)
      """
    try Data(script.utf8).write(to: executableURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executableURL.path
    )
  }

  func launchCount() throws -> Int {
    try Int(String(contentsOf: launchCountURL, encoding: .utf8)) ?? 0
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}
