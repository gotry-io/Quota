import Foundation

enum RelayClientErrorCategory: String, Sendable {
  case configuration
  case unsupported
  case authentication
  case authorization
  case unavailable
  case malformedData
}

enum RelayClientError: LocalizedError, Equatable, Sendable {
  case invalidRelayURL
  case invalidRequest
  case unsupportedRelay
  case instanceMismatch
  case credentialRejected
  case permissionDenied
  case resourceNotFound
  case pairingUnavailable
  case rateLimited
  case redirected
  case requestFailed
  case unavailable
  case responseTooLarge
  case malformedResponse

  var category: RelayClientErrorCategory {
    switch self {
    case .invalidRelayURL, .invalidRequest, .instanceMismatch:
      .configuration
    case .unsupportedRelay:
      .unsupported
    case .credentialRejected:
      .authentication
    case .permissionDenied:
      .authorization
    case .redirected, .requestFailed, .unavailable, .responseTooLarge, .rateLimited,
      .resourceNotFound, .pairingUnavailable:
      .unavailable
    case .malformedResponse:
      .malformedData
    }
  }

  var errorDescription: String? {
    switch self {
    case .invalidRelayURL:
      "The Relay address is invalid."
    case .invalidRequest:
      "The Relay request is invalid."
    case .unsupportedRelay:
      "This Relay does not support secure QuotaBar access."
    case .instanceMismatch:
      "The Relay instance no longer matches this profile."
    case .credentialRejected:
      "The Relay controller credential is no longer valid."
    case .permissionDenied:
      "The Relay controller credential lacks the required permission."
    case .resourceNotFound:
      "The requested Relay item was not found."
    case .pairingUnavailable:
      "The pairing request is no longer available."
    case .rateLimited:
      "The Relay is receiving too many requests. Try again later."
    case .redirected:
      "The Relay attempted to redirect an authenticated request."
    case .requestFailed:
      "The Relay could not complete the request."
    case .unavailable:
      "The Relay is unavailable."
    case .responseTooLarge:
      "The Relay response exceeds the allowed size."
    case .malformedResponse:
      "The Relay returned malformed data."
    }
  }
}

actor RelayClient {
  private static let maximumResponseBytes = 1_048_576
  private static let requestTimeout: TimeInterval = 20

  private let transport: any RelayHTTPTransport

  init(transport: any RelayHTTPTransport = URLSessionRelayHTTPTransport()) {
    self.transport = transport
  }

  func discover(baseURL: URL) async throws -> RelayInfo {
    let canonicalURL: URL
    do {
      canonicalURL = try RelayOrigin.canonicalURL(from: baseURL)
    } catch {
      throw RelayClientError.invalidRelayURL
    }

    let request = makeRequest(
      url: canonicalURL.appending(path: ".well-known/quotabar-relay"),
      method: "GET"
    )
    let response = try await send(request)
    try requireStatus(response.statusCode, expected: 200, authenticated: false)

    let relayInfo: RelayInfo = try decode(RelayInfo.self, from: response.body)
    guard !relayInfo.instanceID.isEmpty,
      !relayInfo.version.isEmpty,
      relayInfo.apiVersions.contains(1),
      relayInfo.authMethods.contains("bearer"),
      relayInfo.capabilities.persistentSnapshots,
      relayInfo.capabilities.instantDeviceRevocation
    else {
      throw RelayClientError.unsupportedRelay
    }
    return relayInfo
  }

  func registerController(baseURL: URL) async throws -> ControllerRegistrationResponse {
    let canonicalURL: URL
    do {
      canonicalURL = try RelayOrigin.canonicalURL(from: baseURL)
    } catch {
      throw RelayClientError.invalidRelayURL
    }
    let request = makeRequest(
      url: canonicalURL.appending(path: "api/v1/controllers"),
      method: "POST"
    )
    let response = try await send(request)
    try requireStatus(response.statusCode, expected: 201, authenticated: false)
    return try decode(ControllerRegistrationResponse.self, from: response.body)
  }

  func approvePairing(
    userCode: String,
    profile: RelayProfile,
    controllerBearer: String
  ) async throws {
    try await decidePairing(
      action: "approve",
      userCode: userCode,
      profile: profile,
      controllerBearer: controllerBearer
    )
  }

  func denyPairing(
    userCode: String,
    profile: RelayProfile,
    controllerBearer: String
  ) async throws {
    try await decidePairing(
      action: "deny",
      userCode: userCode,
      profile: profile,
      controllerBearer: controllerBearer
    )
  }

  func fetchLatestSnapshots(
    profile: RelayProfile,
    controllerBearer: String
  ) async throws -> ControllerSnapshotListResponse {
    let boundURL = try await verifyInstance(for: profile)
    let request = try authenticatedRequest(
      url: boundURL.appending(path: "api/v1/snapshots"),
      method: "GET",
      controllerBearer: controllerBearer
    )
    let response = try await send(request)
    try requireStatus(response.statusCode, expected: 200, authenticated: true)
    return try decode(ControllerSnapshotListResponse.self, from: response.body)
  }

  func listDevices(
    profile: RelayProfile,
    controllerBearer: String
  ) async throws -> DeviceListResponse {
    let boundURL = try await verifyInstance(for: profile)
    let request = try authenticatedRequest(
      url: boundURL.appending(path: "api/v1/devices"),
      method: "GET",
      controllerBearer: controllerBearer
    )
    let response = try await send(request)
    try requireStatus(response.statusCode, expected: 200, authenticated: true)
    return try decode(DeviceListResponse.self, from: response.body)
  }

  func revokeDevice(
    deviceID: String,
    profile: RelayProfile,
    controllerBearer: String
  ) async throws {
    let boundURL = try await verifyInstance(for: profile)
    guard !deviceID.isEmpty,
      let encodedDeviceID = deviceID.addingPercentEncoding(
        withAllowedCharacters: Self.pathSegmentCharacters
      ),
      let url = URL(
        string: "\(boundURL.absoluteString)/api/v1/devices/\(encodedDeviceID)"
      )
    else {
      throw RelayClientError.invalidRequest
    }

    let request = try authenticatedRequest(
      url: url,
      method: "DELETE",
      controllerBearer: controllerBearer
    )
    let response = try await send(request)
    try requireStatus(response.statusCode, expected: 204, authenticated: true)
  }

  func deleteController(
    profile: RelayProfile,
    controllerBearer: String
  ) async throws {
    let boundURL = try await verifyInstance(for: profile)
    let request = try authenticatedRequest(
      url: boundURL.appending(path: "api/v1/controllers/self"),
      method: "DELETE",
      controllerBearer: controllerBearer
    )
    let response = try await send(request)
    try requireStatus(response.statusCode, expected: 204, authenticated: true)
  }

  private func decidePairing(
    action: String,
    userCode: String,
    profile: RelayProfile,
    controllerBearer: String
  ) async throws {
    let normalizedCode = userCode.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedCode.isEmpty else {
      throw RelayClientError.invalidRequest
    }

    let boundURL = try await verifyInstance(for: profile)
    let body: Data
    do {
      body = try QuotaWireCodec.makeEncoder().encode(
        PairingDecisionRequest(userCode: normalizedCode)
      )
    } catch {
      throw RelayClientError.invalidRequest
    }
    let request = try authenticatedRequest(
      url: boundURL.appending(path: "api/v1/pairings/\(action)"),
      method: "POST",
      controllerBearer: controllerBearer,
      body: body
    )
    let response = try await send(request)
    try requireStatus(response.statusCode, expected: 204, authenticated: true)
  }

  private func verifyInstance(for profile: RelayProfile) async throws -> URL {
    let boundURL: URL
    do {
      boundURL = try RelayOrigin.canonicalURL(from: profile.baseURL)
    } catch {
      throw RelayClientError.invalidRelayURL
    }
    guard boundURL == profile.baseURL else {
      throw RelayClientError.invalidRelayURL
    }
    let info = try await discover(baseURL: boundURL)
    guard info.instanceID == profile.instanceID else {
      throw RelayClientError.instanceMismatch
    }
    return boundURL
  }

  private func makeRequest(
    url: URL,
    method: String,
    body: Data? = nil
  ) -> URLRequest {
    var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
    request.httpMethod = method
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
      request.httpBody = body
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    return request
  }

  private func authenticatedRequest(
    url: URL,
    method: String,
    controllerBearer: String,
    body: Data? = nil
  ) throws -> URLRequest {
    guard !controllerBearer.isEmpty,
      controllerBearer == controllerBearer.trimmingCharacters(in: .whitespacesAndNewlines),
      controllerBearer.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
    else {
      throw RelayClientError.credentialRejected
    }
    var request = makeRequest(url: url, method: method, body: body)
    request.setValue("Bearer \(controllerBearer)", forHTTPHeaderField: "Authorization")
    return request
  }

  private func send(_ request: URLRequest) async throws -> RelayHTTPResponse {
    do {
      return try await transport.send(
        request,
        maximumResponseBytes: Self.maximumResponseBytes
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch RelayHTTPTransportError.responseTooLarge {
      throw RelayClientError.responseTooLarge
    } catch RelayHTTPTransportError.invalidResponse {
      throw RelayClientError.malformedResponse
    } catch {
      throw RelayClientError.unavailable
    }
  }

  private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
    do {
      return try QuotaWireCodec.makeDecoder().decode(type, from: data)
    } catch {
      throw RelayClientError.malformedResponse
    }
  }

  private func requireStatus(
    _ actual: Int,
    expected: Int,
    authenticated: Bool
  ) throws {
    guard actual == expected else {
      switch actual {
      case 300...399:
        throw RelayClientError.redirected
      case 401 where authenticated:
        throw RelayClientError.credentialRejected
      case 403 where authenticated:
        throw RelayClientError.permissionDenied
      case 404:
        throw RelayClientError.resourceNotFound
      case 409, 410:
        throw RelayClientError.pairingUnavailable
      case 429:
        throw RelayClientError.rateLimited
      case 500...599:
        throw RelayClientError.unavailable
      default:
        throw RelayClientError.requestFailed
      }
    }
  }

  private static let pathSegmentCharacters: CharacterSet = {
    var characters = CharacterSet.urlPathAllowed
    characters.remove(charactersIn: "/%?#")
    return characters
  }()
}

private struct PairingDecisionRequest: Encodable {
  let userCode: String
}
