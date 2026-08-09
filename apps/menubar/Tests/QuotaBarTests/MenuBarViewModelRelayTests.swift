import Foundation
import Testing

@testable import QuotaBar

@Suite
@MainActor
struct MenuBarViewModelRelayTests {
  @Test
  func suppressesLocalAuthStatusWhenRemoteAccountsArePresentable() async throws {
    let profile = try overviewProfile()
    let remoteSnapshot = overviewSnapshot(
      provider: .claude,
      fingerprint: "remote-claude",
      scope: .global,
      usedPercent: 42
    )
    let remoteObservations = OwnerSnapshotListResponse(observations: [
      try overviewObservation(deviceID: "device-a", snapshot: remoteSnapshot)
    ])
    let client = OverviewRelayClient(
      snapshotResults: [
        .success(remoteObservations),
        .success(remoteObservations),
      ]
    )
    let localAuthReport = QuotaCollectionReport(
      schemaVersion: 1,
      capturedAt: overviewNow,
      results: [
        QuotaCollectionResult(
          provider: .claude,
          outcome: .authRequired,
          snapshots: [],
          source: nil,
          message: "Claude OAuth credentials are missing. Run `claude auth login`."
        )
      ]
    )
    let model = MenuBarViewModel(
      collector: OverviewLocalCollector(report: localAuthReport),
      reportCache: nil,
      relayStateModel: makeOverviewRelayStateModel(profiles: [profile], client: client)
    )
    await model.refresh()

    guard case .content(let providers, _) = model.overviewState(
      enabledProviders: [.claude]
    ) else {
      Issue.record("Expected remote Claude quota without local auth chrome.")
      return
    }
    let provider = try #require(providers.first)
    #expect(provider.provider == .claude)
    #expect(provider.status == nil)
    #expect(provider.accounts.count == 1)
    #expect(provider.accounts.first?.sourceSummary == "Remote")
  }

  @Test
  func presentsRemoteQuotaBeforeALocalReportExists() async throws {
    let profile = try overviewProfile()
    let remoteSnapshot = overviewSnapshot(
      provider: .codex,
      fingerprint: "remote-account",
      scope: .global,
      usedPercent: 35
    )
    let client = OverviewRelayClient(
      snapshotResults: [
        .success(OwnerSnapshotListResponse(observations: [
          try overviewObservation(deviceID: "device-a", snapshot: remoteSnapshot)
        ]))
      ]
    )
    let relayModel = makeOverviewRelayStateModel(profiles: [profile], client: client)
    await relayModel.refreshAllProfiles()
    do {
      try await relayModel.approvePairing(profileID: profile.id, userCode: "ABCD-EFGH")
      Issue.record("Expected the synthetic pairing operation to fail.")
    } catch {
      // The operation issue must remain separate from refresh presentation.
    }
    let model = MenuBarViewModel(
      collector: OverviewLocalCollector(report: emptyOverviewReport),
      reportCache: nil,
      relayStateModel: relayModel
    )

    guard case .content(let providers, let warning) = model.overviewState(
      enabledProviders: [.codex]
    ) else {
      Issue.record("Expected remote-only quota content.")
      return
    }
    let account = try #require(providers.first?.accounts.first)

    #expect(model.report == nil)
    #expect(model.relayStateModel === relayModel)
    #expect(relayModel.state(for: profile.id)?.operationIssue != nil)
    #expect(warning == nil)
    #expect(account.selectedSource == .remote(
      relayInstanceID: profile.instanceID,
      deviceID: "device-a"
    ))
    #expect(account.sourceSummary == "Remote")
    #expect(account.snapshot.windows.first?.usedPercent == 35)
  }

  @Test
  func mergesLocalAndTwoRemoteGlobalObservationsWithoutAccumulatingQuota() async throws {
    let profile = try overviewProfile()
    let observedAt = overviewNow.addingTimeInterval(-10)
    let client = OverviewRelayClient(
      snapshotResults: [
        .success(OwnerSnapshotListResponse(observations: [
          try overviewObservation(
            deviceID: "device-a",
            snapshot: overviewSnapshot(
              fingerprint: "shared-account",
              scope: .global,
              usedPercent: 60,
              observedAt: observedAt
            )
          ),
          try overviewObservation(
            deviceID: "device-b",
            snapshot: overviewSnapshot(
              fingerprint: "shared-account",
              scope: .global,
              usedPercent: 80,
              observedAt: observedAt
            )
          ),
        ]))
      ]
    )
    let relayModel = makeOverviewRelayStateModel(profiles: [profile], client: client)
    let localSnapshot = overviewSnapshot(
      fingerprint: "shared-account",
      scope: .global,
      usedPercent: 20,
      observedAt: observedAt
    )
    let model = MenuBarViewModel(
      collector: OverviewLocalCollector(report: overviewReport([localSnapshot])),
      reportCache: nil,
      relayStateModel: relayModel
    )

    await model.refresh()
    let account = try #require(
      contentAccounts(model.overviewState(enabledProviders: [.codex], now: overviewNow)).first
    )

    #expect(account.selectedSource == .local)
    #expect(account.snapshot.windows.first?.usedPercent == 20)
    #expect(account.sources == [
      .local,
      .remote(relayInstanceID: profile.instanceID, deviceID: "device-a"),
      .remote(relayInstanceID: profile.instanceID, deviceID: "device-b"),
    ])
    // Provenance follows SubscriptionResolver's selectedSource only.
    #expect(account.selectedSource == .local)
    #expect(account.sourceSummary == "Local")
    #expect(account.selectedSourceDisplayName == "This Mac")
    #expect(account.sources.count == 3)
  }

  @Test
  func keepsSourceScopedObservationsSeparateAcrossDevices() async throws {
    let profile = try overviewProfile()
    let client = OverviewRelayClient(
      snapshotResults: [
        .success(OwnerSnapshotListResponse(observations: [
          try overviewObservation(
            deviceID: "device-a",
            snapshot: overviewSnapshot(fingerprint: "account", scope: .source)
          ),
          try overviewObservation(
            deviceID: "device-b",
            snapshot: overviewSnapshot(fingerprint: "account", scope: .source)
          ),
        ]))
      ]
    )
    let model = MenuBarViewModel(
      collector: OverviewLocalCollector(report: emptyOverviewReport),
      reportCache: nil,
      relayStateModel: makeOverviewRelayStateModel(profiles: [profile], client: client)
    )

    await model.refresh()
    let accounts = contentAccounts(model.overviewState(enabledProviders: [.codex]))

    #expect(accounts.count == 2)
    #expect(accounts.map(\.sourceSummary) == ["Remote", "Remote"])
    #expect(Set(accounts.map(\.selectedSource)).count == 2)
  }

  @Test
  func keepsProvidersSeparateInProductOrder() async throws {
    let profile = try overviewProfile()
    let client = OverviewRelayClient(
      snapshotResults: [
        .success(OwnerSnapshotListResponse(observations: [
          try overviewObservation(
            deviceID: "device-a",
            snapshot: overviewSnapshot(
              provider: .claude,
              fingerprint: "account",
              scope: .global
            )
          ),
          try overviewObservation(
            deviceID: "device-a",
            snapshot: overviewSnapshot(
              provider: .codex,
              fingerprint: "account",
              scope: .global
            )
          ),
        ]))
      ]
    )
    let model = MenuBarViewModel(
      collector: OverviewLocalCollector(report: emptyOverviewReport),
      reportCache: nil,
      relayStateModel: makeOverviewRelayStateModel(profiles: [profile], client: client)
    )

    await model.refresh()
    guard case .content(let providers, _) = model.overviewState(
      enabledProviders: ProviderID.allCases
    ) else {
      Issue.record("Expected remote provider content.")
      return
    }

    #expect(providers.map(\.provider) == [.codex, .claude])
  }

  @Test
  func integratesAvailabilityNewestAndLocalSelectionPriorities() async throws {
    let profile = try overviewProfile()
    let remoteSource = QuotaObservationSource.remote(
      relayInstanceID: profile.instanceID,
      deviceID: "device-a"
    )
    let client = OverviewRelayClient(
      snapshotResults: [
        .success(OwnerSnapshotListResponse(observations: [
          try overviewObservation(
            deviceID: "device-a",
            snapshot: overviewSnapshot(
              fingerprint: "availability",
              scope: .global,
              usedPercent: 10,
              observedAt: overviewNow.addingTimeInterval(-60)
            )
          ),
          try overviewObservation(
            deviceID: "device-a",
            snapshot: overviewSnapshot(
              fingerprint: "newest",
              scope: .global,
              usedPercent: 20,
              observedAt: overviewNow
            )
          ),
          try overviewObservation(
            deviceID: "device-a",
            snapshot: overviewSnapshot(
              fingerprint: "local-tie",
              scope: .global,
              usedPercent: 40,
              observedAt: overviewNow
            )
          ),
        ]))
      ]
    )
    let localSnapshots = [
      overviewSnapshot(
        fingerprint: "availability",
        scope: .global,
        status: .stale,
        usedPercent: 90,
        observedAt: overviewNow
      ),
      overviewSnapshot(
        fingerprint: "newest",
        scope: .global,
        usedPercent: 80,
        observedAt: overviewNow.addingTimeInterval(-60)
      ),
      overviewSnapshot(
        fingerprint: "local-tie",
        scope: .global,
        usedPercent: 30,
        observedAt: overviewNow
      ),
    ]
    let model = MenuBarViewModel(
      collector: OverviewLocalCollector(report: overviewReport(localSnapshots)),
      reportCache: nil,
      relayStateModel: makeOverviewRelayStateModel(profiles: [profile], client: client)
    )

    await model.refresh()
    let accounts = contentAccounts(
      model.overviewState(enabledProviders: [.codex], now: overviewNow)
    )
    let accountsByFingerprint = Dictionary(
      uniqueKeysWithValues: accounts.map { ($0.identity.fingerprint, $0) }
    )

    #expect(accountsByFingerprint["availability"]?.selectedSource == remoteSource)
    #expect(accountsByFingerprint["availability"]?.snapshot.windows.first?.usedPercent == 10)
    #expect(accountsByFingerprint["newest"]?.selectedSource == remoteSource)
    #expect(accountsByFingerprint["newest"]?.snapshot.windows.first?.usedPercent == 20)
    #expect(accountsByFingerprint["local-tie"]?.selectedSource == .local)
    #expect(accountsByFingerprint["local-tie"]?.snapshot.windows.first?.usedPercent == 30)
  }

  @Test
  func derivesLocalAndActiveRelayReportingSourcesWithAgeAndStaleness() async throws {
    let profile = try overviewProfile()
    let activeDevice = try overviewDevice(deviceID: "device-a", displayName: "Studio Mac")
    let revokedDevice = try overviewDevice(
      deviceID: "device-revoked",
      displayName: "Old Build Host",
      revokedAt: "2026-08-03T11:00:00Z"
    )
    let remoteSnapshot = overviewSnapshot(
      fingerprint: "remote-account",
      scope: .global,
      observedAt: overviewNow.addingTimeInterval(-120),
      validUntil: overviewNow
    )
    let client = OverviewRelayClient(
      snapshotResults: [
        .success(OwnerSnapshotListResponse(observations: [
          try overviewObservation(deviceID: activeDevice.deviceID, snapshot: remoteSnapshot),
          try overviewObservation(deviceID: revokedDevice.deviceID, snapshot: remoteSnapshot),
          try overviewObservation(deviceID: "device-orphaned", snapshot: remoteSnapshot),
        ]))
      ],
      deviceResults: [
        .success(DeviceListResponse(devices: [activeDevice, revokedDevice]))
      ]
    )
    let localSnapshot = overviewSnapshot(
      fingerprint: "local-account",
      scope: .global,
      observedAt: overviewNow.addingTimeInterval(-30)
    )
    let model = MenuBarViewModel(
      collector: OverviewLocalCollector(report: overviewReport([localSnapshot])),
      reportCache: nil,
      relayStateModel: makeOverviewRelayStateModel(profiles: [profile], client: client)
    )

    await model.refresh()
    let sources = model.reportingSources(for: .codex, now: overviewNow)

    #expect(sources.map(\.displayName) == ["This Mac", "Studio Mac"])
    #expect(sources.map(\.kind) == [.local, .relay])
    #expect(sources[0].detailLabel(now: overviewNow) == "Local · 30s ago")
    #expect(sources[1].detailLabel(now: overviewNow) == "Relay · Stale · 2min ago")
  }

  @Test
  func collapsesMultipleRelayDevicesToOneProviderIndicatorEvenWhenHidden() async throws {
    let profile = try overviewProfile()
    let deviceA = try overviewDevice(deviceID: "device-a", displayName: "Studio Mac")
    let deviceB = try overviewDevice(deviceID: "device-b", displayName: "Build Mac")
    let snapshot = overviewSnapshot(fingerprint: "remote-account", scope: .source)
    let client = OverviewRelayClient(
      snapshotResults: [
        .success(OwnerSnapshotListResponse(observations: [
          try overviewObservation(deviceID: deviceA.deviceID, snapshot: snapshot),
          try overviewObservation(deviceID: deviceB.deviceID, snapshot: snapshot),
        ]))
      ],
      deviceResults: [
        // Duplicate device rows still identify one source by profileID + deviceID.
        .success(DeviceListResponse(devices: [deviceA, deviceA, deviceB]))
      ]
    )
    let model = MenuBarViewModel(
      collector: OverviewLocalCollector(report: emptyOverviewReport),
      reportCache: nil,
      relayStateModel: makeOverviewRelayStateModel(profiles: [profile], client: client)
    )

    await model.refresh()
    let sources = model.reportingSources(for: .codex, now: overviewNow)
    let relayReportedProviders = model.relayReportingProviders(now: overviewNow)
    let suiteName = "QuotaBarTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    ProviderVisibility.setVisible(.codex, false, defaults: defaults)

    #expect(sources.count == 2)
    #expect(Set(sources.map(\.id)).count == 2)
    #expect(relayReportedProviders == [.codex])
    #expect(!ProviderVisibility.isVisible(.codex, defaults: defaults))
  }

  @Test
  func keepsSameDeviceIDSeparateAcrossRelayEndpointsWithoutDisplayingAddresses() async throws {
    let first = try overviewProfile(
      id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
      name: "Primary Relay",
      host: "primary-relay.example",
      instanceID: "relay-primary"
    )
    let second = try overviewProfile(
      id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
      name: "Backup Relay",
      host: "backup-relay.example",
      instanceID: "relay-backup"
    )
    let device = try overviewDevice(deviceID: "shared-device", displayName: "Build Mac")
    let snapshot = overviewSnapshot(fingerprint: "remote-account", scope: .source)
    let client = OverviewRelayClient(
      snapshotResults: [
        .success(OwnerSnapshotListResponse(observations: [
          try overviewObservation(deviceID: device.deviceID, snapshot: snapshot)
        ])),
        .success(OwnerSnapshotListResponse(observations: [
          try overviewObservation(deviceID: device.deviceID, snapshot: snapshot)
        ])),
      ],
      deviceResults: [
        .success(DeviceListResponse(devices: [device])),
        .success(DeviceListResponse(devices: [device])),
      ]
    )
    let model = MenuBarViewModel(
      collector: OverviewLocalCollector(report: emptyOverviewReport),
      reportCache: nil,
      relayStateModel: makeOverviewRelayStateModel(profiles: [first, second], client: client)
    )

    await model.refresh()
    let sources = model.reportingSources(for: .codex, now: overviewNow)

    #expect(sources.count == 2)
    #expect(Set(sources.map(\.id)).count == 2)
    #expect(Set(sources.map { $0.detailLabel(now: overviewNow) }) == ["Relay · 0s ago"])
    #expect(model.relayReportingProviders(now: overviewNow) == [.codex])
  }

  @Test
  func relayRefreshFailureKeepsLastGoodContentAndShowsOnlyRefreshWarning() async throws {
    let profile = try overviewProfile()
    let observation = try overviewObservation(
      deviceID: "device-a",
      snapshot: overviewSnapshot(fingerprint: "remote-account", scope: .global)
    )
    let client = OverviewRelayClient(
      snapshotResults: [
        .success(OwnerSnapshotListResponse(observations: [observation])),
        .failure(.unavailable),
      ]
    )
    let relayModel = makeOverviewRelayStateModel(profiles: [profile], client: client)
    let model = MenuBarViewModel(
      collector: OverviewLocalCollector(report: emptyOverviewReport),
      reportCache: nil,
      relayStateModel: relayModel
    )

    await model.refresh()
    await model.refresh()

    guard case .content(let providers, let warning) = model.overviewState(
      enabledProviders: [.codex]
    ) else {
      Issue.record("Expected last-good Relay content.")
      return
    }
    #expect(providers.first?.accounts.count == 1)
    #expect(warning == "Overview Relay: The Relay is unavailable.")
    #expect(relayModel.state(for: profile.id)?.observations == [observation])
    #expect(await client.calls == [
      .snapshots,
      .devices,
      .snapshots,
    ])
  }

  @Test
  func localFailureStillRefreshesRelayAndPresentsRemoteContent() async throws {
    let profile = try overviewProfile()
    let client = OverviewRelayClient(
      snapshotResults: [
        .success(OwnerSnapshotListResponse(observations: [
          try overviewObservation(
            deviceID: "device-a",
            snapshot: overviewSnapshot(fingerprint: "remote-account", scope: .global)
          )
        ]))
      ]
    )
    let model = MenuBarViewModel(
      collector: OverviewFailingLocalCollector(),
      reportCache: nil,
      relayStateModel: makeOverviewRelayStateModel(profiles: [profile], client: client)
    )

    await model.refresh()

    guard case .content(let providers, let warning) = model.overviewState(
      enabledProviders: [.codex]
    ) else {
      Issue.record("Expected Relay content after local collection failed.")
      return
    }
    #expect(providers.first?.accounts.count == 1)
    #expect(warning == "Synthetic local refresh failure.")
    #expect(await client.calls == [.snapshots, .devices])
  }

  @Test
  func aggregatesRefreshWarningsWithTheirRelayProfileNames() async throws {
    let first = try overviewProfile(
      id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
      name: "Primary Relay",
      host: "primary-relay.example",
      instanceID: "relay-primary"
    )
    let second = try overviewProfile(
      id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
      name: "Backup Relay",
      host: "backup-relay.example",
      instanceID: "relay-backup"
    )
    let client = OverviewRelayClient(
      snapshotResults: [.failure(.unavailable), .failure(.unavailable)]
    )
    let model = MenuBarViewModel(
      collector: OverviewLocalCollector(report: emptyOverviewReport),
      reportCache: nil,
      relayStateModel: makeOverviewRelayStateModel(
        profiles: [first, second],
        client: client
      )
    )

    await model.refresh()

    #expect(
      model.overviewState(enabledProviders: ProviderID.allCases)
        == .empty(
          refreshWarning:
            "Primary Relay: The Relay is unavailable. Backup Relay: The Relay is unavailable."
        )
    )
    #expect(await client.calls == [.snapshots, .snapshots])
  }
}

@MainActor
func makeEmptyRelayStateModel() -> RelayStateModel {
  makeOverviewRelayStateModel(profiles: [], client: OverviewRelayClient())
}

@MainActor
private func makeOverviewRelayStateModel(
  profiles: [RelayProfile],
  client: OverviewRelayClient
) -> RelayStateModel {
  RelayStateModel(
    client: client,
    profileStore: OverviewRelayProfileStore(profiles: profiles),
    credentialStore: OverviewRelayCredentialStore(),
    now: { overviewNow }
  )
}

private enum OverviewRelayCall: Equatable, Sendable {
  case snapshots
  case devices
}

private actor OverviewRelayClient: RelayOwnerClientServing {
  private(set) var calls: [OverviewRelayCall] = []
  private var snapshotResults: [Result<OwnerSnapshotListResponse, RelayClientError>]
  private var deviceResults: [Result<DeviceListResponse, RelayClientError>]

  init(
    snapshotResults: [Result<OwnerSnapshotListResponse, RelayClientError>] = [],
    deviceResults: [Result<DeviceListResponse, RelayClientError>] = []
  ) {
    self.snapshotResults = snapshotResults
    self.deviceResults = deviceResults
  }

  func discover(baseURL _: URL) async throws -> RelayInfo {
    throw RelayClientError.unavailable
  }

  func registerOwner(baseURL _: URL) async throws -> OwnerRegistrationResponse {
    throw RelayClientError.unavailable
  }

  func approvePairing(
    userCode _: String,
    profile _: RelayProfile,
    ownerBearer _: String
  ) async throws {
    throw RelayClientError.unavailable
  }

  func denyPairing(
    userCode _: String,
    profile _: RelayProfile,
    ownerBearer _: String
  ) async throws {
    throw RelayClientError.unavailable
  }

  func fetchLatestSnapshots(
    profile _: RelayProfile,
    ownerBearer _: String
  ) async throws -> OwnerSnapshotListResponse {
    calls.append(.snapshots)
    guard !snapshotResults.isEmpty else {
      return OwnerSnapshotListResponse(observations: [])
    }
    return try snapshotResults.removeFirst().get()
  }

  func listDevices(
    profile _: RelayProfile,
    ownerBearer _: String
  ) async throws -> DeviceListResponse {
    calls.append(.devices)
    guard !deviceResults.isEmpty else {
      return DeviceListResponse(devices: [])
    }
    return try deviceResults.removeFirst().get()
  }

  func revokeDevice(
    deviceID _: String,
    profile _: RelayProfile,
    ownerBearer _: String
  ) async throws {
    throw RelayClientError.unavailable
  }

  func deleteOwner(
    profile _: RelayProfile,
    ownerBearer _: String
  ) async throws {
    throw RelayClientError.unavailable
  }
}

@MainActor
private final class OverviewRelayProfileStore: RelayProfilePersisting {
  private let profiles: [RelayProfile]

  init(profiles: [RelayProfile]) {
    self.profiles = profiles
  }

  func load() throws -> [RelayProfile] {
    profiles
  }

  func save(_: [RelayProfile]) throws {}
}

private struct OverviewRelayCredentialStore: RelayOwnerCredentialPersisting {
  func save(_: String, reference _: String) throws {}

  func load(reference _: String) throws -> String {
    "owner_synthetic"
  }

  func delete(reference _: String) throws {}

  func reconcile(retaining _: Set<String>) throws {}

  func deleteAll() throws {}
}

private struct OverviewLocalCollector: LocalQuotaCollecting {
  let report: QuotaCollectionReport

  func collect() async throws -> QuotaCollectionReport {
    report
  }
}

private struct OverviewFailingLocalCollector: LocalQuotaCollecting {
  func collect() async throws -> QuotaCollectionReport {
    throw OverviewLocalError()
  }
}

private struct OverviewLocalError: LocalizedError {
  var errorDescription: String? { "Synthetic local refresh failure." }
}

private func contentAccounts(_ state: QuotaOverviewState) -> [AccountQuotaPresentation] {
  guard case .content(let providers, _) = state else {
    return []
  }
  return providers.flatMap(\.accounts)
}

private func overviewProfile(
  id: UUID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
  name: String = "Overview Relay",
  host: String = "relay.example",
  instanceID: String = "relay-overview"
) throws -> RelayProfile {
  try RelayProfile(
    id: id,
    name: name,
    baseURL: URL(string: "https://\(host)")!,
    instanceID: instanceID,
    mode: .selfHosted,
    capabilities: RelayCapabilities(
      realtime: false,
      persistentSnapshots: true,
      instantDeviceRevocation: true,
      history: false,
      multiTenant: false
    )
  )
}

private func overviewObservation(
  deviceID: String,
  snapshot: QuotaSnapshot
) throws -> OwnerSnapshotObservation {
  let snapshotData = try QuotaWireCodec.makeEncoder().encode(snapshot)
  let snapshotJSON = try #require(String(data: snapshotData, encoding: .utf8))
  let responseData = Data(
    #"{"observations":[{"device_id":"\#(deviceID)","sequence":1,"captured_at":"2026-08-03T12:00:00Z","snapshot":\#(snapshotJSON),"updated_at":"2026-08-03T12:00:01Z"}]}"#.utf8
  )
  return try #require(
    QuotaWireCodec.makeDecoder()
      .decode(OwnerSnapshotListResponse.self, from: responseData)
      .observations.first
  )
}

private func overviewDevice(
  deviceID: String,
  displayName: String,
  revokedAt: String? = nil
) throws -> RelayDevice {
  let revokedAtJSON = revokedAt.map { "\"\($0)\"" } ?? "null"
  let responseData = Data(
    #"{"devices":[{"device_id":"\#(deviceID)","display_name":"\#(displayName)","created_at":"2026-08-03T10:00:00Z","last_seen_at":"2026-08-03T12:00:00Z","last_sequence":1,"revoked_at":\#(revokedAtJSON)}]}"#.utf8
  )
  return try #require(
    QuotaWireCodec.makeDecoder()
      .decode(DeviceListResponse.self, from: responseData)
      .devices.first
  )
}

private func overviewSnapshot(
  provider: ProviderID = .codex,
  fingerprint: String,
  scope: FingerprintScope,
  status: QuotaStatus = .available,
  usedPercent: Double = 50,
  observedAt: Date = overviewNow,
  validUntil: Date? = overviewNow.addingTimeInterval(300)
) -> QuotaSnapshot {
  QuotaSnapshot(
    provider: provider,
    account: QuotaAccount(
      fingerprint: fingerprint,
      label: nil,
      plan: "Pro",
      fingerprintScope: scope
    ),
    windows: [
      QuotaWindow(
        id: "weekly",
        title: "Weekly",
        usedPercent: usedPercent,
        resetsAt: nil,
        durationSeconds: nil
      )
    ],
    source: "provider-reported-source",
    status: status,
    observedAt: observedAt,
    validUntil: validUntil
  )
}

private func overviewReport(_ snapshots: [QuotaSnapshot]) -> QuotaCollectionReport {
  QuotaCollectionReport(
    schemaVersion: 1,
    capturedAt: overviewNow,
    results: [
      QuotaCollectionResult(
        provider: .codex,
        outcome: .success,
        snapshots: snapshots,
        source: "provider-reported-source",
        message: nil
      )
    ]
  )
}

private let emptyOverviewReport = overviewReport([])
private let overviewNow = Date(timeIntervalSince1970: 1_785_758_400)
