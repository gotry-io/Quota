#if DEBUG
  import SwiftUI

  enum VisualTestDataSource: String {
    case fixture
    case live
  }

  enum VisualTestFixture: String {
    case loading
    case content
    case cachedRefreshError = "cached-refresh-error"
    case empty
    case unavailable

    @MainActor
    fileprivate func makeModel(referenceDate: Date) -> MenuBarViewModel {
      let relayRefreshAt: Date? = switch self {
      case .loading, .unavailable: nil
      case .content, .cachedRefreshError, .empty:
        referenceDate.addingTimeInterval(-45)
      }
      let relayStateModel = VisualRelayFixture.makeStateModel(
        referenceDate: referenceDate,
        lastSuccessfulRefreshAt: relayRefreshAt,
        includesQuotaObservations: self == .content || self == .cachedRefreshError
      )
      return switch self {
      case .loading:
        MenuBarViewModel(
          visualTestReport: nil,
          errorMessage: nil,
          refreshedAt: nil,
          relayStateModel: relayStateModel
        )
      case .content, .cachedRefreshError:
        MenuBarViewModel(
          visualTestReport: contentReport(at: referenceDate),
          errorMessage: self == .cachedRefreshError
            ? "Refresh failed. Showing the last local report."
            : nil,
          refreshedAt: referenceDate.addingTimeInterval(
            self == .cachedRefreshError ? -180 : -30
          ),
          relayStateModel: relayStateModel
        )
      case .empty:
        MenuBarViewModel(
          visualTestReport: emptyReport(at: referenceDate),
          errorMessage: nil,
          refreshedAt: referenceDate.addingTimeInterval(-30),
          relayStateModel: relayStateModel
        )
      case .unavailable:
        MenuBarViewModel(
          visualTestReport: nil,
          errorMessage: "The bundled QuotaCLI helper could not be started.",
          refreshedAt: nil,
          relayStateModel: relayStateModel
        )
      }
    }
  }

  enum VisualTestRoute: String {
    case overview
    case settings
    case remoteDevices = "remote-devices"
    case pairDevice = "pair-device"

    fileprivate var path: [MenuBarRoute] {
      switch self {
      case .overview: []
      case .settings: [.settings]
      case .remoteDevices: [.settings, .remoteDevices]
      case .pairDevice: [.settings, .remoteDevices, .pairDevice]
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
    let dataSource: VisualTestDataSource
    let fixture: VisualTestFixture
    let route: VisualTestRoute
    let appearance: VisualTestAppearance
    let textSize: VisualTestTextSize
    /// Absolute file URL for an optional self-captured window PNG. `nil` means no screenshot.
    let screenshotOutputPath: URL?
    let referenceDate: Date

    init?(
      arguments: [String],
      referenceDate: Date = Date(timeIntervalSince1970: 1_785_752_430)
    ) {
      guard
        let dataSource: VisualTestDataSource = Self.argument(
          "--data-source",
          in: arguments,
          default: .fixture
        ),
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

      let parsedScreenshotOutput: URL?
      switch Self.absoluteScreenshotOutputPath(in: arguments) {
      case .absent:
        parsedScreenshotOutput = nil
      case .value(let url):
        parsedScreenshotOutput = url
      case .invalid:
        return nil
      }

      self.dataSource = dataSource
      self.fixture = fixture
      self.route = route
      self.appearance = appearance
      self.textSize = textSize
      self.screenshotOutputPath = parsedScreenshotOutput
      self.referenceDate = referenceDate
    }

    var initialPath: [MenuBarRoute] { route.path }
    var colorScheme: ColorScheme? { appearance.colorScheme }
    var dynamicTypeSize: DynamicTypeSize { textSize.dynamicTypeSize }
    var performsInitialRefresh: Bool { dataSource == .live }
    var performsRelayRefreshes: Bool { false }

    @MainActor
    func makeModel() -> MenuBarViewModel {
      switch dataSource {
      case .fixture:
        fixture.makeModel(referenceDate: referenceDate)
      case .live:
        MenuBarViewModel(
          reportCache: nil,
          relayStateModel: RelayStateModel.visualFixture(profiles: [], profileStates: [:])
        )
      }
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

    private enum ScreenshotOutputArgument {
      case absent
      case value(URL)
      case invalid
    }

    /// Parses optional `--screenshot-output <absolute path>`.
    /// Absent means no screenshot. A missing value or relative path is invalid.
    private static func absoluteScreenshotOutputPath(
      in arguments: [String]
    ) -> ScreenshotOutputArgument {
      guard let index = arguments.firstIndex(of: "--screenshot-output") else {
        return .absent
      }
      let valueIndex = arguments.index(after: index)
      guard valueIndex < arguments.endIndex else { return .invalid }
      let path = arguments[valueIndex]
      guard !path.isEmpty, (path as NSString).isAbsolutePath else { return .invalid }
      return .value(URL(fileURLWithPath: path, isDirectory: false))
    }
  }

  private enum VisualRelayFixture {
    static let profileID = UUID(uuidString: "7A926551-3832-4E39-A931-695563D96541")!

    @MainActor
    static func makeStateModel(
      referenceDate: Date,
      lastSuccessfulRefreshAt: Date?,
      includesQuotaObservations: Bool
    ) -> RelayStateModel {
      do {
        let profile = try RelayProfile(
          id: profileID,
          name: "Quota Relay",
          baseURL: URL(string: "https://quota.gotry.io")!,
          instanceID: "visual-managed-relay-instance-01",
          mode: .managed,
          capabilities: RelayCapabilities(
            realtime: false,
            persistentSnapshots: true,
            instantDeviceRevocation: true,
            history: false,
            multiTenant: true
          )
        )
        let deviceResponse = try QuotaWireCodec.makeDecoder().decode(
          DeviceListResponse.self,
          from: Data(deviceJSON.utf8)
        )
        let observations = includesQuotaObservations
          ? try makeObservations(referenceDate: referenceDate)
          : []
        return RelayStateModel.visualFixture(
          profiles: [profile],
          profileStates: [
            profileID: RelayProfileState(
              observations: observations,
              devices: deviceResponse.devices,
              lastSuccessfulRefreshAt: lastSuccessfulRefreshAt
            )
          ]
        )
      } catch {
        preconditionFailure("Invalid visual Relay fixture.")
      }
    }

    private static func makeObservations(referenceDate: Date) throws
      -> [OwnerSnapshotObservation]
    {
      let snapshots = [
        snapshot(
          provider: .codex,
          fingerprint: "visual_personal",
          label: "pe***@example.com",
          plan: "Plus",
          windows: [
            window(
              id: "five_hour",
              title: "5 hour",
              usedPercent: 34,
              resetsAt: referenceDate.addingTimeInterval(2_700)
            )
          ],
          observedAt: referenceDate.addingTimeInterval(-120),
          validUntil: referenceDate.addingTimeInterval(300)
        ),
        snapshot(
          provider: .grok,
          fingerprint: "visual_remote_grok",
          label: "Remote workstation",
          plan: "SuperGrok",
          windows: [
            window(
              id: "monthly",
              title: "Monthly",
              usedPercent: 41,
              resetsAt: referenceDate.addingTimeInterval(9 * 86_400)
            )
          ],
          observedAt: referenceDate.addingTimeInterval(-60),
          validUntil: referenceDate.addingTimeInterval(300)
        ),
      ]
      let encoder = QuotaWireCodec.makeEncoder()
      let encodedSnapshots = try snapshots.map { snapshot in
        String(decoding: try encoder.encode(snapshot), as: UTF8.self)
      }
      let dateFormatter = ISO8601DateFormatter()
      let capturedAt = dateFormatter.string(from: referenceDate)
      let updatedAt = dateFormatter.string(from: referenceDate.addingTimeInterval(1))
      let responseJSON =
        #"{"observations":[{"device_id":"device_visual_studio_mac_01","sequence":42,"captured_at":"\#(capturedAt)","snapshot":\#(encodedSnapshots[0]),"updated_at":"\#(updatedAt)"},{"device_id":"device_visual_studio_mac_01","sequence":42,"captured_at":"\#(capturedAt)","snapshot":\#(encodedSnapshots[1]),"updated_at":"\#(updatedAt)"}]}"#
      return try QuotaWireCodec.makeDecoder()
        .decode(OwnerSnapshotListResponse.self, from: Data(responseJSON.utf8))
        .observations
    }

    private static let deviceJSON =
      #"""
      {
        "devices": [
          {
            "device_id": "device_visual_studio_mac_01",
            "display_name": "Studio Mac",
            "created_at": "2026-08-03T08:00:00Z",
            "last_seen_at": "2026-08-03T10:20:30Z",
            "last_sequence": 42,
            "revoked_at": null
          },
          {
            "device_id": "device_visual_build_host_02",
            "display_name": "Old build host",
            "created_at": "2026-07-20T08:00:00Z",
            "last_seen_at": "2026-07-31T18:15:00Z",
            "last_sequence": 18,
            "revoked_at": "2026-08-01T09:30:00Z"
          }
        ]
      }
      """#
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
      account: QuotaAccount(
        fingerprint: fingerprint,
        label: label,
        plan: plan,
        fingerprintScope: .global
      ),
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
