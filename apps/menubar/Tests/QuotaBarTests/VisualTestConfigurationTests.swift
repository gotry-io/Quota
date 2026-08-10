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
    #expect(!defaults.performsInitialRefresh)

    #expect(VisualTestConfiguration(arguments: ["QuotaBar", "--fixture", "unknown"]) == nil)
    #expect(VisualTestConfiguration(arguments: ["QuotaBar", "--data-source", "unknown"]) == nil)
    #expect(VisualTestConfiguration(arguments: ["QuotaBar", "--route"]) == nil)
  }

  @Test
  func liveDataSourceEnablesViewDrivenSync() throws {
    let configuration = try #require(
      VisualTestConfiguration(
        arguments: ["QuotaBar", "--data-source", "live", "--route", "settings"]
      )
    )

    #expect(configuration.dataSource == .live)
    #expect(configuration.initialPath == [.settings])
    #expect(configuration.performsInitialRefresh)
  }

  @Test
  func detailVisualRoutesUseOneTypedNavigationStack() throws {
    let routeExpectations: [(rawValue: String, title: String, depth: Int)] = [
      ("agents", "Agents", 2),
      ("provider-codex", "Codex", 3),
      ("provider-openrouter", "OpenRouter", 3),
      ("devices", "Devices", 2),
      ("usage", "Usage", 2),
    ]

    for expectation in routeExpectations {
      let configuration = try #require(
        VisualTestConfiguration(arguments: ["QuotaBar", "--route", expectation.rawValue])
      )
      #expect(configuration.initialPath.count == expectation.depth)
      #expect(configuration.initialPath.first == .settings)
      #expect(configuration.initialPath.last?.title == expectation.title)
      #expect(!configuration.performsInitialRefresh)
    }
  }

  @Test @MainActor
  func contentFixtureCoversAccountDevicesUsageAndProviderSources() throws {
    let referenceDate = Date(timeIntervalSince1970: 1_785_752_430)
    let configuration = try #require(
      VisualTestConfiguration(
        arguments: [
          "QuotaBar", "--fixture", "content", "--route", "usage", "--appearance", "dark",
          "--text-size", "accessibility",
        ],
        referenceDate: referenceDate
      )
    )
    let model = configuration.makeModel()

    #expect(configuration.initialPath == [.settings, .usage])
    #expect(configuration.appearance == .dark)
    #expect(configuration.textSize == .accessibility)
    #expect(model.accountState == .signedIn)
    #expect(model.accountDisplayLabel == "octocat")
    #expect(model.accountSummary?.devices.map(\.displayName) == ["Studio Mac", "Travel Mac"])
    #expect(model.accountSummary?.usage.cost.status == .partial)
    #expect(model.accountSummary?.usage.coverage.count == 2)
    #expect(model.accountReportingProviders() == [.codex, .claude, .grok])
    #expect(
      model.reportingSources(for: .grok, now: referenceDate).first?.kind == .device
    )

    guard
      case .content(let providers, let warning) = model.overviewState(
        enabledProviders: ProviderID.allCases,
        now: referenceDate
      )
    else {
      Issue.record("Expected visual content.")
      return
    }
    #expect(warning == nil)
    #expect(providers.map(\.provider) == [.codex, .claude, .grok])
    #expect(providers.flatMap(\.accounts).allSatisfy { $0.sourceSummary == "Device" })

    let encoded = try QuotaWireCodec.makeEncoder().encode(model.accountSummary)
    let encodedText = String(decoding: encoded, as: UTF8.self).lowercased()
    #expect(!encodedText.contains("bearer"))
    #expect(!encodedText.contains("token_secret"))
    #expect(!encodedText.contains("refresh_token"))
  }

  @Test @MainActor
  func visualFixturesCoverNonContentOverviewStates() throws {
    let referenceDate = Date(timeIntervalSince1970: 1_785_752_430)

    #expect(
      try configuration(fixture: .loading, referenceDate: referenceDate).makeModel()
        .overviewState(enabledProviders: ProviderID.allCases, now: referenceDate) == .loading
    )

    guard
      case .content(_, let refreshWarning) = try configuration(
        fixture: .cachedRefreshError,
        referenceDate: referenceDate
      ).makeModel().overviewState(
        enabledProviders: ProviderID.allCases,
        now: referenceDate
      )
    else {
      Issue.record("Expected cached content.")
      return
    }
    #expect(refreshWarning == "Sync failed. Showing the last known result.")

    let signedOutModel = try configuration(fixture: .empty, referenceDate: referenceDate)
      .makeModel()
    #expect(signedOutModel.accountState == .signedOut)
    guard
      case .content(let emptyProviders, let emptyWarning) = signedOutModel.overviewState(
        enabledProviders: ProviderID.allCases,
        now: referenceDate
      )
    else {
      Issue.record("Expected provider issue rows for the signed-out fixture.")
      return
    }
    #expect(emptyWarning == nil)
    #expect(emptyProviders.map(\.provider) == [.codex, .claude, .grok])
    #expect(emptyProviders.allSatisfy { $0.accounts.isEmpty })

    #expect(
      try configuration(fixture: .unavailable, referenceDate: referenceDate).makeModel()
        .overviewState(enabledProviders: ProviderID.allCases, now: referenceDate)
        == .unavailable(message: "The bundled QuotaCLI helper could not be started.")
    )
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
