import Foundation
import QuotaWire
import Testing

struct DecodingTests {
  /// A read is what a client is handed, and the Relay handing it can be newer than this build.
  /// A key this build does not name — one added since, or one the contract retired — is ignored,
  /// and the reading it arrived with still lands. See
  /// [ADR 0023](../../../../docs/decisions/0023-strict-writes-tolerant-reads.md).
  @Test
  func aReadKeepsWhatItNamesAndIgnoresTheRest() throws {
    var device = Fixtures.accountDevice()
    device["health"] = NSNull()
    var observation = Fixtures.quotaObservation()
    var snapshot = observation["snapshot"] as! [String: Any]
    snapshot["valid_until"] = "2026-12-31T00:00:00Z"
    observation["snapshot"] = snapshot
    let data = try Fixtures.accountSummaryJSON(quota: [observation], devices: [device])

    var root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    root["generated_at"] = "2026-08-24T09:05:00Z"
    var usage = root["usage"] as! [String: Any]
    usage["settled_at"] = "2026-08-24T09:05:00Z"
    root["usage"] = usage
    let tolerated = try WireCodec.decode(
      AccountSummary.self,
      from: try JSONSerialization.data(withJSONObject: root)
    )

    #expect(tolerated.devices.first?.deviceID == Fixtures.accountDevice()["device_id"] as? String)
    #expect(tolerated.quota.first?.snapshot.provider == .codex)
  }

  @Test
  func decodesAccountSummary() throws {
    let data = try Fixtures.accountSummaryJSON(quota: [Fixtures.quotaObservation()])
    let summary = try WireCodec.decode(AccountSummary.self, from: data)
    #expect(summary.protocolVersion == WireCodec.managedDataProtocolVersion)
    #expect(summary.account.displayLabel == "octocat")
    #expect(summary.quota.first?.snapshot.provider == .codex)
    #expect(summary.quota.first?.snapshot.windows.first?.usedPercent == 29)
    #expect(summary.usage.cost.amountMicrousd == "3138")
  }

  /// A marker stated as `false` is a malformed value rather than a member this build has not
  /// heard of, so it is still refused. A provider id outside this build's catalog is the other
  /// case: it reads as itself and is shown as the text it arrived as.
  @Test
  func rejectsFalseTruncationMarkersAndReadsUnknownProviders() throws {
    let falseMarker = try Fixtures.accountSummaryJSON(extraUsage: ["breakdowns_truncated": false])
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(AccountSummary.self, from: falseMarker)
    }

    var snapshot = Fixtures.quotaObservation()
    var nested = snapshot["snapshot"] as! [String: Any]
    nested["provider"] = "a_provider_from_2027"
    snapshot["snapshot"] = nested
    let unknownProvider = try Fixtures.accountSummaryJSON(quota: [snapshot])
    let summary = try WireCodec.decode(AccountSummary.self, from: unknownProvider)
    #expect(summary.quota.first?.snapshot.provider == .unknown("a_provider_from_2027"))
    #expect(summary.quota.first?.snapshot.provider.displayName == "a_provider_from_2027")
    #expect(!ProviderID.allCases.contains(.unknown("a_provider_from_2027")))
    #expect(summary.quota.first?.snapshot.windows.first?.usedPercent == 29)
  }

  @Test
  func acceptsCurrentManagedDataAndRejectsReleasedV2Summary() throws {
    var cursor = Fixtures.quotaObservation()
    var snapshot = cursor["snapshot"] as! [String: Any]
    snapshot["provider"] = "cursor"
    cursor["snapshot"] = snapshot
    let current = try Fixtures.accountSummaryJSON(quota: [cursor])
    let summary = try WireCodec.decode(AccountSummary.self, from: current)
    #expect(summary.quota.first?.snapshot.provider == .cursor)

    var releasedV2 = try JSONSerialization.jsonObject(with: current) as! [String: Any]
    releasedV2["protocol_version"] = 2
    let releasedV2Data = try JSONSerialization.data(withJSONObject: releasedV2)
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(AccountSummary.self, from: releasedV2Data)
    }
  }

  @Test
  func decodesAgentGroupsAndIgnoresFieldsMeantForAnotherClient() throws {
    let structured: [String: Any] = [
      "total_tokens": 1200,
      "input_tokens": 1000,
      "output_tokens": 200,
      "cache_read_input_tokens": 100,
      "cache_write_input_tokens": 0,
      "reasoning_tokens": 50,
      "messages": 1,
    ]
    let cost = Fixtures.completeCost()
    let data = try Fixtures.accountSummaryJSON(
      extraUsage: [
        "model_catalog_revision": "catalog_1",
        "agents": [
          [
            "agent": "codex",
            "totals": structured,
            "cost": cost,
            "providers": [
              [
                "provider": "openai",
                "totals": structured,
                "cost": cost,
                "models": [
                  [
                    "model": "gpt-5.6-sol",
                    "totals": structured,
                    "cost": cost,
                  ]
                ],
              ]
            ],
          ]
        ],
      ]
    )
    let summary = try WireCodec.decode(AccountSummary.self, from: data)
    #expect(summary.usage.agents?.first?.providers.first?.models.first?.model == "gpt-5.6-sol")

    // A response shaped for a different client carries keys this one does not read. It reads
    // the session it came for and leaves the rest alone.
    let tokens = try Fixtures.tokenResponse(extra: ["device_id": "device_01"])
    #expect(try WireCodec.decode(IosOAuthTokenResponse.self, from: tokens).accountSession
      .accessToken.hasPrefix("qia_"))

    let deviceRefresh = try Fixtures.refreshResponse(extra: [
      "device_session": [
        "access_token": Fixtures.accessToken,
        "access_expires_at": "2026-08-14T12:15:00Z",
        "refresh_token": Fixtures.refreshToken,
        "refresh_expires_at": "2026-11-01T12:00:00Z",
      ]
    ])
    #expect(try WireCodec.decode(AccountSessionRefreshResponse.self, from: deviceRefresh)
      .accountSession.accessToken.hasPrefix("qia_"))

    let validTokens = try WireCodec.decode(
      IosOAuthTokenResponse.self,
      from: try Fixtures.tokenResponse()
    )
    #expect(validTokens.accountSession.accessToken.hasPrefix("qia_"))
    #expect(validTokens.accountSession.refreshToken.hasPrefix("qiar_"))
  }

  @Test
  func rejectsIOSTokensWithoutRequiredPrefixes() throws {
    let data = try Fixtures.tokenResponse(
      access: "qa_not_an_ios_access",
      refresh: "qar_not_an_ios_refresh"
    )
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(IosOAuthTokenResponse.self, from: data)
    }
  }
}
