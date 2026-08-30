import Foundation
import Testing

@testable import QuotaBar

@Suite(.serialized)
struct LocalServiceClientTests {
  /// Fast enough for a test, and in the same proportions the app uses: the helper is declared
  /// dead after two unanswered pings, and killed if it does not exit within the grace period.
  private static let testTimings = LocalServiceClientTimings(
    ready: .seconds(10),
    ping: .milliseconds(50),
    termination: .milliseconds(200)
  )

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
                result = state(revision)
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
    let client = try client(for: service)
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
                "schema_version": 3,
                "generated_at": "2026-08-11T00:00:00Z",
                "client": {"name": "QuotaBar", "version": "0.0.7"},
                "summary": {"operation": "healthy", "attention": "none"},
                "surfaces": [
                    {"id": "quota_overview", "status": "ok", "data": "empty", "last_success_at": None, "message": "No quota yet.", "recovery": "none"},
                    {"id": "usage_this_device", "status": "ok", "data": "empty", "last_success_at": None, "message": "No Usage yet.", "recovery": "none"},
                    {"id": "usage_account", "status": "inactive", "data": "empty", "last_success_at": None, "message": "Usage sync is off.", "recovery": "none"},
                    {"id": "account", "status": "inactive", "data": "empty", "last_success_at": None, "message": "Not signed in.", "recovery": "none"},
                ],
                "sources": [],
                "recent": [],
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
    let client = try client(for: service)
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
    let client = try client(for: service)

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
    let client = try client(for: service)
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
    let client = try client(for: service)

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
    let client = try client(for: service)

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
    let client = try client(for: service)

    async let first = stateError(from: client)
    async let second = stateError(from: client)
    let errors = await [first, second]
    #expect(errors.allSatisfy { $0 == .connectionClosed })
  }

  @Test
  func noSigpipeDescriptorsReportEPIPEOnceTheReaderIsGone() throws {
    // `launch` sets this on the helper's stdin so that `write` can catch a broken pipe.
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
  func holdsRequestsUntilTheHelperAnnouncesItselfReady() async throws {
    let service = try TemporaryService(
      announcesReady: false,
      python: #"""
        import json
        import select
        import sys
        import time

        # Long enough that a client which did not wait would already have written its request.
        time.sleep(0.4)
        early = bool(select.select([sys.stdin.fileno()], [], [], 0)[0])
        ready()

        for line in sys.stdin:
            request = json.loads(line)
            print(json.dumps({
                "type": "response",
                "request_id": request["request_id"],
                "result": state(2 if early else 1),
            }), flush=True)
            break
        """#
    )
    defer { service.remove() }
    let client = try client(for: service)

    let state = try await client.state()
    #expect(state.revision == 1, "the request reached the helper before it announced ready")
  }

  @Test
  func killsAHelperThatStopsAnsweringPingsAndStartsAFreshOne() async throws {
    let service = try TemporaryService(
      python: #"""
        import json
        import os
        import signal
        import sys
        import time

        if int(launch_count_path.read_text()) == 1:
            # Only SIGKILL can end this launch, and it answers nothing after the first request.
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            pid_path.write_text(str(os.getpid()))
            sys.stdin.readline()
            time.sleep(600)

        for line in sys.stdin:
            request = json.loads(line)
            print(json.dumps({
                "type": "response",
                "request_id": request["request_id"],
                "result": state(1),
            }), flush=True)
            break
        """#
    )
    defer { service.remove() }
    let client = try client(for: service)

    // The pending request fails only once the helper has been reaped and its reader has ended,
    // so reaching this line at all is what proves both happened.
    await #expect(throws: LocalServiceClientError.connectionClosed) {
      _ = try await client.state()
    }
    let killed = try service.processIdentifier()
    #expect(kill(killed, 0) == -1 && errno == ESRCH)

    let state = try await client.state()
    #expect(state.revision == 1)
    #expect(try service.launchCount() == 2)
    await client.shutdown()
  }

  @Test
  func keepsASlowRequestRunningWhileTheHelperAnswersPings() async throws {
    // Two seconds against a fifty-millisecond ping is forty rounds of liveness, the same
    // proportion as a request running for more than three minutes in the app.
    let service = try TemporaryService(
      python: #"""
        import json
        import sys
        import threading

        lock = threading.Lock()

        def emit(message):
            with lock:
                print(json.dumps(message), flush=True)

        def answer_slowly(request_id):
            threading.Event().wait(2.0)
            emit({"type": "response", "request_id": request_id, "result": state(1)})

        for line in sys.stdin:
            request = json.loads(line)
            if request["operation"] == "ping":
                emit({
                    "type": "response",
                    "request_id": request["request_id"],
                    "result": {"ok": True},
                })
                continue
            if request["operation"] == "shutdown":
                emit({"type": "response", "request_id": request["request_id"], "result": {}})
                break
            threading.Thread(
                target=answer_slowly, args=(request["request_id"],), daemon=True
            ).start()
        """#
    )
    defer { service.remove() }
    let client = try client(for: service)

    let state = try await client.state()
    #expect(state.revision == 1)
    #expect(try service.launchCount() == 1)
    await client.shutdown()
  }

  /// A cancelled caller does not leave a waiter behind, and the answer the helper was already
  /// holding for it is expected on arrival: an unknown request id is otherwise a protocol
  /// violation, and would close a connection that is working.
  @Test
  func aCancelledRequestLetsGoOfItsWaiterAndItsLateAnswerIsDropped() async throws {
    let service = try TemporaryService(
      python: #"""
        import json
        import sys
        import threading

        lock = threading.Lock()

        def emit(message):
            with lock:
                print(json.dumps(message), flush=True)

        def answer_slowly(request_id):
            threading.Event().wait(0.4)
            emit({"type": "response", "request_id": request_id, "result": state(1)})

        for line in sys.stdin:
            request = json.loads(line)
            if request["operation"] == "ping":
                emit({
                    "type": "response",
                    "request_id": request["request_id"],
                    "result": {"ok": True},
                })
                continue
            if request["operation"] == "shutdown":
                emit({"type": "response", "request_id": request["request_id"], "result": {}})
                break
            threading.Thread(
                target=answer_slowly, args=(request["request_id"],), daemon=True
            ).start()
        """#
    )
    defer { service.remove() }
    let client = try client(for: service)

    // One completed request first, so the cancellation below lands on a written request rather
    // than on the launch it would otherwise still be waiting for.
    _ = try await client.state()

    let abandoned = Task { try await client.state() }
    try await Task.sleep(for: .milliseconds(100))
    abandoned.cancel()
    await #expect(throws: CancellationError.self) {
      _ = try await abandoned.value
    }

    // The helper answers it anyway. The connection has to survive that.
    try await Task.sleep(for: .milliseconds(500))
    let state = try await client.state()
    #expect(state.revision == 1)
    #expect(try service.launchCount() == 1, "the late answer did not cost the helper its life")
    await client.shutdown()
  }

  /// The same for a caller waiting on the helper to finish opening: it stops waiting when it is
  /// cancelled rather than when the helper gets around to announcing itself.
  @Test
  func aCancelledCallerStopsWaitingForReady() async throws {
    let service = try TemporaryService(
      announcesReady: false,
      python: #"""
        import json
        import sys
        import time

        time.sleep(0.6)
        ready()

        for line in sys.stdin:
            request = json.loads(line)
            print(json.dumps({
                "type": "response",
                "request_id": request["request_id"],
                "result": state(1),
            }), flush=True)
        """#
    )
    defer { service.remove() }
    let client = try client(for: service)

    let abandoned = Task { try await client.state() }
    try await Task.sleep(for: .milliseconds(100))
    abandoned.cancel()
    await #expect(throws: CancellationError.self) {
      _ = try await abandoned.value
    }

    // The helper opens as it was always going to, and the next request is served by it.
    let state = try await client.state()
    #expect(state.revision == 1)
    #expect(try service.launchCount() == 1)
    await client.shutdown()
  }

  @Test
  func reportsAHelperThatNeverAnnouncesItselfAsUnavailableAfterOneRetry() async throws {
    // A helper that records the start it is and then answers nothing: no `ready`, no response,
    // and no clock of its own. It ends when the client closes its stdin, so every step of this
    // test is something the client did rather than time that passed.
    let service = try TemporaryService(
      announcesReady: false,
      python: #"""
        import sys

        sys.stdin.read()
        """#
    )
    defer { service.remove() }
    // macOS assesses a newly written executable the first time it is started, which costs
    // hundreds of milliseconds and far more on a loaded machine. Spending it here rather than
    // inside the ready deadline is what keeps that deadline measuring the helper's silence.
    try await service.warmUp()

    // The ready deadline is the only clock the outcome depends on. No request is ever written,
    // so liveness never pings; a helper whose stdin has been closed exits before the grace
    // period matters. Both are set past anything reachable here so that neither can decide
    // this test, and the deadline itself is two orders of magnitude longer than a warm start.
    let client = try LocalServiceClient(
      executableURL: service.executableURL,
      timings: LocalServiceClientTimings(
        ready: .seconds(1),
        ping: .seconds(60),
        termination: .seconds(5)
      )
    )

    await #expect(throws: LocalServiceClientError.launchFailed) {
      _ = try await client.state()
    }
    #expect(try service.launchCount() == 2, "a silent helper is restarted exactly once")
  }

  private func client(for service: TemporaryService) throws -> LocalServiceClient {
    try LocalServiceClient(executableURL: service.executableURL, timings: Self.testTimings)
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
  let processIdentifierURL: URL

  init(announcesReady: Bool = true, python body: String) throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appending(path: "QuotaBarServiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    executableURL = directoryURL.appending(path: "quota-service")
    launchCountURL = directoryURL.appending(path: "launch-count")
    processIdentifierURL = directoryURL.appending(path: "pid")
    try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    let script = """
      #!/usr/bin/env python3
      import json as _json
      from pathlib import Path
      launch_count_path = Path(\(String(reflecting: launchCountURL.path)))
      pid_path = Path(\(String(reflecting: processIdentifierURL.path)))
      count = int(launch_count_path.read_text()) if launch_count_path.exists() else 0
      launch_count_path.write_text(str(count + 1))
      def ready():
          print(_json.dumps({"type": "event", "event": "ready", "ipc_version": 1}), flush=True)
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
      def state(revision):
          return {
              "ipc_version": 1,
              "revision": revision,
              "usage_upload_enabled": True,
              "quota_refresh_interval_seconds": 300,
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
              "browser_scan_enabled": [],
              "overview": [],
              "cache": settled_cache(),
          }
      \(announcesReady ? "ready()" : "")
      \(body)
      """
    try Data(script.utf8).write(to: executableURL, options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: executableURL.path
    )
  }

  /// Runs the fixture once with nothing on its stdin, waits for it to exit, and then forgets
  /// that start. The first execution of a freshly written file pays macOS's launch assessment,
  /// which is far slower than every start after it; a test that measures one of the client's
  /// own deadlines calls this so that the deadline is not measuring that assessment instead.
  func warmUp() async throws {
    let process = Process()
    process.executableURL = executableURL
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    // Waiting for the exit rather than for an interval: the fixture reaches end of file on its
    // first read, so this returns as soon as it has run, however long that took.
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      process.terminationHandler = { _ in continuation.resume() }
      do {
        try process.run()
      } catch {
        process.terminationHandler = nil
        continuation.resume(throwing: error)
      }
    }
    try FileManager.default.removeItem(at: launchCountURL)
  }

  func launchCount() throws -> Int {
    try Int(String(contentsOf: launchCountURL, encoding: .utf8)) ?? 0
  }

  func processIdentifier() throws -> pid_t {
    try pid_t(String(contentsOf: processIdentifierURL, encoding: .utf8)) ?? 0
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}
