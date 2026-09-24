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
    #expect(VisualTestConfiguration(arguments: ["QuotaBar", "--route", "settings"]) == nil)
    #expect(VisualTestConfiguration(arguments: ["QuotaBar", "--route", "dashboard"]) == nil)
    #expect(
      VisualTestConfiguration(arguments: ["QuotaBar", "--route", "settings-account"]) == nil
    )
  }
#endif
