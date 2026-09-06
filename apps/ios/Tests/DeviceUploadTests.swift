import Foundation
import QuotaAccount
import QuotaProviderSessions
import QuotaProviderWeb
import QuotaRelay
import QuotaWire
import Testing

@testable import Quota

/// This phone as a Device: what it presents when it signs in, what it sends afterwards, and
/// where paid sync stops it ([ADR 0041](../../../docs/decisions/0041-ios-is-a-device-when-sync-is-paid.md)).
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
  func aPaidDeviceUploadsWhatThisPhoneRead() async throws {
    let transport = RecordingHTTPTransport([
      .init(status: 200, body: try Fixtures.accountSummaryJSON()),
      .init(status: 200, body: try deviceSyncJSON(generation: 4)),
      .init(status: 200, body: try uploadResponseJSON(generation: 4)),
    ])
    let model = collectingModel(transport: transport, deviceID: "device_phone")

    await model.restore()

    #expect(transport.requests.map(\.path) == [
      "/api/v6/account/summary",
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
    #expect(model.isSyncOn)
  }

  @Test
  func aRefusedUploadStopsAtTheControlDocumentAndSaysSyncIsOff() async throws {
    let transport = RecordingHTTPTransport([
      .init(
        status: 200,
        body: try Fixtures.accountSummaryJSON(
          entitlement: Fixtures.entitlement(status: "expired")
        )
      ),
      .init(status: 200, body: try Fixtures.accountSummaryJSON()),
      .init(status: 402, body: subscriptionRequiredJSON()),
    ])
    let model = collectingModel(transport: transport, deviceID: "device_phone")

    // An Account whose entitlement has expired is not asked to accept a write at all.
    await model.restore()
    #expect(transport.requests.map(\.path) == ["/api/v6/account/summary"])
    #expect(!model.isSyncOn)
    #expect(model.syncBanner == SyncCopy.offBanner)

    // An Account whose summary says sync is on, refused at the boundary, says so too, and
    // sends no reading after the refusal.
    await model.refresh()
    #expect(transport.requests.map(\.path) == [
      "/api/v6/account/summary",
      "/api/v6/account/summary",
      "/api/v2/device/sync",
    ])
    #expect(!model.isSyncOn)
    #expect(model.syncBanner == SyncCopy.offBanner)
  }

  @Test
  func aSessionThatNamesNoDeviceUploadsNothing() async throws {
    let transport = RecordingHTTPTransport([
      .init(status: 200, body: try Fixtures.accountSummaryJSON())
    ])
    let model = collectingModel(transport: transport, deviceID: nil)

    await model.restore()

    #expect(transport.requests.map(\.path) == ["/api/v6/account/summary"])
    #expect(model.localCollection?.snapshots.count == 1)
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
  deviceID: String?
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
  return AppModel(
    account: AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: MemoryAccountSessionStore(
        session: Fixtures.session(deviceID: deviceID)
      ),
      summaryStore: MemoryAccountSummaryStore(value: nil),
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
  }

  struct Recorded {
    var method: String
    var path: String
    var body: Data?
  }

  private let lock = NSLock()
  private var exchanges: [Exchange]
  private var recorded: [Recorded] = []

  init(_ exchanges: [Exchange]) {
    self.exchanges = exchanges
  }

  var requests: [Recorded] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    guard let exchange = record(request) else { throw HTTPTransportError.unavailable }
    let response = HTTPURLResponse(
      url: request.url ?? URL(string: "https://quota.gotry.io")!,
      statusCode: exchange.status,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!
    return (exchange.body, response)
  }

  private func record(_ request: URLRequest) -> Exchange? {
    lock.lock()
    defer { lock.unlock() }
    recorded.append(
      Recorded(
        method: request.httpMethod ?? "GET",
        path: request.url?.path ?? "",
        body: request.httpBody
      )
    )
    return exchanges.isEmpty ? nil : exchanges.removeFirst()
  }
}

private struct NotAnObject: Error {}

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
      "access_expires_at": "2026-08-14T12:15:00Z",
      "refresh_token": Fixtures.refreshToken,
      "refresh_expires_at": "2026-11-01T12:00:00Z",
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

private func subscriptionRequiredJSON() -> Data {
  Data(
    """
    {"error":{"code":"subscription_required","message":"Sync is off."}}
    """.utf8
  )
}
