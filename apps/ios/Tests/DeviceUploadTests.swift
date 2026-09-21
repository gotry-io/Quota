import Foundation
import QuotaAccount
import QuotaProviderSessions
import QuotaProviderStatus
import QuotaProviderWeb
import QuotaRelay
import QuotaWire
import Testing

@testable import Quota

/// This phone as a Device: what it presents when it signs in, and what it sends afterwards
/// ([ADR 0041](../../../docs/decisions/0041-ios-is-a-device-when-sync-is-paid.md)).
@MainActor
struct DeviceUploadTests {
  @Test
  func signingInPresentsThisInstallation() async throws {
    let transport = RecordingHTTPTransport([
      .init(status: 200, body: try tokenResponseJSON(device: "device_phone")),
      .init(status: 200, body: try Fixtures.accountSummaryJSON()),
    ])
    let sessions = MemoryAccountSessionStore()
    let model = connectModel(
      transport: transport,
      sessions: sessions,
      installation: MemoryInstallationIdentity(value: "6eec1da2-8d8f-4e77-9a9a-3b6d61bf8998")
    )

    await model.connectAccount()

    let exchange = try #require(transport.requests.first)
    let body = try #require(exchange.body)
    let json = try jsonObject(body)
    #expect(json["installation_id"] as? String == "6eec1da2-8d8f-4e77-9a9a-3b6d61bf8998")
    #expect(json["platform"] as? String == "ios")
    #expect((json["device_display_name"] as? String)?.isEmpty == false)
    // Nothing about a provider session goes with it.
    #expect(!String(decoding: body, as: UTF8.self).contains("cookie"))
    #expect(try sessions.load()?.deviceID == "device_phone")
    #expect(model.sessionDeviceID == "device_phone")
  }

  @Test
  func aDeviceUploadsWhatThisPhoneRead() async throws {
    let transport = RecordingHTTPTransport([
      .init(status: 200, body: try Fixtures.accountSummaryJSON()),
      .init(status: 200, body: try deviceSyncJSON(generation: 4)),
      .init(status: 200, body: try uploadResponseJSON(generation: 4)),
    ])
    let model = collectingModel(transport: transport, deviceID: "device_phone")

    await model.restore()
    await model.waitForDetachedLaunchWork()

    #expect(
      transport.requests.map(\.path).filter { $0 != "/api/v2/providers/status" } == [
        "/api/v6/account/summary",
        "/api/v2/account/settings",
        "/api/v2/device/sync",
        "/api/v6/device/snapshots",
      ])
    let upload = try #require(transport.requests.last)
    #expect(upload.method == "PUT")
    let envelope = try jsonObject(try #require(upload.body))
    // The generation the control document answered, not one the client remembered.
    #expect(envelope["generation"] as? Int == 4)
    #expect(envelope["protocol_version"] as? Int == 6)
    let snapshots = try #require(envelope["snapshots"] as? [[String: Any]])
    #expect(snapshots.count == 1)
    #expect(snapshots[0]["provider"] as? String == "codex")
    #expect(snapshots[0]["observed_at"] != nil)
  }

  @Test
  func aSessionThatNamesNoDeviceUploadsNothing() async throws {
    let transport = RecordingHTTPTransport([
      .init(status: 200, body: try Fixtures.accountSummaryJSON())
    ])
    let model = collectingModel(transport: transport, deviceID: nil)

    await model.restore()
    await model.waitForDetachedLaunchWork()

    #expect(
      transport.requests.map(\.path).filter { $0 != "/api/v2/providers/status" } == [
        "/api/v6/account/summary",
        "/api/v2/account/settings",
      ])
    #expect(model.localCollection?.snapshots.count == 1)
  }

  @Test
  func aForegroundLaunchDetachesUploadAndABackgroundRefreshAwaitsIt() async throws {
    let delayed = RecordingHTTPTransport([
      .init(status: 200, body: try Fixtures.accountSummaryJSON()),
      .init(status: 200, body: try deviceSyncJSON(generation: 4), delayNanoseconds: 200_000_000),
      .init(status: 200, body: try uploadResponseJSON(generation: 4)),
    ])
    let launched = collectingModel(transport: delayed, deviceID: "device_phone")
    await launched.restore()
    #expect(!delayed.requests.map(\.path).contains("/api/v6/device/snapshots"))
    await launched.waitForDetachedLaunchWork()
    #expect(delayed.requests.map(\.path).contains("/api/v6/device/snapshots"))

    let awaited = RecordingHTTPTransport([
      .init(status: 200, body: try Fixtures.accountSummaryJSON()),
      .init(status: 200, body: try deviceSyncJSON(generation: 4), delayNanoseconds: 50_000_000),
      .init(status: 200, body: try uploadResponseJSON(generation: 4)),
    ])
    let background = collectingModel(transport: awaited, deviceID: "device_phone")
    background.poseSession(activation: .active, deviceID: "device_phone")
    #expect(await background.refresh(awaitUpload: true))
    #expect(awaited.requests.map(\.path).contains("/api/v6/device/snapshots"))
  }

  @Test
  func aSecondRefreshJoinsAnInFlightUpload() async throws {
    let summary = try Fixtures.accountSummaryJSON()
    let sync = try deviceSyncJSON(generation: 4)
    let uploaded = try uploadResponseJSON(generation: 4)
    let transport = RecordingHTTPTransport(
      byPath: [
        "/api/v6/account/summary": [
          .init(status: 200, body: summary),
          .init(status: 200, body: summary),
        ],
        "/api/v2/device/sync": [
          .init(status: 200, body: sync, delayNanoseconds: 200_000_000),
          .init(status: 200, body: sync, delayNanoseconds: 200_000_000),
        ],
        "/api/v6/device/snapshots": [
          .init(status: 200, body: uploaded),
          .init(status: 200, body: uploaded),
        ],
      ]
    )
    let model = collectingModel(transport: transport, deviceID: "device_phone")
    await model.restore()
    #expect(!transport.requests.map(\.path).contains("/api/v6/device/snapshots"))
    #expect(await model.refresh(awaitUpload: true))
    let syncs = transport.requests.filter { $0.path == "/api/v2/device/sync" }
    #expect(syncs.count == 2)
    #expect(transport.requests.map(\.path).contains("/api/v6/device/snapshots"))
    #expect(transport.maxInFlightSync == 1)
  }

  @Test
  func aColdLaunchThatNeverOpensUsageDoesNotReadUsage() async throws {
    let range = UsageActivityCalendar.range(
      endingOn: UsageActivityCalendar.utcDay(from: collectedAt))
    let usageStore = MemoryAccountUsageStore(
      value: CachedAccountUsage(
        accountID: "account_01",
        activity: CachedUsageActivity(
          from: range.from,
          to: range.to,
          etag: "\"a\"",
          fetchedAt: collectedAt,
          response: AccountUsageActivityResponse(days: [])
        )
      )
    )
    let transport = RecordingHTTPTransport([
      .init(status: 200, body: try Fixtures.accountSummaryJSON()),
      .init(status: 200, body: try deviceSyncJSON(generation: 4)),
      .init(status: 200, body: try uploadResponseJSON(generation: 4)),
    ])
    let model = collectingModel(
      transport: transport,
      deviceID: "device_phone",
      usageStore: usageStore,
      syncAccountSettings: false
    )
    await model.restore()
    await model.setForeground(true)
    await model.waitForDetachedLaunchWork()
    let paths = Set(transport.requests.map(\.path))
    #expect(paths.contains("/api/v6/account/summary"))
    #expect(paths.contains("/api/v2/providers/status"))
    #expect(paths.contains("/api/v2/device/sync"))
    #expect(paths.contains("/api/v6/device/snapshots"))
    #expect(!paths.contains("/api/v6/account/usage/activity"))
    #expect(!paths.contains("/api/v6/account/usage/period"))
  }

  @Test
  func aRegisteredPhoneIsTheAccountsRowRatherThanOneOfItsOwn() async throws {
    let phone: [String: Any] = [
      "id": "device_phone",
      "display_name": "Kyle iPhone",
      "platform": "ios",
      "last_seen_at": "2026-08-14T15:00:00Z",
      "last_observed_at": "2026-08-14T15:00:00Z",
    ]
    let model = makeModel(
      session: Fixtures.session(deviceID: "device_phone"),
      cache: nil,
      exchanges: [
        .init(status: 200, body: try Fixtures.accountSummaryJSON(devices: [phone]))
      ]
    )

    await model.restore()

    #expect(model.isRegisteredDevice)
    #expect(model.summary?.devices.first?.platform == .ios)
    #expect(DeviceRowContent.make(try #require(model.summary?.devices.first)).platform == "iOS")

    let reader = makeModel(
      session: Fixtures.session(),
      cache: nil,
      exchanges: [.init(status: 200, body: try Fixtures.accountSummaryJSON(devices: [phone]))]
    )
    await reader.restore()
    #expect(!reader.isRegisteredDevice)
  }
}

// MARK: - Harness

private let collectedAt = Fixtures.date("2026-08-14T16:00:00Z")

@MainActor
private func collectingModel(
  transport: RecordingHTTPTransport,
  deviceID: String?,
  usageStore: any AccountUsageStore = MemoryAccountUsageStore(),
  providerStatusClient: (any ProviderStatusServing)? = nil,
  syncAccountSettings: Bool = true
) -> AppModel {
  let providerSessions = MemoryProviderSessionStore(
    sessions: [
      StoredProviderSession(
        provider: .codex,
        accountFingerprint: "fp",
        cookieHeader: "session=fp",
        accountLabel: nil,
        storedAt: collectedAt,
        lastValidatedAt: collectedAt
      )
    ]
  )
  let relay = RelayClient(transport: transport)
  return AppModel(
    account: AccountClient(
      relay: relay,
      sessionStore: MemoryAccountSessionStore(
        session: Fixtures.session(deviceID: deviceID)
      ),
      summaryStore: MemoryAccountSummaryStore(value: nil),
      usageStore: usageStore,
      now: { collectedAt }
    ),
    authenticator: ScriptedAuthenticator(result: .failure(AuthorizationError.cancelled)),
    providerSessions: providerSessions,
    localStore: MemoryLocalCollectionStore(),
    localCollector: LocalCollector(
      sessions: providerSessions,
      collectors: { provider, _ in UploadStubCollector(provider: provider) },
      now: { collectedAt }
    ),
    providerStatusClient: providerStatusClient
      ?? ProviderStatusClient(catalog: RelayProviderStatusCatalog(relay: relay)),
    settingsDefaults: UserDefaults(suiteName: "QuotaTests.SettingsSync.\(UUID().uuidString)")!,
    syncAccountSettings: syncAccountSettings,
    installation: MemoryInstallationIdentity(value: "6eec1da2-8d8f-4e77-9a9a-3b6d61bf8998"),
    now: { collectedAt }
  )
}

@MainActor
private func connectModel(
  transport: RecordingHTTPTransport,
  sessions: MemoryAccountSessionStore,
  installation: MemoryInstallationIdentity
) -> AppModel {
  AppModel(
    account: AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: sessions,
      summaryStore: MemoryAccountSummaryStore(value: nil),
      now: { collectedAt }
    ),
    authenticator: ScriptedAuthenticator(
      result: .success(
        URL(
          string:
            "io.gotry.quota:/oauth/callback?code=synthetic-login-code&state=client-state-123456789"
        )!
      )
    ),
    makeAuthorizationAttempt: {
      AuthorizationAttempt(
        authorizationURL: URL(string: "https://quota.gotry.io/oauth/v2/authorize")!,
        state: "client-state-123456789",
        verifier: String(repeating: "a", count: 43),
        challenge: "challenge"
      )
    },
    settingsDefaults: UserDefaults(suiteName: "QuotaTests.SettingsSync.\(UUID().uuidString)")!,
    syncAccountSettings: true,
    installation: installation,
    now: { collectedAt }
  )
}

private struct UploadStubCollector: ProviderWebCollector {
  static var provider: ProviderID { .codex }
  let provider: ProviderID

  func validate(cookieHeader: String) async throws -> ValidatedBrowserSession {
    ValidatedBrowserSession(accountFingerprint: "fp", accountLabel: nil)
  }

  func collect(cookieHeader: String) async throws -> QuotaSnapshot {
    QuotaSnapshot(
      provider: provider,
      account: QuotaAccount(fingerprint: "fp", fingerprintScope: .global),
      windows: [
        QuotaWindow(id: "weekly", title: "Weekly", usedPercent: 20, durationSeconds: 604_800)
      ],
      status: .available,
      observedAt: collectedAt
    )
  }
}

/// A transport that keeps what was asked, because what this phone sends is the thing under test.
final class RecordingHTTPTransport: HTTPTransport, @unchecked Sendable {
  struct Exchange {
    var status: Int
    var body: Data
    var delayNanoseconds: UInt64

    init(status: Int, body: Data, delayNanoseconds: UInt64 = 0) {
      self.status = status
      self.body = body
      self.delayNanoseconds = delayNanoseconds
    }
  }

  struct Recorded {
    var method: String
    var path: String
    var body: Data?
  }

  private let lock = NSLock()
  private var exchanges: [Exchange]
  private var exchangesByPath: [String: [Exchange]]
  private var recorded: [Recorded] = []
  private var inFlightSync = 0
  private var maxInFlightSyncValue = 0

  var maxInFlightSync: Int {
    lock.lock()
    defer { lock.unlock() }
    return maxInFlightSyncValue
  }

  init(_ exchanges: [Exchange]) {
    self.exchanges = exchanges
    self.exchangesByPath = [:]
  }

  init(byPath: [String: [Exchange]]) {
    self.exchanges = []
    self.exchangesByPath = byPath
  }

  var requests: [Recorded] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    if request.url?.path == "/api/v2/providers/status" {
      recordPath(request)
      let body = Data(
        #"{"providers":[{"id":"claude","indicator":"none","description":"All Systems Operational","checked_at":"2026-08-14T16:00:00Z"}]}"#
          .utf8)
      let response = HTTPURLResponse(
        url: request.url ?? URL(string: "https://quota.gotry.io")!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: nil
      )!
      return (body, response)
    }
    if request.url?.path == "/api/v2/account/settings" {
      recordPath(request)
      let body = defaultAccountSettingsBody(for: request)
      let response = HTTPURLResponse(
        url: request.url ?? URL(string: "https://quota.gotry.io")!,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["ETag": request.httpMethod == "PUT" ? "\"1\"" : "\"0\""]
      )!
      return (body, response)
    }
    guard let exchange = record(request) else { throw HTTPTransportError.unavailable }
    let path = request.url?.path ?? ""
    let trackingSync = path == "/api/v2/device/sync"
    if trackingSync {
      beginSync()
    }
    defer {
      if trackingSync {
        endSync()
      }
    }
    if exchange.delayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: exchange.delayNanoseconds)
    }
    let response = HTTPURLResponse(
      url: request.url ?? URL(string: "https://quota.gotry.io")!,
      statusCode: exchange.status,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!
    return (exchange.body, response)
  }

  private func recordPath(_ request: URLRequest) {
    lock.lock()
    recorded.append(
      Recorded(
        method: request.httpMethod ?? "GET",
        path: request.url?.path ?? "",
        body: request.httpBody
      )
    )
    lock.unlock()
  }

  private func record(_ request: URLRequest) -> Exchange? {
    lock.lock()
    defer { lock.unlock() }
    let path = request.url?.path ?? ""
    recorded.append(
      Recorded(
        method: request.httpMethod ?? "GET",
        path: path,
        body: request.httpBody
      )
    )
    if var queued = exchangesByPath[path] {
      guard !queued.isEmpty else { return nil }
      let exchange = queued.removeFirst()
      exchangesByPath[path] = queued
      return exchange
    }
    return exchanges.isEmpty ? nil : exchanges.removeFirst()
  }

  private func beginSync() {
    lock.lock()
    inFlightSync += 1
    maxInFlightSyncValue = max(maxInFlightSyncValue, inFlightSync)
    lock.unlock()
  }

  private func endSync() {
    lock.lock()
    inFlightSync -= 1
    lock.unlock()
  }
}

private struct NotAnObject: Error {}

private func defaultAccountSettingsBody(for request: URLRequest) -> Data {
  if request.httpMethod == "PUT", let body = request.httpBody,
    let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
  {
    var response = object
    response["revision"] = 1
    response["updated_at"] = "2026-09-21T10:00:00Z"
    return (try? JSONSerialization.data(withJSONObject: response))
      ?? defaultAccountSettingsGETBody()
  }
  return defaultAccountSettingsGETBody()
}

/// The body of a recorded request, as the object it is.
private func jsonObject(_ data: Data) throws -> [String: Any] {
  guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    throw NotAnObject()
  }
  return object
}

private func tokenResponseJSON(device: String?) throws -> Data {
  var object: [String: Any] = [
    "protocol_version": 2,
    "token_type": "Bearer",
    "account_id": "account_01",
    "display_label": "octocat",
    "session": [
      "access_token": Fixtures.accessToken,
      "access_expires_at": "2999-01-01T00:00:00Z",
      "refresh_token": Fixtures.refreshToken,
      "refresh_expires_at": "2999-01-01T00:00:00Z",
    ],
  ]
  if let device {
    object["device_id"] = device
    object["device_generation"] = 1
  }
  return try JSONSerialization.data(withJSONObject: object)
}

private func deviceSyncJSON(generation: Int) throws -> Data {
  try JSONSerialization.data(withJSONObject: [
    "protocol_version": 2,
    "account_id": "account_01",
    "device_id": "device_phone",
    "device_generation": generation,
    "usage_deleted_before": NSNull(),
    "usage_sync_revision": 0,
  ])
}

private func uploadResponseJSON(generation: Int) throws -> Data {
  try JSONSerialization.data(withJSONObject: [
    "protocol_version": 6,
    "device_id": "device_phone",
    "device_generation": generation,
    "accepted": ["codex"],
    "ignored": [],
  ])
}
