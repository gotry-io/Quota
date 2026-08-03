#if DEBUG
  import Foundation
  import Testing

  @testable import QuotaBar

  @Test
  func visualTestConfigurationDefaultsAndRejectsInvalidArguments() throws {
    let defaults = try #require(VisualTestConfiguration(arguments: ["QuotaBar"]))
    #expect(defaults.dataSource == .fixture)
    #expect(defaults.fixture == .content)
    #expect(defaults.route == .overview)
    #expect(defaults.appearance == .system)
    #expect(defaults.textSize == .standard)
    #expect(defaults.performsInitialRefresh == false)
    #expect(defaults.screenshotOutputPath == nil)

    #expect(
      VisualTestConfiguration(arguments: ["QuotaBar", "--fixture", "unknown"]) == nil
    )
    #expect(
      VisualTestConfiguration(arguments: ["QuotaBar", "--data-source", "unknown"]) == nil
    )
    #expect(VisualTestConfiguration(arguments: ["QuotaBar", "--route"]) == nil)
    #expect(VisualTestConfiguration(arguments: ["QuotaBar", "--screenshot-output"]) == nil)
    #expect(
      VisualTestConfiguration(
        arguments: ["QuotaBar", "--screenshot-output", "relative/path.png"]
      ) == nil
    )
    #expect(
      VisualTestConfiguration(arguments: ["QuotaBar", "--screenshot-output", ""]) == nil
    )

    let withScreenshot = try #require(
      VisualTestConfiguration(
        arguments: ["QuotaBar", "--screenshot-output", "/tmp/quotabar-visual.png"]
      )
    )
    #expect(withScreenshot.screenshotOutputPath?.path == "/tmp/quotabar-visual.png")
  }

  @Test
  func liveDataSourceEnablesOnlyLocalViewDrivenRefresh() throws {
    let configuration = try #require(
      VisualTestConfiguration(
        arguments: ["QuotaBar", "--data-source", "live", "--route", "settings"]
      )
    )

    #expect(configuration.dataSource == .live)
    #expect(configuration.initialPath == [.settings])
    #expect(configuration.performsInitialRefresh)
    #expect(!configuration.performsRelayRefreshes)
  }

  @Test @MainActor
  func liveDataSourceDoesNotInjectRelayFixturesOrCredentials() throws {
    let configuration = try #require(
      VisualTestConfiguration(arguments: ["QuotaBar", "--data-source", "live"])
    )
    let menuModel = configuration.makeModel()
    let relayModel = menuModel.relayStateModel

    #expect(relayModel.profiles.isEmpty)
    #expect(!relayModel.isPolling)
  }

  @Test
  func relayVisualRoutesParseIntoOneTypedStackWithMatchingTitles() throws {
    let routeExpectations: [(rawValue: String, title: String, depth: Int)] = [
      ("relays", "Relays", 2),
      ("add", "Add Relay", 3),
      ("detail", "Relay", 3),
      ("pairing", "Pair device", 4),
      ("devices", "Devices", 4),
    ]

    for expectation in routeExpectations {
      let configuration = try #require(
        VisualTestConfiguration(
          arguments: ["QuotaBar", "--route", expectation.rawValue]
        )
      )
      #expect(configuration.initialPath.count == expectation.depth)
      #expect(configuration.initialPath.first == .settings)
      #expect(configuration.initialPath.last?.title == expectation.title)
      #expect(!configuration.performsInitialRefresh)
      #expect(!configuration.performsRelayRefreshes)
    }
  }

  @Test @MainActor
  func contentFixtureCoversProvidersAccountsStalenessAndSettingsRoute() throws {
    let referenceDate = Date(timeIntervalSince1970: 1_754_112_000)
    let configuration = try #require(
      VisualTestConfiguration(
        arguments: [
          "QuotaBar", "--fixture", "content", "--route", "settings", "--appearance", "dark",
          "--text-size", "accessibility",
        ],
        referenceDate: referenceDate
      )
    )

    #expect(configuration.initialPath == [.settings])
    #expect(configuration.appearance == .dark)
    #expect(configuration.textSize == .accessibility)

    guard
      case .content(let providers, let warning) = configuration.makeModel().overviewState(
        enabledProviders: Set(ProviderID.allCases),
        now: referenceDate
      )
    else {
      Issue.record("Expected visual content.")
      return
    }
    #expect(warning == nil)
    #expect(providers.map(\.provider) == [.codex, .claude, .grok])
    #expect(providers.first?.accounts.map(\.isStale) == [false, true])
  }

  @Test @MainActor
  func visualFixturesCoverNonContentOverviewStates() throws {
    let referenceDate = Date(timeIntervalSince1970: 1_754_112_000)

    #expect(
      try configuration(fixture: .loading, referenceDate: referenceDate).makeModel()
        .overviewState(enabledProviders: Set(ProviderID.allCases), now: referenceDate) == .loading
    )

    guard
      case .content(_, let refreshWarning) = try configuration(
        fixture: .cachedRefreshError,
        referenceDate: referenceDate
      ).makeModel().overviewState(
        enabledProviders: Set(ProviderID.allCases),
        now: referenceDate
      )
    else {
      Issue.record("Expected cached content.")
      return
    }
    #expect(refreshWarning == "Refresh failed. Showing the last local report.")

    #expect(
      try configuration(fixture: .empty, referenceDate: referenceDate).makeModel()
        .overviewState(enabledProviders: Set(ProviderID.allCases), now: referenceDate)
        == .empty(refreshWarning: nil)
    )

    #expect(
      try configuration(fixture: .unavailable, referenceDate: referenceDate).makeModel()
        .overviewState(enabledProviders: Set(ProviderID.allCases), now: referenceDate)
        == .unavailable(message: "The bundled QuotaCLI helper could not be started.")
    )
  }

  @Test @MainActor
  func relayFixtureIsDeterministicSecretFreeAndDoesNotStartExternalWork() throws {
    let referenceDate = Date(timeIntervalSince1970: 1_785_752_430)
    let configuration = try #require(
      VisualTestConfiguration(
        arguments: ["QuotaBar", "--route", "devices"],
        referenceDate: referenceDate
      )
    )

    let menuModel = configuration.makeModel()
    let relayModel = menuModel.relayStateModel
    let profile = try #require(relayModel.profiles.first)
    let state = try #require(relayModel.state(for: profile.id))
    let accounts = menuModel.overviewState(
      enabledProviders: Set(ProviderID.allCases),
      now: referenceDate
    )
    let encodedProfiles = try QuotaWireCodec.makeEncoder().encode(relayModel.profiles)
    let encodedText = try #require(String(data: encodedProfiles, encoding: .utf8)).lowercased()

    #expect(profile.name == "Studio Relay")
    #expect(profile.baseURL.absoluteString == "https://relay.visual.example")
    #expect(state.observations.count == 2)
    #expect(state.devices.map(\.displayName) == ["Studio Mac", "Old build host"])
    #expect(state.lastSuccessfulRefreshAt == referenceDate.addingTimeInterval(-45))
    #expect(!relayModel.isPolling)
    #expect(!configuration.performsRelayRefreshes)
    #expect(!encodedText.contains("bearer"))
    #expect(!encodedText.contains("token"))
    #expect(!encodedText.contains("secret"))

    guard case .content(let providers, _) = accounts else {
      Issue.record("Expected local and remote visual quota content.")
      return
    }
    let summaries: [String: String] = Dictionary(
      uniqueKeysWithValues: providers.flatMap(\.accounts).map {
        ($0.identity.fingerprint, $0.sourceSummary)
      }
    )
    #expect(summaries["visual_personal"] == "Local + Remote")
    #expect(summaries["visual_remote_grok"] == "Remote")
  }

  private func configuration(
    fixture: VisualTestFixture,
    referenceDate: Date
  ) throws -> VisualTestConfiguration {
    try #require(
      VisualTestConfiguration(
        arguments: ["QuotaBar", "--fixture", fixture.rawValue],
        referenceDate: referenceDate
      )
    )
  }
#endif
