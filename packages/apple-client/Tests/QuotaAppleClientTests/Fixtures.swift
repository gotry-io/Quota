import Foundation
import QuotaAccount
import QuotaAlerts
import QuotaRelay
import QuotaWire
import os

enum Fixtures {
  static let accessToken = "qia_synthetic_access_token"
  static let refreshToken = "qiar_synthetic_refresh_token"
  static let rotatedAccess = "qia_synthetic_rotated_access"
  static let rotatedRefresh = "qiar_synthetic_rotated_refresh"

  static func session(
    accountID: String = "account_01",
    deviceID: String? = nil,
    access: String = accessToken,
    refresh: String = refreshToken,
    accessExpiresAt: Date? = nil,
    activation: AccountSessionActivation = .active
  ) -> AccountSession {
    AccountSession(
      accountID: accountID,
      deviceID: deviceID,
      accessToken: access,
      accessExpiresAt: accessExpiresAt ?? date("2999-01-01T00:00:00Z"),
      refreshToken: refresh,
      refreshExpiresAt: date("2999-01-01T00:00:00Z"),
      activation: activation
    )
  }

  static func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)!
  }

  /// GET / PUT `/api/v2/account/settings` body. Keys stay snake_case because this document
  /// is not decoded by `WireCodec`.
  static func accountSettingsJSON(
    revision: Int = 0,
    updatedAt: String = "1970-01-01T00:00:00Z",
    resetReminders: Bool = true,
    paceAlerts: Bool = true,
    thresholds: [String: [Int]] = [:],
    amountUSD: String? = nil,
    budgetAlerts: Bool = true
  ) -> Data {
    var object: [String: Any] = [
      "protocol_version": 2,
      "revision": revision,
      "updated_at": updatedAt,
      "alerts": [
        "reset_reminders": resetReminders,
        "pace_alerts": paceAlerts,
        "thresholds": thresholds,
      ],
      "budget": [
        "amount_usd": amountUSD as Any,
        "alerts": budgetAlerts,
      ],
    ]
    if amountUSD == nil {
      var budget = object["budget"] as! [String: Any]
      budget["amount_usd"] = NSNull()
      object["budget"] = budget
    }
    return try! JSONSerialization.data(withJSONObject: object)
  }

  static func summaryTotals(input: Int = 1000, output: Int = 200) -> [String: Any] {
    [
      "total_tokens": input + output,
      "input_tokens": input,
      "output_tokens": output,
      "cache_read_input_tokens": 100,
      "cache_write_input_tokens": 0,
      "reasoning_tokens": 50,
      "messages": 1,
    ]
  }

  static func completeCost() -> [String: Any] {
    [
      "mode": "calculate",
      "basis": "calculated",
      "status": "complete",
      "amount_microusd": "3138",
      "catalog_revision": "pricing_1",
      "calculated_rows": 1,
      "reported_rows": 0,
      "unpriced_rows": 0,
      "assumptions": ["agent_default_channel"],
      "unpriced": [],
    ]
  }

  static func usageActivityDay(date: String = "2026-08-10") -> [String: Any] {
    [
      "date": date,
      "totals": summaryTotals(),
      "cost": completeCost(),
      "partial": false,
    ]
  }

  static func accountUsagePeriodJSON(
    from: String = "2026-08-02",
    to: String = "2026-08-02",
    timezone: String = "UTC",
    totals: [String: Any]? = nil
  ) throws -> Data {
    let totals = totals ?? summaryTotals()
    let object: [String: Any] = [
      "protocol_version": 6,
      "request": ["from": from, "to": to, "timezone": timezone],
      "bounds": [
        "start": "\(from)T00:00:00Z",
        "end": "\(from)T01:00:00Z",
        "grid": WireCodec.usageHourGridRule,
      ],
      "totals": totals,
      "cost": completeCost(),
      "cache_saved": cacheSaved(),
      "days": [
        ["date": from, "totals": totals, "cost": completeCost(), "partial": false]
      ],
      "coverage": [
        "partial": false,
        "daily_retained_from": NSNull(),
        "hourly_retained_from": NSNull(),
        "truncated_by_retention": false,
      ],
      "revision": [
        "usage_revision": 1,
        "device_generation": 1,
        "account_updated_at": "2026-08-02T12:00:00Z",
        "pricing_revision": "pricing_1",
        "model_catalog_revision": "models_1",
        "fold_version": 1,
      ],
    ]
    return try JSONSerialization.data(withJSONObject: object)
  }

  static func usageActivityJSON(days: [[String: Any]]) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "protocol_version": 6,
      "days": days,
    ])
  }

  static func cacheSaved() -> [String: Any] {
    [
      "amount_microusd": "190",
      "status": "complete",
      "unpriced_rows": 0,
    ]
  }

  static func usagePeriod(cost: [String: Any]? = nil) -> [String: Any] {
    [
      "totals": summaryTotals(),
      "cost": cost ?? completeCost(),
      "cache_saved": cacheSaved(),
      "partial": false,
      "agents": [],
    ]
  }

  static func accountUsage(today: [String: Any]? = nil) -> [String: Any] {
    [
      "today": today ?? usagePeriod(),
      "last_7_days": usagePeriod(),
      "last_30_days": usagePeriod(),
      "all": usagePeriod(),
    ]
  }

  static let identityToken =
    "\(String(repeating: "a", count: 20)).\(String(repeating: "b", count: 40))."
    + String(repeating: "c", count: 43)

  static func accountIdentitiesJSON(
    identities: [[String: Any]]? = nil,
    extraRoot: [String: Any] = [:]
  ) throws -> Data {
    var object: [String: Any] = [
      "protocol_version": 2,
      "account": [
        "account_id": "account_01",
        "display_label": "octocat",
        "created_at": "2026-01-04T12:00:00Z",
      ],
      "identities": identities
        ?? [
          ["provider": "github", "label": "octocat", "linked_at": "2026-01-04T12:00:00Z"],
          ["provider": "apple", "label": NSNull(), "linked_at": "2026-02-04T12:00:00Z"],
        ],
    ]
    for (key, value) in extraRoot {
      object[key] = value
    }
    return try JSONSerialization.data(withJSONObject: object)
  }

  static func identityLinkJSON(
    provider: String = "apple",
    status: String = "linked"
  ) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "protocol_version": 2,
      "provider": provider,
      "status": status,
    ])
  }

  static func accountSummaryJSON(
    accountID: String = "account_01",
    usage: [String: Any]? = nil
  ) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "protocol_version": 6,
      "account": [
        "account_id": accountID,
        "display_label": "octocat",
        "created_at": "2026-07-01T00:00:00Z",
      ],
      "devices": [],
      "subscriptions": [],
      "usage": usage ?? accountUsage(),
      "pricing_revision": "pricing_1",
      "model_catalog_revision": "models_1",
    ])
  }

  /// The control document an upload reads first.
  static func deviceSync(generation: Int) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "protocol_version": 2,
      "account_id": "account_01",
      "device_id": "device_01",
      "device_generation": generation,
      "usage_deleted_before": NSNull(),
      "usage_sync_revision": 0,
    ])
  }

  static func uploadResponse(generation: Int) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "protocol_version": 6,
      "device_id": "device_01",
      "device_generation": generation,
      "accepted": ["codex"],
      "ignored": [],
    ])
  }

  /// A reading taken on this device, as the upload envelope carries it.
  static func localSnapshot() -> QuotaSnapshot {
    QuotaSnapshot(
      provider: .codex,
      account: QuotaAccount(fingerprint: "fp", fingerprintScope: .global),
      windows: [
        QuotaWindow(id: "weekly", title: "Weekly", usedPercent: 20, durationSeconds: 604_800)
      ],
      status: .available,
      observedAt: date("2026-08-14T15:00:00Z")
    )
  }

  static func tokenResponse(
    access: String = accessToken,
    refresh: String = refreshToken,
    extra: [String: Any] = [:]
  ) throws -> Data {
    var object: [String: Any] = [
      "protocol_version": 2,
      "token_type": "Bearer",
      "account_id": "account_01",
      "session": [
        "access_token": access,
        "access_expires_at": "2999-01-01T00:00:00Z",
        "refresh_token": refresh,
        "refresh_expires_at": "2999-01-01T00:00:00Z",
      ],
    ]
    for (key, value) in extra {
      object[key] = value
    }
    return try JSONSerialization.data(withJSONObject: object)
  }

  static func refreshResponse(
    access: String = rotatedAccess,
    refresh: String = rotatedRefresh,
    accessExpiresAt: String = "2999-01-01T00:00:00Z",
    extra: [String: Any] = [:]
  ) throws -> Data {
    var object: [String: Any] = [
      "protocol_version": 2,
      "token_type": "Bearer",
      "account_id": "account_01",
      "session": [
        "access_token": access,
        "access_expires_at": accessExpiresAt,
        "refresh_token": refresh,
        "refresh_expires_at": "2999-01-01T00:00:00Z",
      ],
    ]
    for (key, value) in extra {
      object[key] = value
    }
    return try JSONSerialization.data(withJSONObject: object)
  }

  static func errorBody(code: String, message: String = "Rejected.") throws -> Data {
    try JSONSerialization.data(
      withJSONObject: [
        "error": ["code": code, "message": message]
      ]
    )
  }
}

final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
  struct Exchange {
    var status: Int
    var body: Data
    var headers: [String: String]
    var delayNanoseconds: UInt64

    init(
      status: Int,
      body: Data = Data(),
      headers: [String: String] = [:],
      delayNanoseconds: UInt64 = 0
    ) {
      self.status = status
      self.body = body
      self.headers = headers
      self.delayNanoseconds = delayNanoseconds
    }
  }

  private struct State {
    var exchanges: [Exchange]
    var requests: [URLRequest] = []
    var bodies: [Data] = []
  }

  private let lock: OSAllocatedUnfairLock<State>

  init(_ exchanges: [Exchange]) {
    self.lock = OSAllocatedUnfairLock(initialState: State(exchanges: exchanges))
  }

  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let exchange = try lock.withLock { state -> Exchange in
      state.requests.append(request)
      state.bodies.append(request.httpBody ?? Data())
      guard !state.exchanges.isEmpty else {
        throw HTTPTransportError.unavailable
      }
      return state.exchanges.removeFirst()
    }
    if exchange.delayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: exchange.delayNanoseconds)
    }
    guard let url = request.url,
      let response = HTTPURLResponse(
        url: url,
        statusCode: exchange.status,
        httpVersion: "HTTP/1.1",
        headerFields: exchange.headers
      )
    else {
      throw HTTPTransportError.unavailable
    }
    return (exchange.body, response)
  }

  var recordedURLs: [URL] {
    lock.withLock { $0.requests.compactMap(\.url) }
  }

  var recordedMethods: [String] {
    lock.withLock { $0.requests.compactMap(\.httpMethod) }
  }

  var recordedAuthorization: [String?] {
    lock.withLock { $0.requests.map { $0.value(forHTTPHeaderField: "Authorization") } }
  }

  var tokenPosts: Int {
    lock.withLock {
      $0.requests.filter { $0.httpMethod == "POST" && $0.url?.path == "/oauth/v2/token" }.count
    }
  }

  var recordedBodies: [Data] {
    lock.withLock { $0.bodies }
  }

  var recordedIfNoneMatch: [String?] {
    lock.withLock { $0.requests.map { $0.value(forHTTPHeaderField: "If-None-Match") } }
  }

  var recordedIfMatch: [String?] {
    lock.withLock { $0.requests.map { $0.value(forHTTPHeaderField: "If-Match") } }
  }
}

struct FixedEntropy: RandomBytesGenerating {
  let values: [UInt8]

  func bytes(count: Int) throws -> [UInt8] {
    Array(values.prefix(count))
  }
}
