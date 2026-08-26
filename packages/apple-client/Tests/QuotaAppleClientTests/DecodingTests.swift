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
    var subscription = Fixtures.quotaSubscription()
    var snapshot = subscription["snapshot"] as! [String: Any]
    snapshot["valid_until"] = "2026-12-31T00:00:00Z"
    subscription["snapshot"] = snapshot
    let data = try Fixtures.accountSummaryJSON(
      subscriptions: [subscription],
      devices: [device]
    )

    var root = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    root["generated_at"] = "2026-08-24T09:05:00Z"
    var usage = root["usage"] as! [String: Any]
    usage["settled_at"] = "2026-08-24T09:05:00Z"
    root["usage"] = usage
    let tolerated = try WireCodec.decode(
      AccountSummary.self,
      from: try JSONSerialization.data(withJSONObject: root)
    )

    #expect(tolerated.devices.first?.id == Fixtures.accountDevice()["id"] as? String)
    #expect(tolerated.subscriptions.first?.snapshot.provider == .codex)
  }

  @Test
  func decodesAccountSummary() throws {
    let data = try Fixtures.accountSummaryJSON(subscriptions: [Fixtures.quotaSubscription()])
    let summary = try WireCodec.decode(AccountSummary.self, from: data)
    #expect(summary.protocolVersion == WireCodec.managedDataProtocolVersion)
    #expect(summary.account.displayLabel == "octocat")
    #expect(summary.subscriptions.first?.key == "codex|fp_codex_01|global|")
    #expect(summary.subscriptions.first?.snapshot.provider == .codex)
    #expect(summary.subscriptions.first?.snapshot.windows.first?.usedPercent == 29)
    #expect(summary.subscriptions.first?.sources.first?.deviceID == "device_01")
    #expect(summary.usage.today.cost.amountMicrousd == "3138")
    #expect(summary.devices.isEmpty)
  }

  /// A marker stated as `false` is a malformed value rather than a member this build has not
  /// heard of, so it is still refused. A provider id outside this build's catalog is the other
  /// case: it reads as itself and is shown as the text it arrived as.
  @Test
  func rejectsFalseTruncationMarkersAndReadsUnknownProviders() throws {
    var cost = Fixtures.completeCost()
    cost["unpriced_truncated"] = false
    let falseMarker = try Fixtures.accountSummaryJSON(
      usage: Fixtures.accountUsage(today: Fixtures.usagePeriod(cost: cost))
    )
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(AccountSummary.self, from: falseMarker)
    }

    var subscription = Fixtures.quotaSubscription()
    var nested = subscription["snapshot"] as! [String: Any]
    nested["provider"] = "a_provider_from_2027"
    subscription["snapshot"] = nested
    subscription["provider"] = "a_provider_from_2027"
    let unknownProvider = try Fixtures.accountSummaryJSON(subscriptions: [subscription])
    let summary = try WireCodec.decode(AccountSummary.self, from: unknownProvider)
    #expect(summary.subscriptions.first?.snapshot.provider == .unknown("a_provider_from_2027"))
    #expect(
      summary.subscriptions.first?.snapshot.provider.displayName == "a_provider_from_2027")
    #expect(!ProviderID.allCases.contains(.unknown("a_provider_from_2027")))
    #expect(summary.subscriptions.first?.snapshot.windows.first?.usedPercent == 29)
  }

  @Test
  func acceptsCurrentManagedDataAndRejectsARetiredVersion() throws {
    var cursor = Fixtures.quotaSubscription()
    var snapshot = cursor["snapshot"] as! [String: Any]
    snapshot["provider"] = "cursor"
    cursor["snapshot"] = snapshot
    cursor["provider"] = "cursor"
    let current = try Fixtures.accountSummaryJSON(subscriptions: [cursor])
    let summary = try WireCodec.decode(AccountSummary.self, from: current)
    #expect(summary.subscriptions.first?.snapshot.provider == .cursor)

    var retired = try JSONSerialization.jsonObject(with: current) as! [String: Any]
    retired["protocol_version"] = 5
    let retiredData = try JSONSerialization.data(withJSONObject: retired)
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(AccountSummary.self, from: retiredData)
    }
  }

  @Test
  func decodesAgentGroupsAndIgnoresFieldsMeantForAnotherClient() throws {
    let totals: [String: Any] = [
      "total_tokens": 1200,
      "input_tokens": 1000,
      "output_tokens": 200,
      "cache_read_input_tokens": 100,
      "cache_write_input_tokens": 0,
      "reasoning_tokens": 50,
      "messages": 1,
    ]
    let agents: [[String: Any]] = [
      [
        "agent": "codex",
        "providers": [
          [
            "provider": "openai",
            "models": [["model": "gpt-5.6-sol", "totals": totals, "cost": Fixtures.completeCost()]],
          ]
        ],
      ]
    ]
    let data = try Fixtures.accountSummaryJSON(
      usage: Fixtures.accountUsage(today: Fixtures.usagePeriod(agents: agents))
    )
    let summary = try WireCodec.decode(AccountSummary.self, from: data)
    #expect(
      summary.usage.today.agents.first?.providers.first?.models.first?.model == "gpt-5.6-sol")
    #expect(summary.usage.last7Days.agents.isEmpty)

    // A response shaped for a different client carries keys this one does not read. It reads
    // the session it came for and leaves the rest alone.
    let tokens = try Fixtures.tokenResponse(extra: ["device_id": "device_01"])
    #expect(try WireCodec.decode(IosOAuthTokenResponse.self, from: tokens).session
      .accessToken.hasPrefix("qia_"))

    let widerRefresh = try Fixtures.refreshResponse(extra: [
      "device_id": "device_01",
      "device_generation": 3,
    ])
    #expect(try WireCodec.decode(SessionRefreshResponse.self, from: widerRefresh)
      .session.accessToken.hasPrefix("qia_"))

    let validTokens = try WireCodec.decode(
      IosOAuthTokenResponse.self,
      from: try Fixtures.tokenResponse()
    )
    #expect(validTokens.session.accessToken.hasPrefix("qia_"))
    #expect(validTokens.session.refreshToken.hasPrefix("qiar_"))
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
