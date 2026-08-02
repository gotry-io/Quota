#if DEBUG
  import SwiftUI

  enum VisualTestFixture: String {
    case loading
    case content
    case cachedRefreshError = "cached-refresh-error"
    case empty
    case unavailable

    @MainActor
    fileprivate func makeModel(referenceDate: Date) -> MenuBarViewModel {
      switch self {
      case .loading:
        MenuBarViewModel(
          visualTestReport: nil,
          errorMessage: nil,
          refreshedAt: nil
        )
      case .content, .cachedRefreshError:
        MenuBarViewModel(
          visualTestReport: contentReport(at: referenceDate),
          errorMessage: self == .cachedRefreshError
            ? "Refresh failed. Showing the last local report."
            : nil,
          refreshedAt: referenceDate.addingTimeInterval(
            self == .cachedRefreshError ? -180 : -30
          )
        )
      case .empty:
        MenuBarViewModel(
          visualTestReport: emptyReport(at: referenceDate),
          errorMessage: nil,
          refreshedAt: referenceDate.addingTimeInterval(-30)
        )
      case .unavailable:
        MenuBarViewModel(
          visualTestReport: nil,
          errorMessage: "The bundled QuotaCLI helper could not be started.",
          refreshedAt: nil
        )
      }
    }
  }

  enum VisualTestRoute: String {
    case overview
    case settings

    fileprivate var path: [MenuBarRoute] {
      switch self {
      case .overview: []
      case .settings: [.settings]
      }
    }
  }

  enum VisualTestAppearance: String {
    case system
    case light
    case dark

    fileprivate var colorScheme: ColorScheme? {
      switch self {
      case .system: nil
      case .light: .light
      case .dark: .dark
      }
    }
  }

  enum VisualTestTextSize: String {
    case standard
    case extraLarge = "extra-large"
    case accessibility

    fileprivate var dynamicTypeSize: DynamicTypeSize {
      switch self {
      case .standard: .large
      case .extraLarge: .xxxLarge
      case .accessibility: .accessibility3
      }
    }
  }

  struct VisualTestConfiguration {
    let fixture: VisualTestFixture
    let route: VisualTestRoute
    let appearance: VisualTestAppearance
    let textSize: VisualTestTextSize
    let referenceDate: Date

    init?(arguments: [String], referenceDate: Date = Date()) {
      guard
        let fixture: VisualTestFixture = Self.argument(
          "--fixture",
          in: arguments,
          default: .content
        ),
        let route: VisualTestRoute = Self.argument(
          "--route",
          in: arguments,
          default: .overview
        ),
        let appearance: VisualTestAppearance = Self.argument(
          "--appearance",
          in: arguments,
          default: .system
        ),
        let textSize: VisualTestTextSize = Self.argument(
          "--text-size",
          in: arguments,
          default: .standard
        )
      else {
        return nil
      }

      self.fixture = fixture
      self.route = route
      self.appearance = appearance
      self.textSize = textSize
      self.referenceDate = referenceDate
    }

    var initialPath: [MenuBarRoute] { route.path }
    var colorScheme: ColorScheme? { appearance.colorScheme }
    var dynamicTypeSize: DynamicTypeSize { textSize.dynamicTypeSize }

    @MainActor
    func makeModel() -> MenuBarViewModel {
      fixture.makeModel(referenceDate: referenceDate)
    }

    func prepareEnvironment() {
      for provider in ProviderID.allCases {
        UserDefaults.standard.set(true, forKey: "provider.\(provider.rawValue).visible")
      }
    }

    private static func argument<Value: RawRepresentable>(
      _ flag: String,
      in arguments: [String],
      default defaultValue: Value
    ) -> Value? where Value.RawValue == String {
      guard let index = arguments.firstIndex(of: flag) else { return defaultValue }
      let valueIndex = arguments.index(after: index)
      guard valueIndex < arguments.endIndex else { return nil }
      return Value(rawValue: arguments[valueIndex])
    }
  }

  private func contentReport(at date: Date) -> QuotaCollectionReport {
    QuotaCollectionReport(
      schemaVersion: 1,
      capturedAt: date,
      results: [
        successResult(
          provider: .codex,
          snapshots: [
            snapshot(
              provider: .codex,
              fingerprint: "visual_personal",
              label: "pe***@example.com",
              plan: "Plus",
              windows: [
                window(
                  id: "five_hour",
                  title: "5 hour",
                  usedPercent: 32,
                  resetsAt: date.addingTimeInterval(2_700)
                ),
                window(
                  id: "weekly",
                  title: "Weekly",
                  usedPercent: 16,
                  resetsAt: date.addingTimeInterval(4 * 86_400)
                ),
              ],
              observedAt: date.addingTimeInterval(-90),
              validUntil: date.addingTimeInterval(300)
            ),
            snapshot(
              provider: .codex,
              fingerprint: "visual_work",
              label: "wo***@example.com",
              plan: "Team",
              windows: [
                window(
                  id: "weekly",
                  title: "Weekly",
                  usedPercent: 66,
                  resetsAt: date.addingTimeInterval(2 * 86_400)
                )
              ],
              observedAt: date.addingTimeInterval(-150),
              validUntil: date.addingTimeInterval(-30)
            ),
          ]
        ),
        successResult(
          provider: .claude,
          snapshots: [
            snapshot(
              provider: .claude,
              fingerprint: "visual_claude",
              label: "Team workspace",
              plan: "Max",
              windows: [
                window(
                  id: "session",
                  title: "Session",
                  usedPercent: 47,
                  resetsAt: date.addingTimeInterval(7_200)
                )
              ],
              observedAt: date.addingTimeInterval(-120),
              validUntil: date.addingTimeInterval(300)
            )
          ]
        ),
        successResult(
          provider: .grok,
          snapshots: [
            snapshot(
              provider: .grok,
              fingerprint: "visual_grok",
              label: nil,
              plan: "SuperGrok",
              windows: [
                window(
                  id: "monthly",
                  title: "Monthly",
                  usedPercent: 73,
                  resetsAt: date.addingTimeInterval(12 * 86_400)
                )
              ],
              observedAt: date.addingTimeInterval(-180),
              validUntil: date.addingTimeInterval(300)
            )
          ]
        ),
      ]
    )
  }

  private func emptyReport(at date: Date) -> QuotaCollectionReport {
    QuotaCollectionReport(
      schemaVersion: 1,
      capturedAt: date,
      results: [
        failureResult(
          provider: .codex,
          outcome: .authRequired,
          message: "Run `codex` to sign in."
        ),
        failureResult(
          provider: .claude,
          outcome: .authRequired,
          message: "Run `claude auth login`."
        ),
        failureResult(
          provider: .grok,
          outcome: .unavailable,
          message: "Grok quota is temporarily unavailable."
        ),
      ]
    )
  }

  private func successResult(
    provider: ProviderID,
    snapshots: [QuotaSnapshot]
  ) -> QuotaCollectionResult {
    QuotaCollectionResult(
      provider: provider,
      outcome: .success,
      snapshots: snapshots,
      source: "visual_test_fixture",
      message: nil
    )
  }

  private func failureResult(
    provider: ProviderID,
    outcome: CollectionOutcome,
    message: String
  ) -> QuotaCollectionResult {
    QuotaCollectionResult(
      provider: provider,
      outcome: outcome,
      snapshots: [],
      source: nil,
      message: message
    )
  }

  private func snapshot(
    provider: ProviderID,
    fingerprint: String,
    label: String?,
    plan: String?,
    windows: [QuotaWindow],
    observedAt: Date,
    validUntil: Date?
  ) -> QuotaSnapshot {
    QuotaSnapshot(
      provider: provider,
      account: QuotaAccount(fingerprint: fingerprint, label: label, plan: plan),
      windows: windows,
      source: "visual_test_fixture",
      status: .available,
      observedAt: observedAt,
      validUntil: validUntil
    )
  }

  private func window(
    id: String,
    title: String,
    usedPercent: Double,
    resetsAt: Date?
  ) -> QuotaWindow {
    QuotaWindow(
      id: id,
      title: title,
      usedPercent: usedPercent,
      resetsAt: resetsAt,
      durationSeconds: nil
    )
  }
#endif
