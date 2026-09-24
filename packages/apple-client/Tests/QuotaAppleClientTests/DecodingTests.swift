import Foundation
import QuotaWire
import Testing

struct DecodingTests {
  /// A marker stated as `false` is a malformed value rather than a member this build has not
  /// heard of, so it is refused. (An unknown provider id is the fixture's case.)
  @Test
  func aFalseTruncationMarkerIsRefused() throws {
    var cost = Fixtures.completeCost()
    cost["unpriced_truncated"] = false
    let falseMarker = try Fixtures.accountSummaryJSON(
      usage: Fixtures.accountUsage(today: Fixtures.usagePeriod(cost: cost))
    )
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(AccountSummary.self, from: falseMarker)
    }
  }

  /// A session either names the Device it speaks for, at the generation it was opened at, or
  /// names none; half an answer is not one. A token that is not an iOS token is not this app's.
  @Test
  func aTokenResponseWithAForeignPrefixOrHalfADeviceIsRefused() throws {
    let data = try Fixtures.tokenResponse(
      access: "qa_not_an_ios_access",
      refresh: "qar_not_an_ios_refresh"
    )
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(IosOAuthTokenResponse.self, from: data)
    }

    let device = try WireCodec.decode(
      IosOAuthTokenResponse.self,
      from: try Fixtures.tokenResponse(extra: ["device_id": "device_01", "device_generation": 2])
    )
    #expect(device.deviceID == "device_01")
    #expect(device.deviceGeneration == 2)
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(
        IosOAuthTokenResponse.self,
        from: try Fixtures.tokenResponse(extra: ["device_id": "device_01"])
      )
    }
  }

  @Test
  func aWindowCarriesPrimaryCadenceAndAnUnknownMemberDoesNotThrow() throws {
    let known = try WireCodec.decode(
      QuotaWindow.self,
      from: try JSONSerialization.data(withJSONObject: [
        "id": "five_hour",
        "title": "5 Hours",
        "used_percent": 40.0,
        "primary_cadence": "five_hour",
      ])
    )
    #expect(known.primaryCadence == .fiveHour)

    let unknown = try WireCodec.decode(
      QuotaWindow.self,
      from: try JSONSerialization.data(withJSONObject: [
        "id": "weekly",
        "title": "Weekly",
        "used_percent": 29.0,
        "primary_cadence": "yearly",
      ])
    )
    #expect(unknown.primaryCadence == .unknown)
  }

  @Test
  func primaryCadenceWindowsAreShortestFirstAndSkipUnmarked() {
    let account = QuotaAccount(fingerprint: "fp", fingerprintScope: .global)
    let observedAt = Date(timeIntervalSince1970: 1_786_300_000)
    let snapshot = QuotaSnapshot(
      provider: .claude,
      account: account,
      windows: [
        QuotaWindow(id: "seven_day_sonnet", title: "Sonnet Weekly", usedPercent: 95),
        QuotaWindow(id: "future", title: "Yearly", usedPercent: 5, primaryCadence: .unknown),
        QuotaWindow(
          id: "seven_day",
          title: "Weekly",
          usedPercent: 73,
          primaryCadence: .weekly
        ),
        QuotaWindow(
          id: "five_hour",
          title: "5 Hours",
          usedPercent: 40,
          primaryCadence: .fiveHour
        ),
        QuotaWindow(
          id: "monthly",
          title: "Monthly",
          usedPercent: 10,
          primaryCadence: .monthly
        ),
        QuotaWindow(
          id: "balance",
          title: "Balance",
          usedPercent: 0,
          remainingValue: 3.75,
          valueUnit: .usd,
          primaryCadence: .weekly
        ),
        QuotaWindow(
          id: "also_weekly",
          title: "Weekly",
          usedPercent: 90,
          primaryCadence: .weekly
        ),
      ],
      status: .available,
      observedAt: observedAt
    )

    #expect(snapshot.primaryCadenceWindows.map(\.id) == ["five_hour", "seven_day", "monthly"])
  }

  /// The agent tree, a null `agents`, and a rhythm with both halves are the fixture's cases.
  /// What it does not state: this read checks its own version, and a rhythm is both halves or
  /// neither.
  @Test
  func anActivityReadAtARetiredVersionOrWithHalfItsRhythmIsRefused() throws {
    var root = try JSONSerialization.jsonObject(
      with: try Fixtures.usageActivityJSON(days: [Fixtures.usageActivityDay()])
    ) as! [String: Any]
    root["protocol_version"] = 5
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(
        AccountUsageActivityResponse.self,
        from: try JSONSerialization.data(withJSONObject: root)
      )
    }

    root["protocol_version"] = 6
    root["hours_of_day"] = (0..<24).map {
      ["hour": $0, "total_tokens": 0, "cost_microusd": NSNull()] as [String: Any]
    }
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(
        AccountUsageActivityResponse.self,
        from: try JSONSerialization.data(withJSONObject: root)
      )
    }
  }

  /// The Account read that names the channels reaching an Account, read tolerantly: this app
  /// takes `identities[]` and ignores the account beside it, which it already holds from the
  /// summary
  /// ([ADR 0023](../../../../docs/decisions/0023-strict-writes-tolerant-reads.md)).
  @Test func accountIdentitiesAreReadTolerantly() throws {
    let both = try WireCodec.decode(
      AccountIdentitiesResponse.self,
      from: try Fixtures.accountIdentitiesJSON()
    )
    #expect(both.identities.map(\.provider) == [.github, .apple])
    #expect(both.identities[1].label == nil)

    // A channel a newer Relay offers is a member this build cannot name, not a broken payload.
    let newer = try WireCodec.decode(
      AccountIdentitiesResponse.self,
      from: try Fixtures.accountIdentitiesJSON(identities: [
        ["provider": "carrier-pigeon", "label": NSNull(), "linked_at": "2026-01-04T12:00:00Z"]
      ])
    )
    #expect(newer.identities.map(\.provider) == [.unknown])

    // A field beside the ones this read names is ignored, including one Relay does not send.
    let extra = try WireCodec.decode(
      AccountIdentitiesResponse.self,
      from: try Fixtures.accountIdentitiesJSON(
        identities: [
          [
            "provider": "github", "label": "octocat", "linked_at": "2026-01-04T12:00:00Z",
            "subject": "5b2c9f0a",
          ]
        ],
        extraRoot: ["generated_at": "2026-08-24T09:05:00Z"]
      )
    )
    #expect(extra.identities.map(\.provider) == [.github])

    // An Account always keeps at least one way to sign in to it, so no channels at all is not
    // an Account this build can show a Sign-in methods group for.
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(
        AccountIdentitiesResponse.self,
        from: try Fixtures.accountIdentitiesJSON(identities: [])
      )
    }

    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(
        AccountIdentitiesResponse.self,
        from: try Fixtures.accountIdentitiesJSON(extraRoot: ["protocol_version": 1])
      )
    }
  }
}
