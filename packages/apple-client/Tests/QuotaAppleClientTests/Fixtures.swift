import Foundation
import QuotaAccount
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
    access: String = accessToken,
    refresh: String = refreshToken
  ) -> AccountSession {
    AccountSession(
      accountID: accountID,
      accessToken: access,
      accessExpiresAt: date("2026-08-14T12:15:00Z"),
      refreshToken: refresh,
      refreshExpiresAt: date("2026-11-01T12:00:00Z")
    )
  }

  static func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)!
  }

  static func emptyUsage(from: String = "2026-08-14", to: String = "2026-08-14") -> [String: Any] {
    [
      "range": ["from": from, "to": to],
      "totals": tokenTotals(),
      "cost": completeCost(),
      "coverage": "complete",
      "breakdowns": [],
    ]
  }

  static func tokenTotals(
    input: Int = 1000,
    output: Int = 200,
    cacheRead: Int = 100
  ) -> [String: Any] {
    [
      "input_tokens": input,
      "cache_read_tokens": cacheRead,
      "cache_write_5m_tokens": 0,
      "cache_write_1h_tokens": 0,
      "cache_write_inferred_tokens": 0,
      "output_tokens": output,
      "reasoning_tokens": 50,
      "requests": 1,
      "web_search_requests": 0,
      "web_fetch_requests": 0,
      "source_cost_microusd": NSNull(),
      "source_cost_covered_requests": 0,
    ]
  }

  static func completeCost(amount: String = "3138") -> [String: Any] {
    [
      "mode": "calculate",
      "basis": "calculated",
      "status": "complete",
      "amount_microusd": amount,
      "catalog_revision": "pricing_1",
      "calculated_rows": 1,
      "reported_rows": 0,
      "unpriced_rows": 0,
      "assumptions": ["agent_default_channel"],
      "unpriced": [],
    ]
  }

  static func accountSummaryJSON(
    accountID: String = "account_01",
    extraRoot: [String: Any] = [:],
    extraUsage: [String: Any] = [:],
    quota: [[String: Any]] = [],
    devices: [[String: Any]] = []
  ) throws -> Data {
    var usage = emptyUsage()
    for (key, value) in extraUsage {
      usage[key] = value
    }
    var object: [String: Any] = [
      "protocol_version": 5,
      "account": [
        "account_id": accountID,
        "display_label": "octocat",
        "created_at": "2026-07-01T00:00:00Z",
      ],
      "devices": devices,
      "quota": quota,
      "usage": usage,
    ]
    for (key, value) in extraRoot {
      object[key] = value
    }
    return try JSONSerialization.data(withJSONObject: object)
  }

  static func quotaObservation() -> [String: Any] {
    [
      "device_id": "device_01",
      "snapshot": [
        "provider": "codex",
        "account": [
          "fingerprint": "fp_codex_01",
          "fingerprint_scope": "global",
          "label": "codex-user",
          "plan": "plus",
        ],
        "windows": [
          [
            "id": "weekly",
            "title": "Weekly",
            "used_percent": 29.0,
            "resets_at": "2026-08-18T00:00:00Z",
          ]
        ],
        "status": "available",
        "observed_at": "2026-08-14T15:00:00Z",
      ],
    ]
  }

  static func accountDevice(health: Any = NSNull()) -> [String: Any] {
    [
      "device_id": "device_01",
      "display_name": "Studio Mac",
      "platform": "macos",
      "device_generation": 1,
      "status": "active",
      "created_at": "2026-08-01T00:00:00Z",
      "last_login_at": "2026-08-14T15:00:00Z",
      "last_seen_at": "2026-08-14T15:00:05Z",
      "signed_out_at": NSNull(),
      "health": health,
    ]
  }

  static func deviceHealth() -> [String: Any] {
    [
      "schema_version": 1,
      "client_product": "quotabar",
      "client_version": "0.0.16",
      "platform": "macos",
      "observed_at": "2026-08-14T15:00:00Z",
      "refresh_revision": 42,
      "last_completed_refresh_at": "2026-08-14T15:00:00Z",
      "last_successful_account_sync_at": "2026-08-14T14:59:00Z",
      "summary": ["operation": "healthy", "data": "current", "attention": "none"],
      "top_code": NSNull(),
      "consecutive_failures": 0,
      "usage_upload_enabled": true,
      "received_at": "2026-08-14T15:00:05Z",
      "fresh_until": "2026-08-14T15:20:05Z",
    ]
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
      "account_session": [
        "access_token": access,
        "access_expires_at": "2026-08-14T12:15:00Z",
        "refresh_token": refresh,
        "refresh_expires_at": "2026-11-01T12:00:00Z",
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
    extra: [String: Any] = [:]
  ) throws -> Data {
    var object: [String: Any] = [
      "protocol_version": 2,
      "token_type": "Bearer",
      "token_audience": "account",
      "account_id": "account_01",
      "account_session": [
        "access_token": access,
        "access_expires_at": "2026-08-14T13:15:00Z",
        "refresh_token": refresh,
        "refresh_expires_at": "2026-11-02T12:00:00Z",
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
}

struct FixedEntropy: RandomBytesGenerating {
  let values: [UInt8]

  func bytes(count: Int) throws -> [UInt8] {
    Array(values.prefix(count))
  }
}
