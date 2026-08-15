import Foundation
import QuotaWire
import Testing

struct DecodingTests {
  @Test
  func deviceHealthOptInRequiresNullableKeyAndStrictBoundedPayload() throws {
    let data = try Fixtures.accountSummaryJSON(
      devices: [Fixtures.accountDevice(health: Fixtures.deviceHealth())]
    )
    let summary = try WireCodec.decode(AccountSummary.self, from: data)
    #expect(summary.devices.first?.health?.refreshRevision == 42)
    #expect(summary.devices.first?.health?.clientVersion == "0.0.16")

    let nullHealth = try Fixtures.accountSummaryJSON(devices: [Fixtures.accountDevice()])
    #expect(try WireCodec.decode(AccountSummary.self, from: nullHealth).devices.first?.health == nil)

    var missing = Fixtures.accountDevice()
    missing.removeValue(forKey: "health")
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(
        AccountSummary.self,
        from: Fixtures.accountSummaryJSON(devices: [missing])
      )
    }

    var unsafe = Fixtures.deviceHealth()
    unsafe["client_version"] = "0.0.16 /Users/private"
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(
        AccountSummary.self,
        from: Fixtures.accountSummaryJSON(devices: [Fixtures.accountDevice(health: unsafe)])
      )
    }
  }

  @Test
  func decodesAccountSummaryAndRejectsUnknownFields() throws {
    let data = try Fixtures.accountSummaryJSON(quota: [Fixtures.quotaObservation()])
    let summary = try WireCodec.decode(AccountSummary.self, from: data)
    #expect(summary.protocolVersion == 3)
    #expect(summary.account.displayLabel == "octocat")
    #expect(summary.quota.first?.snapshot.provider == .codex)
    #expect(summary.quota.first?.snapshot.windows.first?.remainingPercent == 71)
    #expect(summary.usage.cost.amountMicrousd == "3138")

    var extra = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    extra["unexpected"] = true
    let extraData = try JSONSerialization.data(withJSONObject: extra)
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(AccountSummary.self, from: extraData)
    }

    var nestedObject = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    var nestedUsage = nestedObject["usage"] as! [String: Any]
    nestedUsage["extra"] = true
    nestedObject["usage"] = nestedUsage
    let nested = try JSONSerialization.data(withJSONObject: nestedObject)
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(AccountSummary.self, from: nested)
    }
  }

  @Test
  func rejectsFalseTruncationMarkersAndUnknownProviders() throws {
    let falseMarker = try Fixtures.accountSummaryJSON(extraUsage: ["coverage_truncated": false])
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(AccountSummary.self, from: falseMarker)
    }

    var snapshot = Fixtures.quotaObservation()
    var nested = snapshot["snapshot"] as! [String: Any]
    nested["provider"] = "not_a_provider"
    snapshot["snapshot"] = nested
    let unknownProvider = try Fixtures.accountSummaryJSON(quota: [snapshot])
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(AccountSummary.self, from: unknownProvider)
    }
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
  func decodesOptInClientsAndRejectsDeviceFieldsOnIOSTokens() throws {
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
        "clients": [
          [
            "client": "codex",
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
    #expect(summary.usage.clients?.first?.providers.first?.models.first?.model == "gpt-5.6-sol")

    let tokens = try Fixtures.tokenResponse(extra: ["device_id": "device_01"])
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(IosOAuthTokenResponse.self, from: tokens)
    }

    let deviceRefresh = try Fixtures.refreshResponse(extra: [
      "device_session": [
        "access_token": Fixtures.accessToken,
        "access_expires_at": "2026-08-14T12:15:00Z",
        "refresh_token": Fixtures.refreshToken,
        "refresh_expires_at": "2026-11-01T12:00:00Z",
      ]
    ])
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(AccountSessionRefreshResponse.self, from: deviceRefresh)
    }

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
