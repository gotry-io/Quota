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

  /// The entitlement is part of the Account read, and its status is tolerant: a member added to
  /// the contract after this build shipped reads as `unknown`, which is not sync.
  @Test
  func decodesTheEntitlementAndReadsAnUnknownStatusAsNotSynced() throws {
    let summary = try WireCodec.decode(
      AccountSummary.self,
      from: try Fixtures.accountSummaryJSON()
    )
    #expect(summary.entitlement.status == .active)
    #expect(summary.entitlement.expiresAt == Fixtures.date("2026-09-14T12:00:00Z"))
    #expect(summary.entitlement.willRenew)
    #expect(summary.entitlement.productID == "quota_sync_monthly")
    #expect(summary.entitlement.store == "app_store")
    #expect(summary.entitlement.stale == false)
    #expect(summary.entitlement.status.allowsSync)

    let unbought = try WireCodec.decode(
      AccountSummary.self,
      from: try Fixtures.accountSummaryJSON(
        entitlement: Fixtures.entitlement(
          status: "none",
          expiresAt: nil,
          willRenew: false,
          productID: nil,
          store: nil
        )
      )
    )
    #expect(unbought.entitlement.status == .none)
    #expect(unbought.entitlement.status.allowsSync == false)

    let newer = try WireCodec.decode(
      AccountSummary.self,
      from: try Fixtures.accountSummaryJSON(
        entitlement: Fixtures.entitlement(status: "paused")
      )
    )
    #expect(newer.entitlement.status == .unknown)
    #expect(newer.entitlement.status.allowsSync == false)
  }

  @Test
  func aSummaryWithoutAnEntitlementIsRefused() throws {
    var root =
      try JSONSerialization.jsonObject(with: try Fixtures.accountSummaryJSON()) as! [String: Any]
    root.removeValue(forKey: "entitlement")
    #expect(
      throws: (any Error).self,
      performing: {
        try WireCodec.decode(
          AccountSummary.self,
          from: try JSONSerialization.data(withJSONObject: root)
        )
      })
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
    #expect(summary.subscriptions.first?.sources.first?.snapshot == nil)

    var withSnapshot = Fixtures.quotaSubscription()
    var sources = withSnapshot["sources"] as! [[String: Any]]
    sources[0]["snapshot"] = withSnapshot["snapshot"]
    withSnapshot["sources"] = sources
    let decodedSnapshot = try WireCodec.decode(
      AccountSummary.self,
      from: try Fixtures.accountSummaryJSON(subscriptions: [withSnapshot])
    )
    #expect(decodedSnapshot.subscriptions.first?.sources.first?.snapshot?.provider == .codex)
    #expect(
      decodedSnapshot.subscriptions.first?.sources.first?.snapshot?.account.fingerprint
        == "fp_codex_01"
    )

    var malformed = Fixtures.quotaSubscription()
    var malformedSources = malformed["sources"] as! [[String: Any]]
    malformedSources[0]["snapshot"] = ["provider": "codex"]
    malformed["sources"] = malformedSources
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(
        AccountSummary.self,
        from: try Fixtures.accountSummaryJSON(subscriptions: [malformed])
      )
    }
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
    // The id is kept, because the reading is worth keeping. It is not a name: the catalog is the
    // only place a provider is named, and this one is not in it.
    #expect(summary.subscriptions.first?.snapshot.provider.rawValue == "a_provider_from_2027")
    #expect(summary.subscriptions.first?.snapshot.provider.displayName == "Unknown provider")
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

    // A session either names the Device it speaks for, at the generation it was opened at, or
    // names none. Half an answer is not one.
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

    // Rotation answers the tokens; the Device the session speaks for is not restated, so keys
    // meant for another client are read past.
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
    // Signing in names the Account. A build talking to a Relay that does not say so yet, or to
    // an Account that kept no name, reads a session without one rather than refusing it.
    #expect(validTokens.displayLabel == nil)
    #expect(validTokens.deviceID == nil)
    #expect(
      try WireCodec.decode(
        IosOAuthTokenResponse.self,
        from: try Fixtures.tokenResponse(extra: ["display_label": "octocat"])
      ).displayLabel == "octocat")
    #expect(
      try WireCodec.decode(
        IosOAuthTokenResponse.self,
        from: try Fixtures.tokenResponse(extra: ["display_label": NSNull()])
      ).displayLabel == nil)
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

  @Test
  func decodesAnActivityDayWithAndWithoutItsAgentTree() throws {
    let totals = Fixtures.summaryTotals()
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
    let withoutAgents = try WireCodec.decode(
      AccountUsageActivityResponse.self,
      from: try Fixtures.usageActivityJSON(days: [Fixtures.usageActivityDay()])
    )
    #expect(withoutAgents.protocolVersion == WireCodec.managedDataProtocolVersion)
    #expect(withoutAgents.days.count == 1)
    #expect(withoutAgents.days.first?.date == "2026-08-10")
    #expect(withoutAgents.days.first?.agents == nil)

    let withAgents = try WireCodec.decode(
      AccountUsageActivityResponse.self,
      from: try Fixtures.usageActivityJSON(days: [
        Fixtures.usageActivityDay(agents: agents)
      ])
    )
    #expect(withAgents.days.first?.agents?.first?.agent == .codex)
    #expect(
      withAgents.days.first?.agents?.first?.providers.first?.models.first?.model == "gpt-5.6-sol")

    var extra = try JSONSerialization.jsonObject(
      with: try Fixtures.usageActivityJSON(days: [Fixtures.usageActivityDay()])
    ) as! [String: Any]
    extra["generated_at"] = "2026-08-24T09:05:00Z"
    let tolerated = try WireCodec.decode(
      AccountUsageActivityResponse.self,
      from: try JSONSerialization.data(withJSONObject: extra)
    )
    #expect(tolerated.days.first?.date == "2026-08-10")

    extra["protocol_version"] = 5
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(
        AccountUsageActivityResponse.self,
        from: try JSONSerialization.data(withJSONObject: extra)
      )
    }

    var nullAgents = Fixtures.usageActivityDay()
    nullAgents["agents"] = NSNull()
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(
        AccountUsageActivityResponse.self,
        from: try Fixtures.usageActivityJSON(days: [nullAgents])
      )
    }

    var withHours = try JSONSerialization.jsonObject(
      with: try Fixtures.usageActivityJSON(days: [Fixtures.usageActivityDay()])
    ) as! [String: Any]
    withHours["hours_of_day"] = (0..<24).map {
      ["hour": $0, "total_tokens": $0 == 14 ? 100 : 0, "cost_microusd": NSNull()] as [String: Any]
    }
    withHours["weekday_hours"] = (0..<7).map { weekday in
      (0..<24).map { hour in weekday == 1 && hour == 14 ? 100 : 0 }
    }
    let rhythm = try WireCodec.decode(
      AccountUsageActivityResponse.self,
      from: try JSONSerialization.data(withJSONObject: withHours)
    )
    #expect(rhythm.hoursOfDay?.count == 24)
    #expect(rhythm.hoursOfDay?[14].totalTokens == 100)
    #expect(rhythm.weekdayHours?[1][14] == 100)

    withHours.removeValue(forKey: "weekday_hours")
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(
        AccountUsageActivityResponse.self,
        from: try JSONSerialization.data(withJSONObject: withHours)
      )
    }
  }

  /// The Account read that names the channels reaching an Account, read tolerantly: this app
  /// takes `identities[]` and ignores the account, entitlement, and purchase beside it, which it
  /// already holds from the summary
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

  @Test func identityLinkStatusIsTolerant() throws {
    let linked = try WireCodec.decode(
      IdentityLinkResponse.self,
      from: try Fixtures.identityLinkJSON()
    )
    #expect(linked.provider == .apple)
    #expect(linked.status == .linked)

    let repeated = try WireCodec.decode(
      IdentityLinkResponse.self,
      from: try Fixtures.identityLinkJSON(status: "already_linked")
    )
    #expect(repeated.status == .alreadyLinked)

    let newer = try WireCodec.decode(
      IdentityLinkResponse.self,
      from: try Fixtures.identityLinkJSON(status: "rebound")
    )
    #expect(newer.status == .unknown)
  }
}
