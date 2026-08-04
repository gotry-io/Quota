import Foundation
import Testing

@testable import QuotaBar

@Test
func discoversSupportedRelayWithoutAuthorization() async throws {
  let transport = StubRelayTransport([.response(200, supportedDiscovery)])
  let client = RelayClient(transport: transport)

  let info = try await client.discover(baseURL: URL(string: "HTTPS://Relay.EXAMPLE:443/")!)

  #expect(info.instanceID == "relay_primary")
  let request = try #require(await transport.recordedRequests().first)
  #expect(request.method == "GET")
  #expect(request.url == "https://relay.example/.well-known/quotabar-relay")
  #expect(request.authorization == nil)
  #expect(request.accept == "application/json")
  #expect(request.timeout == 20)
  #expect(request.maximumResponseBytes == 1_048_576)
}

@Test
func registersAnonymousOwnerWithAnEmptyUnauthenticatedRequest() async throws {
  let transport = StubRelayTransport([
    .response(201, Data(#"{"owner_token":"owner_registered_0123456789"}"#.utf8))
  ])
  let client = RelayClient(transport: transport)

  let registration = try await client.registerOwner(
    baseURL: URL(string: "https://quota.gotry.io")!
  )

  #expect(registration.ownerToken == "owner_registered_0123456789")
  let request = try #require(await transport.recordedRequests().first)
  #expect(request.method == "POST")
  #expect(request.path == "/api/v1/owners")
  #expect(request.authorization == nil)
  #expect(request.contentType == nil)
  #expect(request.body == nil)
}

@Test
func rejectsMalformedAnonymousOwnerRegistration() async throws {
  let transport = StubRelayTransport([
    .response(201, Data(#"{"owner_token":" owner_secret"}"#.utf8))
  ])

  do {
    _ = try await RelayClient(transport: transport).registerOwner(
      baseURL: URL(string: "https://quota.gotry.io")!
    )
    Issue.record("Expected malformed owner registration to fail.")
  } catch let error as RelayClientError {
    #expect(error == .malformedResponse)
    #expect(error.errorDescription?.contains("owner_secret") == false)
  }
}

@Test
func sendsExactPairingDecisionRequestsAfterDiscovery() async throws {
  let transport = StubRelayTransport([
    .response(200, supportedDiscovery),
    .response(204, Data()),
    .response(200, supportedDiscovery),
    .response(204, Data()),
  ])
  let client = RelayClient(transport: transport)
  let profile = try makeProfile()

  try await client.approvePairing(
    userCode: "  ABCD-EFGH  ",
    profile: profile,
    ownerBearer: ownerBearer
  )
  try await client.denyPairing(
    userCode: "IJKL-MNOP",
    profile: profile,
    ownerBearer: ownerBearer
  )

  let requests = await transport.recordedRequests()
  #expect(requests.count == 4)
  #expect(requests[0].authorization == nil)
  #expect(requests[1].method == "POST")
  #expect(requests[1].path == "/api/v1/pairings/approve")
  #expect(requests[1].authorization == "Bearer \(ownerBearer)")
  #expect(requests[1].contentType == "application/json")
  #expect(try jsonObject(requests[1].body) == ["user_code": "ABCD-EFGH"])
  #expect(requests[2].authorization == nil)
  #expect(requests[3].method == "POST")
  #expect(requests[3].path == "/api/v1/pairings/deny")
  #expect(try jsonObject(requests[3].body) == ["user_code": "IJKL-MNOP"])
}

@Test
func sendsExactOwnerReadAndRevokeRequests() async throws {
  let transport = StubRelayTransport([
    .response(200, supportedDiscovery),
    .response(200, Data(#"{"observations":[]}"#.utf8)),
    .response(200, supportedDiscovery),
    .response(200, Data(#"{"devices":[]}"#.utf8)),
    .response(200, supportedDiscovery),
    .response(204, Data()),
  ])
  let client = RelayClient(transport: transport)
  let profile = try makeProfile()

  let snapshots = try await client.fetchLatestSnapshots(
    profile: profile,
    ownerBearer: ownerBearer
  )
  let devices = try await client.listDevices(profile: profile, ownerBearer: ownerBearer)
  try await client.revokeDevice(
    deviceID: "device/with %2F space",
    profile: profile,
    ownerBearer: ownerBearer
  )

  #expect(snapshots.observations.isEmpty)
  #expect(devices.devices.isEmpty)
  let requests = await transport.recordedRequests()
  #expect(requests[1].method == "GET")
  #expect(requests[1].path == "/api/v1/snapshots")
  #expect(requests[3].method == "GET")
  #expect(requests[3].path == "/api/v1/devices")
  #expect(requests[5].method == "DELETE")
  #expect(requests[5].percentEncodedPath == "/api/v1/devices/device%2Fwith%20%252F%20space")
  #expect([requests[1], requests[3], requests[5]].allSatisfy {
    $0.authorization == "Bearer \(ownerBearer)"
  })
}

@Test
func sendsExactAuthenticatedOwnerDeletionRequest() async throws {
  let transport = StubRelayTransport([
    .response(200, supportedDiscovery),
    .response(204, Data()),
  ])
  let client = RelayClient(transport: transport)

  try await client.deleteOwner(
    profile: makeProfile(),
    ownerBearer: ownerBearer
  )

  let requests = await transport.recordedRequests()
  #expect(requests.count == 2)
  #expect(requests[0].authorization == nil)
  #expect(requests[1].method == "DELETE")
  #expect(requests[1].path == "/api/v1/owners/self")
  #expect(requests[1].authorization == "Bearer \(ownerBearer)")
  #expect(requests[1].body == nil)
}

@Test
func doesNotTreatARejectedOwnerCredentialAsProofOfDeletion() async throws {
  let transport = StubRelayTransport([
    .response(200, supportedDiscovery),
    .response(401, sensitiveServerBody),
  ])
  let client = RelayClient(transport: transport)

  await #expect(throws: RelayClientError.credentialRejected) {
    try await client.deleteOwner(
      profile: makeProfile(),
      ownerBearer: ownerBearer
    )
  }
}

@Test
func instanceMismatchSendsNoOwnerCredential() async throws {
  let transport = StubRelayTransport([
    .response(200, discovery(instanceID: "replacement_relay"))
  ])
  let client = RelayClient(transport: transport)
  let profile = try makeProfile()

  do {
    _ = try await client.listDevices(profile: profile, ownerBearer: ownerBearer)
    Issue.record("Expected the Relay instance mismatch to fail.")
  } catch let error as RelayClientError {
    #expect(error == .instanceMismatch)
  }

  let requests = await transport.recordedRequests()
  #expect(requests.count == 1)
  #expect(requests[0].authorization == nil)
}

@Test
func rejectsOwnerBearerWithSurroundingWhitespaceBeforeAuthenticatedRequest() async throws {
  let transport = StubRelayTransport([.response(200, supportedDiscovery)])
  let client = RelayClient(transport: transport)

  do {
    _ = try await client.listDevices(
      profile: makeProfile(),
      ownerBearer: " \(ownerBearer)"
    )
    Issue.record("Expected the invalid owner bearer to fail.")
  } catch let error as RelayClientError {
    #expect(error == .credentialRejected)
  }

  let requests = await transport.recordedRequests()
  #expect(requests.count == 1)
  #expect(requests[0].authorization == nil)
}

@Test(arguments: RelayFailureCase.allCases)
func returnsFixedSafeErrors(failure: RelayFailureCase) async throws {
  let endpointOutcome: StubRelayOutcome
  switch failure {
  case .redirect:
    endpointOutcome = .response(302, sensitiveServerBody)
  case .revoked:
    endpointOutcome = .response(401, sensitiveServerBody)
  case .forbidden:
    endpointOutcome = .response(403, sensitiveServerBody)
  case .notFound:
    endpointOutcome = .response(404, sensitiveServerBody)
  case .rateLimited:
    endpointOutcome = .response(429, sensitiveServerBody)
  case .unavailable:
    endpointOutcome = .response(503, sensitiveServerBody)
  case .oversize:
    endpointOutcome = .error(.responseTooLarge)
  case .malformed:
    endpointOutcome = .response(200, sensitiveServerBody)
  }
  let transport = StubRelayTransport([
    .response(200, supportedDiscovery),
    endpointOutcome,
  ])
  let client = RelayClient(transport: transport)

  do {
    _ = try await client.listDevices(profile: makeProfile(), ownerBearer: ownerBearer)
    Issue.record("Expected the Relay request to fail.")
  } catch let error as RelayClientError {
    #expect(error == failure.expectedError)
    let message = try #require(error.errorDescription)
    #expect(!message.contains(ownerBearer))
    #expect(!message.contains("ABCD-EFGH"))
    #expect(!message.contains("account_01"))
    #expect(!message.contains("alice@example.com"))
    #expect(!message.contains("upstream_secret"))
  }
}

@Test
func rejectsUnsupportedDiscoveryCapabilities() async throws {
  let unsupported = Data(
    String(decoding: supportedDiscovery, as: UTF8.self)
      .replacingOccurrences(of: "\"instant_device_revocation\":true", with: "\"instant_device_revocation\":false")
      .utf8
  )
  let transport = StubRelayTransport([.response(200, unsupported)])
  let client = RelayClient(transport: transport)

  do {
    _ = try await client.discover(baseURL: URL(string: "https://relay.example")!)
    Issue.record("Expected unsupported discovery to fail.")
  } catch let error as RelayClientError {
    #expect(error == .unsupportedRelay)
    #expect(error.category == .unsupported)
  }
}

enum RelayFailureCase: CaseIterable, CustomTestStringConvertible {
  case redirect
  case revoked
  case forbidden
  case notFound
  case rateLimited
  case unavailable
  case oversize
  case malformed

  var testDescription: String { String(describing: self) }

  var expectedError: RelayClientError {
    switch self {
    case .redirect: .redirected
    case .revoked: .credentialRejected
    case .forbidden: .permissionDenied
    case .notFound: .resourceNotFound
    case .rateLimited: .rateLimited
    case .unavailable: .unavailable
    case .oversize: .responseTooLarge
    case .malformed: .malformedResponse
    }
  }
}

private enum StubRelayOutcome: Sendable {
  case response(Int, Data)
  case error(RelayHTTPTransportError)
}

private struct RecordedRelayRequest: Sendable {
  let method: String?
  let url: String?
  let path: String?
  let percentEncodedPath: String?
  let authorization: String?
  let accept: String?
  let contentType: String?
  let timeout: TimeInterval
  let body: Data?
  let maximumResponseBytes: Int
}

private actor StubRelayTransport: RelayHTTPTransport {
  private var outcomes: [StubRelayOutcome]
  private var requests: [RecordedRelayRequest] = []

  init(_ outcomes: [StubRelayOutcome]) {
    self.outcomes = outcomes
  }

  func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> RelayHTTPResponse {
    requests.append(
      RecordedRelayRequest(
        method: request.httpMethod,
        url: request.url?.absoluteString,
        path: request.url?.path,
        percentEncodedPath: request.url.flatMap {
          URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath
        },
        authorization: request.value(forHTTPHeaderField: "Authorization"),
        accept: request.value(forHTTPHeaderField: "Accept"),
        contentType: request.value(forHTTPHeaderField: "Content-Type"),
        timeout: request.timeoutInterval,
        body: request.httpBody,
        maximumResponseBytes: maximumResponseBytes
      )
    )
    guard !outcomes.isEmpty else {
      throw RelayHTTPTransportError.invalidResponse
    }
    switch outcomes.removeFirst() {
    case .response(let status, let data):
      return RelayHTTPResponse(statusCode: status, body: data)
    case .error(let error):
      throw error
    }
  }

  func recordedRequests() -> [RecordedRelayRequest] {
    requests
  }
}

private func makeProfile() throws -> RelayProfile {
  try RelayProfile(
    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
    name: "Primary Relay",
    baseURL: URL(string: "https://relay.example")!,
    instanceID: "relay_primary",
    mode: .selfHosted,
    capabilities: RelayCapabilities(
      realtime: false,
      persistentSnapshots: true,
      instantDeviceRevocation: true,
      history: false,
      multiTenant: false
    )
  )
}

private func discovery(instanceID: String) -> Data {
  Data(
    #"{"instance_id":"\#(instanceID)","mode":"self_hosted","version":"0.0.1","api_versions":[1],"auth_methods":["bearer"],"capabilities":{"realtime":false,"persistent_snapshots":true,"instant_device_revocation":true,"history":false,"multi_tenant":false}}"#.utf8
  )
}

private func jsonObject(_ data: Data?) throws -> [String: String] {
  let data = try #require(data)
  return try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
}

private let ownerBearer = "owner_synthetic_0123456789"
private let supportedDiscovery = discovery(instanceID: "relay_primary")
private let sensitiveServerBody = Data(
  #"{"error":{"message":"upstream_secret owner_synthetic_0123456789 ABCD-EFGH account_01 alice@example.com"}}"#.utf8
)
