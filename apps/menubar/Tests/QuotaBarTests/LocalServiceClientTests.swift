import Foundation
import Testing

@testable import QuotaBar

@Suite(.serialized)
struct LocalServiceClientTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["QUOTA_LIVE_HELPER"] != nil))
  func decodesInstalledServiceStateWhenRequested() async throws {
    guard
      let path = ProcessInfo.processInfo.environment["QUOTA_LIVE_HELPER"],
      !path.isEmpty
    else {
      return
    }
    let client = try LocalServiceClient(executableURL: URL(filePath: path))
    defer { Task { await client.shutdown() } }

    _ = try await client.state()
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
            components = [
                {"name": name, "status": "ready", "message": None, "metrics": {}}
                for name in ["providers", "quota", "usage", "pricing", "account", "sync"]
            ]
            result = {
                "schema_version": 1,
                "status": "healthy",
                "generated_at": "2026-08-11T00:00:00Z",
                "client": {"name": "QuotaBar", "version": "0.0.7"},
                "components": components,
                "issues": [],
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
    #expect(report.status == .healthy)
    #expect(report.components.count == 6)
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
