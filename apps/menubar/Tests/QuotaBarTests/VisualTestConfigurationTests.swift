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

    #expect(
      VisualTestConfiguration(arguments: ["QuotaBar", "--fixture", "unknown"]) == nil
    )
    #expect(
      VisualTestConfiguration(arguments: ["QuotaBar", "--data-source", "unknown"]) == nil
    )
    #expect(VisualTestConfiguration(arguments: ["QuotaBar", "--route"]) == nil)
  }

  @Test
  func liveDataSourceEnablesOneViewDrivenRefresh() throws {
    let configuration = try #require(
      VisualTestConfiguration(
        arguments: ["QuotaBar", "--data-source", "live", "--route", "settings"]
      )
    )

    #expect(configuration.dataSource == .live)
    #expect(configuration.initialPath == [.settings])
    #expect(configuration.performsInitialRefresh)
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
