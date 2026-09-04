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

  static func summaryTotals(
    input: Int = 1000,
    output: Int = 200,
    cacheRead: Int = 100
  ) -> [String: Any] {
    [
      "total_tokens": input + output,
      "input_tokens": input,
      "output_tokens": output,
      "cache_read_input_tokens": cacheRead,
      "cache_write_input_tokens": 0,
      "reasoning_tokens": 50,
      "messages": 1,
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

  static func usageActivityDay(
    date: String = "2026-08-10",
    totals: [String: Any]? = nil,
    cost: [String: Any]? = nil,
    partial: Bool = false,
    agents: [[String: Any]]? = nil
  ) -> [String: Any] {
    var object: [String: Any] = [
      "date": date,
      "totals": totals ?? summaryTotals(),
      "cost": cost ?? completeCost(),
      "partial": partial,
    ]
    if let agents {
      object["agents"] = agents
    }
    return object
  }

  static func usageActivityJSON(
    days: [[String: Any]],
    extra: [String: Any] = [:]
  ) throws -> Data {
    var object: [String: Any] = [
      "protocol_version": 6,
      "days": days,
    ]
    for (key, value) in extra {
      object[key] = value
    }
    return try JSONSerialization.data(withJSONObject: object)
  }

  static func usagePeriod(
    totals: [String: Any]? = nil,
    cost: [String: Any]? = nil,
    partial: Bool = false,
    agents: [[String: Any]] = []
  ) -> [String: Any] {
    [
      "totals": totals ?? summaryTotals(),
      "cost": cost ?? completeCost(),
      "partial": partial,
      "agents": agents,
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

  static func accountSummaryJSON(
    accountID: String = "account_01",
    extraRoot: [String: Any] = [:],
    usage: [String: Any]? = nil,
    subscriptions: [[String: Any]] = [],
    devices: [[String: Any]] = []
  ) throws -> Data {
    var object: [String: Any] = [
      "protocol_version": 6,
      "account": [
        "account_id": accountID,
        "display_label": "octocat",
        "created_at": "2026-07-01T00:00:00Z",
      ],
      "devices": devices,
      "subscriptions": subscriptions,
      "usage": usage ?? accountUsage(),
      "pricing_revision": "pricing_1",
      "model_catalog_revision": "models_1",
    ]
    for (key, value) in extraRoot {
      object[key] = value
    }
    return try JSONSerialization.data(withJSONObject: object)
  }

  static func quotaSubscription() -> [String: Any] {
    [
      "key": "codex|fp_codex_01|global|",
      "provider": "codex",
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
      "sources": [["device_id": "device_01", "observed_at": "2026-08-14T15:00:00Z"]],
    ]
  }

  static func accountDevice() -> [String: Any] {
    [
      "id": "device_01",
      "display_name": "Studio Mac",
      "platform": "macos",
      "last_seen_at": "2026-08-14T15:00:05Z",
      "last_observed_at": "2026-08-14T15:00:00Z",
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
      "session": [
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
      "account_id": "account_01",
      "session": [
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

  var recordedIfNoneMatch: [String?] {
    lock.withLock { $0.requests.map { $0.value(forHTTPHeaderField: "If-None-Match") } }
  }
}

struct FixedEntropy: RandomBytesGenerating {
  let values: [UInt8]

  func bytes(count: Int) throws -> [UInt8] {
    Array(values.prefix(count))
  }
}
