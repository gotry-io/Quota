import Foundation
import Testing

@testable import QuotaBar

@Suite
@MainActor
struct RelayStateModelTests {
  @Test
  func managedEnrollmentOptOutPersistsInItsOwnNonSecretPreference() throws {
    let suite = "io.gotry.quotabar.tests.managed-enrollment.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let store = ManagedRelayEnrollmentStore(defaults: defaults)
    #expect(!store.isDisabled)

    store.setDisabled(true)

    #expect(ManagedRelayEnrollmentStore(defaults: defaults).isDisabled)
    #expect(defaults.object(forKey: ManagedRelayEnrollmentStore.storageKey) as? Bool == true)
  }

  @Test
  func loadsProfilesAndReportsFixedLoadFailure() throws {
    let profile = try sampleRelayProfile(id: profileID1, isDefault: true)
    let loadedModel = RelayStateModel(
      client: FakeRelayStateClient(),
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([profile])),
      credentialStore: FakeRelayCredentialStore()
    )

    #expect(loadedModel.profiles == [profile])
    #expect(loadedModel.state(for: profile.id) == RelayProfileState())
    #expect(loadedModel.globalIssue == nil)

    let failedModel = RelayStateModel(
      client: FakeRelayStateClient(),
      profileStore: FakeRelayProfileStore(loadedProfiles: .failure(.invalidData)),
      credentialStore: FakeRelayCredentialStore()
    )
    #expect(failedModel.profiles.isEmpty)
    #expect(failedModel.globalIssue?.category == .persistence)
    #expect(failedModel.globalIssue?.message == "The saved Relay profiles are invalid.")
  }

  @Test
  func addsSelfHostedProfileAndMakesTheFirstProfileDefault() async throws {
    let operations = RelayPersistenceRecorder()
    let profileStore = FakeRelayProfileStore(operations: operations)
    let credentialStore = FakeRelayCredentialStore(operations: operations)
    let client = FakeRelayStateClient(
      discoveryResults: [.success(sampleRelayInfo())]
    )
    let model = RelayStateModel(
      client: client,
      profileStore: profileStore,
      credentialStore: credentialStore,
      makeProfileID: { profileID1 }
    )

    let profile = try await model.addSelfHostedProfile(
      name: " Primary ",
      origin: "HTTPS://Relay.EXAMPLE:443/",
      controllerBearer: syntheticControllerBearer
    )

    #expect(profile.id == profileID1)
    #expect(profile.name == "Primary")
    #expect(profile.baseURL.absoluteString == "https://relay.example")
    #expect(profile.instanceID == "relay_primary")
    #expect(profile.isDefault)
    #expect(model.profiles == [profile])
    #expect(model.state(for: profile.id) == RelayProfileState())
    #expect(credentialStore.token(reference: profile.credentialReference) == syntheticControllerBearer)
    #expect(profileStore.savedProfiles == [[profile]])
    #expect(operations.values == [
      .credentialSave(profile.credentialReference),
      .metadataSave,
    ])
    #expect(await client.calls == [.discover("https://relay.example")])
  }

  @Test
  func updateControllerCredentialReplacesStoredBearerForSelfHostedProfile() async throws {
    let operations = RelayPersistenceRecorder()
    let credentialStore = FakeRelayCredentialStore(operations: operations)
    let model = RelayStateModel(
      client: FakeRelayStateClient(discoveryResults: [.success(sampleRelayInfo())]),
      profileStore: FakeRelayProfileStore(operations: operations),
      credentialStore: credentialStore,
      makeProfileID: { profileID1 }
    )
    let profile = try await model.addSelfHostedProfile(
      name: "Primary",
      origin: "https://relay.example",
      controllerBearer: syntheticControllerBearer
    )

    let replacement = "replacement_controller_credential_0123456789"
    try model.updateControllerCredential(
      profileID: profile.id,
      controllerBearer: replacement
    )

    #expect(credentialStore.token(reference: profile.credentialReference) == replacement)
    #expect(operations.values.contains(.credentialSave(profile.credentialReference)))
  }

  @Test
  func rollsBackCredentialWhenAddedProfileMetadataCannotBeSaved() async throws {
    let operations = RelayPersistenceRecorder()
    let profileStore = FakeRelayProfileStore(
      saveErrors: [.couldNotSave],
      operations: operations
    )
    let credentialStore = FakeRelayCredentialStore(operations: operations)
    let model = RelayStateModel(
      client: FakeRelayStateClient(discoveryResults: [.success(sampleRelayInfo())]),
      profileStore: profileStore,
      credentialStore: credentialStore,
      makeProfileID: { profileID1 }
    )
    let reference = RelayProfile.credentialReference(for: profileID1)

    do {
      _ = try await model.addSelfHostedProfile(
        name: "Primary",
        origin: "https://relay.example",
        controllerBearer: syntheticControllerBearer
      )
      Issue.record("Expected profile metadata storage to fail.")
    } catch let error as RelayStateModelError {
      #expect(error.issue.category == .persistence)
      #expect(error.errorDescription == "QuotaBar could not save the Relay profiles.")
    }

    #expect(model.profiles.isEmpty)
    #expect(credentialStore.token(reference: reference) == nil)
    #expect(operations.values == [
      .credentialSave(reference),
      .metadataSave,
      .credentialDelete(reference),
    ])
  }

  @Test
  func rejectsManagedRelayFromSelfHostedProfileFlowBeforeCredentialStorage() async throws {
    let managedInfo = RelayInfo(
      instanceID: "managed_primary",
      mode: .managed,
      version: "0.1.0",
      apiVersions: [1],
      authMethods: ["bearer"],
      capabilities: sampleRelayCapabilities
    )
    let credentialStore = FakeRelayCredentialStore()
    let model = RelayStateModel(
      client: FakeRelayStateClient(discoveryResults: [.success(managedInfo)]),
      profileStore: FakeRelayProfileStore(),
      credentialStore: credentialStore
    )

    do {
      _ = try await model.addSelfHostedProfile(
        name: "Managed",
        origin: "https://quota.example",
        controllerBearer: syntheticControllerBearer
      )
      Issue.record("Expected the self-hosted controller flow to reject a managed Relay.")
    } catch let error as RelayStateModelError {
      #expect(error.issue.category == .unsupported)
      #expect(error.errorDescription == "Only self-hosted Relays can be added with a controller bearer.")
    }

    #expect(model.profiles.isEmpty)
    #expect(
      credentialStore.token(reference: RelayProfile.credentialReference(for: profileID1)) == nil
    )
  }

  @Test
  func registersAndPersistsManagedControllerWhenNoManagedProfileExists() async throws {
    let info = RelayInfo(
      instanceID: "managed_primary",
      mode: .managed,
      version: "0.1.0",
      apiVersions: [1],
      authMethods: ["bearer"],
      capabilities: sampleManagedRelayCapabilities
    )
    let profileStore = FakeRelayProfileStore()
    let credentialStore = FakeRelayCredentialStore()
    let client = FakeRelayStateClient(
      discoveryResults: [.success(info)],
      registrationResults: [
        .success(ControllerRegistrationResponse(controllerToken: syntheticControllerBearer))
      ]
    )
    let model = RelayStateModel(
      client: client,
      profileStore: profileStore,
      credentialStore: credentialStore,
      makeProfileID: { profileID1 }
    )

    await model.ensureManagedControllerProfile()

    let profile = try #require(model.profiles.first)
    #expect(profile.id == profileID1)
    #expect(profile.name == "Quota Relay")
    #expect(profile.baseURL.absoluteString == "https://quota.gotry.io")
    #expect(profile.mode == .managed)
    #expect(profile.isDefault)
    #expect(credentialStore.token(reference: profile.credentialReference) == syntheticControllerBearer)
    #expect(profileStore.savedProfiles == [[profile]])
    #expect(await client.calls == [
      .discover("https://quota.gotry.io"),
      .register("https://quota.gotry.io"),
    ])
  }

  @Test
  func managedControllerEnrollmentFailureRemainsRetryable() async throws {
    let info = RelayInfo(
      instanceID: "managed_primary",
      mode: .managed,
      version: "0.1.0",
      apiVersions: [1],
      authMethods: ["bearer"],
      capabilities: sampleManagedRelayCapabilities
    )
    let client = FakeRelayStateClient(
      discoveryResults: [.failure(.unavailable), .success(info)],
      registrationResults: [
        .success(ControllerRegistrationResponse(controllerToken: syntheticControllerBearer))
      ]
    )
    let model = RelayStateModel(
      client: client,
      profileStore: FakeRelayProfileStore(),
      credentialStore: FakeRelayCredentialStore(),
      makeProfileID: { profileID1 }
    )

    await model.ensureManagedControllerProfile()
    #expect(model.profiles.isEmpty)
    #expect(model.globalIssue?.category == .unavailable)

    await model.ensureManagedControllerProfile()
    #expect(model.profiles.count == 1)
    #expect(model.globalIssue == nil)
  }

  @Test
  func managedEnrollmentRollsBackRemoteControllerWhenProfilePersistenceFails() async throws {
    let info = RelayInfo(
      instanceID: "managed_primary",
      mode: .managed,
      version: "0.1.0",
      apiVersions: [1],
      authMethods: ["bearer"],
      capabilities: sampleManagedRelayCapabilities
    )
    let profileStore = FakeRelayProfileStore(saveErrors: [.couldNotSave])
    let credentialStore = FakeRelayCredentialStore()
    let client = FakeRelayStateClient(
      discoveryResults: [.success(info)],
      registrationResults: [
        .success(ControllerRegistrationResponse(controllerToken: syntheticControllerBearer))
      ]
    )
    let model = RelayStateModel(
      client: client,
      profileStore: profileStore,
      credentialStore: credentialStore,
      makeProfileID: { profileID1 }
    )

    await model.ensureManagedControllerProfile()

    #expect(model.profiles.isEmpty)
    #expect(model.globalIssue?.category == .persistence)
    #expect(
      credentialStore.token(reference: RelayProfile.credentialReference(for: profileID1)) == nil
    )
    #expect(await client.calls == [
      .discover("https://quota.gotry.io"),
      .register("https://quota.gotry.io"),
      .deleteController(profileID1, syntheticControllerBearer),
    ])
  }

  @Test
  func startupReconcilesControllerCredentialsAgainstLoadedProfiles() throws {
    let profile = try sampleRelayProfile(id: profileID1, isDefault: true)
    let credentialStore = FakeRelayCredentialStore()

    _ = RelayStateModel(
      client: FakeRelayStateClient(),
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([profile])),
      credentialStore: credentialStore
    )

    #expect(credentialStore.reconciledReferences == [profile.credentialReference])
  }

  @Test
  func deletesMetadataBeforeCredentialAndPromotesTheNextDefault() async throws {
    let first = try sampleRelayProfile(id: profileID1, isDefault: true)
    let second = try sampleRelayProfile(id: profileID2, host: "relay-two.example")
    let operations = RelayPersistenceRecorder()
    let profileStore = FakeRelayProfileStore(
      loadedProfiles: .success([first, second]),
      operations: operations
    )
    let credentialStore = FakeRelayCredentialStore(
      tokens: [
        first.credentialReference: syntheticControllerBearer,
        second.credentialReference: "controller_second_synthetic",
      ],
      operations: operations
    )
    let client = FakeRelayStateClient()
    let model = RelayStateModel(
      client: client,
      profileStore: profileStore,
      credentialStore: credentialStore
    )

    try await model.deleteProfile(first.id)

    #expect(credentialStore.token(reference: first.credentialReference) == nil)
    #expect(model.profiles.count == 1)
    #expect(model.profiles[0].id == second.id)
    #expect(model.profiles[0].isDefault)
    #expect(model.state(for: first.id) == nil)
    #expect(operations.values == [
      .metadataSave,
      .credentialDelete(first.credentialReference),
    ])
    #expect(await client.calls.isEmpty)
  }

  @Test
  func deletingManagedProfileDeletesControllerAndPersistsEnrollmentOptOut() async throws {
    let profile = try sampleRelayProfile(
      id: profileID1,
      host: "quota.gotry.io",
      mode: .managed,
      isDefault: true
    )
    let client = FakeRelayStateClient()
    let credentialStore = FakeRelayCredentialStore(
      tokens: [profile.credentialReference: syntheticControllerBearer]
    )
    let enrollmentStore = FakeManagedRelayEnrollmentStore()
    let model = RelayStateModel(
      client: client,
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([profile])),
      credentialStore: credentialStore,
      managedEnrollmentStore: enrollmentStore
    )

    try await model.deleteProfile(profile.id)
    await model.ensureManagedControllerProfile()

    #expect(model.profiles.isEmpty)
    #expect(model.managedEnrollmentDisabled)
    #expect(enrollmentStore.isDisabled)
    #expect(credentialStore.token(reference: profile.credentialReference) == nil)
    #expect(await client.calls == [
      .deleteController(profile.id, syntheticControllerBearer)
    ])

    let restartedModel = RelayStateModel(
      client: client,
      profileStore: FakeRelayProfileStore(),
      credentialStore: credentialStore,
      managedEnrollmentStore: enrollmentStore
    )
    await restartedModel.ensureManagedControllerProfile()

    #expect(restartedModel.profiles.isEmpty)
    #expect(await client.calls == [.deleteController(profile.id, syntheticControllerBearer)])
  }

  @Test
  func reconnectingManagedRelayClearsThePersistentOptOutAndEnrolls() async throws {
    let info = RelayInfo(
      instanceID: "managed_primary",
      mode: .managed,
      version: "0.1.0",
      apiVersions: [1],
      authMethods: ["bearer"],
      capabilities: sampleManagedRelayCapabilities
    )
    let enrollmentStore = FakeManagedRelayEnrollmentStore(isDisabled: true)
    let model = RelayStateModel(
      client: FakeRelayStateClient(
        discoveryResults: [.success(info)],
        registrationResults: [
          .success(ControllerRegistrationResponse(controllerToken: syntheticControllerBearer))
        ],
        snapshotResults: [.success(ControllerSnapshotListResponse(observations: []))],
        deviceResults: [.success(DeviceListResponse(devices: []))]
      ),
      profileStore: FakeRelayProfileStore(),
      credentialStore: FakeRelayCredentialStore(),
      managedEnrollmentStore: enrollmentStore,
      makeProfileID: { profileID1 }
    )

    await model.enableManagedControllerProfile()

    #expect(!model.managedEnrollmentDisabled)
    #expect(!enrollmentStore.isDisabled)
    #expect(model.profiles.map(\.id) == [profileID1])
  }

  @Test
  func managedProfileCanBeExplicitlyDeletedLocallyAfterRemoteDeletionFails() async throws {
    let profile = try sampleRelayProfile(
      id: profileID1,
      host: "quota.gotry.io",
      mode: .managed,
      isDefault: true
    )
    let credentialStore = FakeRelayCredentialStore(
      tokens: [profile.credentialReference: syntheticControllerBearer]
    )
    let enrollmentStore = FakeManagedRelayEnrollmentStore()
    let model = RelayStateModel(
      client: FakeRelayStateClient(controllerDeleteResults: [.failure(.credentialRejected)]),
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([profile])),
      credentialStore: credentialStore,
      managedEnrollmentStore: enrollmentStore
    )

    await #expect(throws: RelayStateModelError.self) {
      try await model.deleteProfile(profile.id)
    }
    try model.deleteProfileLocally(profile.id)

    #expect(model.profiles.isEmpty)
    #expect(model.managedEnrollmentDisabled)
    #expect(enrollmentStore.isDisabled)
    #expect(credentialStore.token(reference: profile.credentialReference) == nil)
  }

  @Test
  func fullResetDeletesOnlyManagedControllersStopsPollingAndClearsLocalData() async throws {
    let managed = try sampleRelayProfile(
      id: profileID1,
      host: "quota.gotry.io",
      mode: .managed,
      isDefault: true
    )
    let selfHosted = try sampleRelayProfile(id: profileID2, host: "relay.example")
    let client = FakeRelayStateClient(
      deviceResults: [
        .success(DeviceListResponse(devices: [])),
        .success(DeviceListResponse(devices: [])),
      ]
    )
    let credentialStore = FakeRelayCredentialStore(tokens: [
      managed.credentialReference: syntheticControllerBearer,
      selfHosted.credentialReference: "controller_self_hosted",
    ])
    let defaultsResetter = FakeQuotaBarDefaultsResetter()
    let sleepProbe = RelaySleepProbe()
    let model = RelayStateModel(
      client: client,
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([managed, selfHosted])),
      credentialStore: credentialStore,
      defaultsResetter: defaultsResetter,
      sleep: { duration in try await sleepProbe.sleep(duration) }
    )
    model.startPolling()
    try await waitForSleepCount(1, probe: sleepProbe)

    try await model.deleteAllQuotaBarData()
    await model.ensureManagedControllerProfile()

    #expect(model.profiles.isEmpty)
    #expect(!model.isPolling)
    #expect(credentialStore.deleteAllCount == 1)
    #expect(defaultsResetter.deleteAllCount == 1)
    #expect(await client.calls == [
      .snapshots(managed.id, syntheticControllerBearer),
      .devices(managed.id, syntheticControllerBearer),
      .snapshots(selfHosted.id, "controller_self_hosted"),
      .devices(selfHosted.id, "controller_self_hosted"),
      .deleteController(managed.id, syntheticControllerBearer),
    ])
  }

  @Test
  func failedManagedResetCanBeExplicitlyCompletedLocally() async throws {
    let profile = try sampleRelayProfile(
      id: profileID1,
      host: "quota.gotry.io",
      mode: .managed,
      isDefault: true
    )
    let credentialStore = FakeRelayCredentialStore(
      tokens: [profile.credentialReference: syntheticControllerBearer]
    )
    let defaultsResetter = FakeQuotaBarDefaultsResetter()
    let client = FakeRelayStateClient(controllerDeleteResults: [.failure(.unavailable)])
    let model = RelayStateModel(
      client: client,
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([profile])),
      credentialStore: credentialStore,
      defaultsResetter: defaultsResetter
    )

    await #expect(throws: RelayStateModelError.self) {
      try await model.deleteAllQuotaBarData()
    }
    #expect(model.profiles == [profile])
    #expect(credentialStore.deleteAllCount == 0)

    try model.deleteAllQuotaBarDataLocally()
    await model.ensureManagedControllerProfile()

    #expect(model.profiles.isEmpty)
    #expect(credentialStore.deleteAllCount == 1)
    #expect(defaultsResetter.deleteAllCount == 1)
    #expect(await client.calls == [.deleteController(profile.id, syntheticControllerBearer)])
  }

  @Test
  func keepsProfileAndReportsPersistenceFailureWhenDeleteMetadataSaveFails() async throws {
    let profile = try sampleRelayProfile(id: profileID1, isDefault: true)
    let profileStore = FakeRelayProfileStore(
      loadedProfiles: .success([profile]),
      saveErrors: [.couldNotSave]
    )
    let credentialStore = FakeRelayCredentialStore(
      tokens: [profile.credentialReference: syntheticControllerBearer]
    )
    let model = RelayStateModel(
      client: FakeRelayStateClient(),
      profileStore: profileStore,
      credentialStore: credentialStore
    )

    do {
      try await model.deleteProfile(profile.id)
      Issue.record("Expected metadata deletion to fail.")
    } catch let error as RelayStateModelError {
      #expect(error.issue.category == .persistence)
      #expect(error.errorDescription == "QuotaBar could not save the Relay profiles.")
    }

    #expect(model.profiles == [profile])
    #expect(
      credentialStore.token(reference: profile.credentialReference) == syntheticControllerBearer
    )
    #expect(model.state(for: profile.id)?.operationIssue?.category == .persistence)
  }

  @Test
  func retriesCredentialDeletionAfterMetadataWasAlreadyRemoved() async throws {
    let profile = try sampleRelayProfile(id: profileID1, isDefault: true)
    let profileStore = FakeRelayProfileStore(loadedProfiles: .success([profile]))
    let credentialStore = FakeRelayCredentialStore(
      tokens: [profile.credentialReference: syntheticControllerBearer],
      deleteErrors: [.couldNotDelete]
    )
    let model = RelayStateModel(
      client: FakeRelayStateClient(),
      profileStore: profileStore,
      credentialStore: credentialStore
    )

    await #expect(throws: RelayStateModelError.self) {
      try await model.deleteProfile(profile.id)
    }

    #expect(model.profiles == [profile])
    #expect(profileStore.savedProfiles == [[]])
    #expect(
      credentialStore.token(reference: profile.credentialReference) == syntheticControllerBearer
    )

    try await model.deleteProfile(profile.id)

    #expect(model.profiles.isEmpty)
    #expect(profileStore.savedProfiles == [[], []])
    #expect(credentialStore.token(reference: profile.credentialReference) == nil)
  }

  @Test
  func keepsOneDefaultAndRenamesWithCanonicalName() throws {
    let first = try sampleRelayProfile(id: profileID1, isDefault: true)
    let second = try sampleRelayProfile(id: profileID2, host: "relay-two.example")
    let profileStore = FakeRelayProfileStore(loadedProfiles: .success([first, second]))
    let model = RelayStateModel(
      client: FakeRelayStateClient(),
      profileStore: profileStore,
      credentialStore: FakeRelayCredentialStore()
    )

    try model.setDefaultProfile(second.id)
    try model.renameProfile(second.id, to: " Edge Relay ")

    #expect(model.profiles.filter(\.isDefault).map(\.id) == [second.id])
    #expect(model.profiles.first(where: { $0.id == second.id })?.name == "Edge Relay")
    #expect(profileStore.savedProfiles.count == 2)
    #expect(throws: RelayStateModelError.self) {
      try model.renameProfile(second.id, to: "   ")
    }
  }

  @Test
  func approvesAndDeniesPairingThroughTheBoundProfile() async throws {
    let profile = try sampleRelayProfile(id: profileID1, isDefault: true)
    let client = FakeRelayStateClient()
    let model = RelayStateModel(
      client: client,
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([profile])),
      credentialStore: FakeRelayCredentialStore(
        tokens: [profile.credentialReference: syntheticControllerBearer]
      )
    )

    try await model.approvePairing(profileID: profile.id, userCode: "ABCD-EFGH")
    try await model.denyPairing(profileID: profile.id, userCode: "IJKL-MNOP")

    #expect(await client.calls == [
      .approve(profile.id, "ABCD-EFGH", syntheticControllerBearer),
      .deny(profile.id, "IJKL-MNOP", syntheticControllerBearer),
    ])
  }

  @Test
  func pairingFailureUsesFixedSafeIssue() async throws {
    let profile = try sampleRelayProfile(id: profileID1, isDefault: true)
    let client = FakeRelayStateClient(
      approvalResults: [.failure(.permissionDenied)]
    )
    let model = RelayStateModel(
      client: client,
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([profile])),
      credentialStore: FakeRelayCredentialStore(
        tokens: [profile.credentialReference: syntheticControllerBearer]
      )
    )

    do {
      try await model.approvePairing(profileID: profile.id, userCode: "ABCD-EFGH")
      Issue.record("Expected pairing approval to fail.")
    } catch let error as RelayStateModelError {
      #expect(error.issue.category == .authorization)
      let message = try #require(error.errorDescription)
      #expect(!message.contains(syntheticControllerBearer))
      #expect(!message.contains("ABCD-EFGH"))
      #expect(!message.contains(profile.id.uuidString))
      #expect(!message.contains("alice@example.com"))
    }
  }

  @Test
  func operationIssueDoesNotMarkLastKnownQuotaDataStale() {
    let operationIssue = RelayStateIssue(
      category: .authorization,
      message: "The Relay controller credential lacks the required permission."
    )
    let refreshIssue = RelayStateIssue(
      category: .unavailable,
      message: "The Relay is unavailable."
    )
    var state = RelayProfileState(
      lastSuccessfulRefreshAt: Date(timeIntervalSince1970: 1_785_752_430),
      operationIssue: operationIssue
    )

    #expect(!state.isStale)
    state.refreshIssue = refreshIssue
    #expect(state.isStale)
  }

  @Test
  func refreshPreservesLastKnownGoodDataAndMarksItStaleAfterFailure() async throws {
    let profile = try sampleRelayProfile(id: profileID1, isDefault: true)
    let observation = try sampleObservation(deviceID: "device_01", sequence: 4)
    let device = try sampleDevice(deviceID: "device_01", sequence: 4)
    let refreshedAt = Date(timeIntervalSince1970: 1_785_752_430)
    let client = FakeRelayStateClient(
      snapshotResults: [
        .success(ControllerSnapshotListResponse(observations: [observation])),
        .failure(.unavailable),
      ],
      deviceResults: [.success(DeviceListResponse(devices: [device]))]
    )
    let model = RelayStateModel(
      client: client,
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([profile])),
      credentialStore: FakeRelayCredentialStore(
        tokens: [profile.credentialReference: syntheticControllerBearer]
      ),
      now: { refreshedAt }
    )

    await model.refreshProfile(profile.id)
    let goodState = try #require(model.state(for: profile.id))
    #expect(goodState.observations == [observation])
    #expect(goodState.devices == [device])
    #expect(goodState.lastSuccessfulRefreshAt == refreshedAt)
    #expect(!goodState.isStale)

    await model.refreshProfile(profile.id)
    let failedState = try #require(model.state(for: profile.id))
    #expect(failedState.observations == [observation])
    #expect(failedState.devices == [device])
    #expect(failedState.lastSuccessfulRefreshAt == refreshedAt)
    #expect(failedState.refreshIssue?.category == .unavailable)
    #expect(failedState.refreshIssue?.message == "The Relay is unavailable.")
    #expect(failedState.isStale)
    #expect(!failedState.isRefreshing)
  }

  @Test
  func refreshReportsMissingAndRejectedCredentialsExplicitly() async throws {
    let missingProfile = try sampleRelayProfile(id: profileID1, isDefault: true)
    let missingClient = FakeRelayStateClient()
    let missingModel = RelayStateModel(
      client: missingClient,
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([missingProfile])),
      credentialStore: FakeRelayCredentialStore()
    )

    await missingModel.refreshProfile(missingProfile.id)

    #expect(missingModel.state(for: missingProfile.id)?.issue?.category == .credentialMissing)
    #expect(
      missingModel.state(for: missingProfile.id)?.issue?.message
        == "The Relay controller credential is missing."
    )
    #expect(await missingClient.calls.isEmpty)

    let rejectedProfile = try sampleRelayProfile(id: profileID2, isDefault: true)
    let rejectedClient = FakeRelayStateClient(
      snapshotResults: [.failure(.credentialRejected)]
    )
    let rejectedModel = RelayStateModel(
      client: rejectedClient,
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([rejectedProfile])),
      credentialStore: FakeRelayCredentialStore(
        tokens: [rejectedProfile.credentialReference: syntheticControllerBearer]
      )
    )

    await rejectedModel.refreshProfile(rejectedProfile.id)

    #expect(rejectedModel.state(for: rejectedProfile.id)?.issue?.category == .authentication)
    #expect(
      rejectedModel.state(for: rejectedProfile.id)?.issue?.message
        == "The Relay controller credential is no longer valid."
    )
  }

  @Test
  func revokeRefreshesDevicesAndKeepsSnapshots() async throws {
    let profile = try sampleRelayProfile(id: profileID1, isDefault: true)
    let remainingDevice = try sampleDevice(deviceID: "device_02", sequence: 2)
    let refreshedAt = Date(timeIntervalSince1970: 1_785_752_430)
    let client = FakeRelayStateClient(
      deviceResults: [.success(DeviceListResponse(devices: [remainingDevice]))]
    )
    let model = RelayStateModel(
      client: client,
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([profile])),
      credentialStore: FakeRelayCredentialStore(
        tokens: [profile.credentialReference: syntheticControllerBearer]
      ),
      now: { refreshedAt }
    )

    try await model.revokeDevice(profileID: profile.id, deviceID: "device_01")

    #expect(model.state(for: profile.id)?.devices == [remainingDevice])
    #expect(model.state(for: profile.id)?.lastSuccessfulRefreshAt == nil)
    #expect(await client.calls == [
      .revoke(profile.id, "device_01", syntheticControllerBearer),
      .devices(profile.id, syntheticControllerBearer),
    ])
  }

  @Test
  func refreshesAllProfilesSequentially() async throws {
    let first = try sampleRelayProfile(id: profileID1, isDefault: true)
    let second = try sampleRelayProfile(id: profileID2, host: "relay-two.example")
    let client = FakeRelayStateClient(
      snapshotResults: [
        .success(ControllerSnapshotListResponse(observations: [])),
        .success(ControllerSnapshotListResponse(observations: [])),
      ],
      deviceResults: [
        .success(DeviceListResponse(devices: [])),
        .success(DeviceListResponse(devices: [])),
      ]
    )
    let model = RelayStateModel(
      client: client,
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([first, second])),
      credentialStore: FakeRelayCredentialStore(tokens: [
        first.credentialReference: syntheticControllerBearer,
        second.credentialReference: "controller_second_synthetic",
      ])
    )

    await model.refreshAllProfiles()

    #expect(await client.calls == [
      .snapshots(first.id, syntheticControllerBearer),
      .devices(first.id, syntheticControllerBearer),
      .snapshots(second.id, "controller_second_synthetic"),
      .devices(second.id, "controller_second_synthetic"),
    ])
  }

  @Test
  func pollingStartIsIdempotentAndStopIsCancellationSafe() async throws {
    let profile = try sampleRelayProfile(id: profileID1, isDefault: true)
    let client = FakeRelayStateClient()
    let sleepProbe = RelaySleepProbe()
    let model = RelayStateModel(
      client: client,
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([profile])),
      credentialStore: FakeRelayCredentialStore(
        tokens: [profile.credentialReference: syntheticControllerBearer]
      ),
      managedRelayConfiguration: nil,
      pollInterval: .seconds(123),
      sleep: { duration in try await sleepProbe.sleep(duration) }
    )

    model.startPolling()
    model.startPolling()
    try await waitForSleepCount(1, probe: sleepProbe)

    #expect(model.isPolling)
    #expect(await sleepProbe.durations == [.seconds(123)])
    #expect(await client.calls == [
      .snapshots(profile.id, syntheticControllerBearer),
      .devices(profile.id, syntheticControllerBearer),
    ])

    model.stopPolling()
    #expect(!model.isPolling)
    try await Task.sleep(for: .milliseconds(20))
    #expect(await sleepProbe.durations.count == 1)

    model.startPolling()
    try await waitForSleepCount(2, probe: sleepProbe)
    model.stopPolling()
    #expect(await client.calls.count == 4)
  }

  @Test
  func releasingPollingModelCancelsSleeperWithoutARetainCycle() async throws {
    let profile = try sampleRelayProfile(id: profileID1, isDefault: true)
    let sleepProbe = RelaySleepProbe()
    var model: RelayStateModel? = RelayStateModel(
      client: FakeRelayStateClient(),
      profileStore: FakeRelayProfileStore(loadedProfiles: .success([profile])),
      credentialStore: FakeRelayCredentialStore(
        tokens: [profile.credentialReference: syntheticControllerBearer]
      ),
      managedRelayConfiguration: nil,
      sleep: { duration in try await sleepProbe.sleep(duration) }
    )
    weak let weakModel = model

    model?.startPolling()
    try await waitForSleepCount(1, probe: sleepProbe)
    model = nil
    try await waitForCancellationCount(1, probe: sleepProbe)

    #expect(weakModel == nil)
    #expect(await sleepProbe.cancellationCount == 1)
  }
}

private enum FakeRelayClientCall: Equatable, Sendable {
  case discover(String)
  case register(String)
  case approve(UUID, String, String)
  case deny(UUID, String, String)
  case snapshots(UUID, String)
  case devices(UUID, String)
  case revoke(UUID, String, String)
  case deleteController(UUID, String)
}

private actor FakeRelayStateClient: RelayControllerClientServing {
  private(set) var calls: [FakeRelayClientCall] = []
  private var discoveryResults: [Result<RelayInfo, RelayClientError>]
  private var registrationResults: [Result<ControllerRegistrationResponse, RelayClientError>]
  private var approvalResults: [Result<Void, RelayClientError>]
  private var denialResults: [Result<Void, RelayClientError>]
  private var snapshotResults: [Result<ControllerSnapshotListResponse, RelayClientError>]
  private var deviceResults: [Result<DeviceListResponse, RelayClientError>]
  private var revokeResults: [Result<Void, RelayClientError>]
  private var controllerDeleteResults: [Result<Void, RelayClientError>]

  init(
    discoveryResults: [Result<RelayInfo, RelayClientError>] = [],
    registrationResults: [Result<ControllerRegistrationResponse, RelayClientError>] = [],
    approvalResults: [Result<Void, RelayClientError>] = [],
    denialResults: [Result<Void, RelayClientError>] = [],
    snapshotResults: [Result<ControllerSnapshotListResponse, RelayClientError>] = [],
    deviceResults: [Result<DeviceListResponse, RelayClientError>] = [],
    revokeResults: [Result<Void, RelayClientError>] = [],
    controllerDeleteResults: [Result<Void, RelayClientError>] = []
  ) {
    self.discoveryResults = discoveryResults
    self.registrationResults = registrationResults
    self.approvalResults = approvalResults
    self.denialResults = denialResults
    self.snapshotResults = snapshotResults
    self.deviceResults = deviceResults
    self.revokeResults = revokeResults
    self.controllerDeleteResults = controllerDeleteResults
  }

  func discover(baseURL: URL) async throws -> RelayInfo {
    calls.append(.discover(baseURL.absoluteString))
    guard !discoveryResults.isEmpty else { throw RelayClientError.unavailable }
    return try discoveryResults.removeFirst().get()
  }

  func registerController(baseURL: URL) async throws -> ControllerRegistrationResponse {
    calls.append(.register(baseURL.absoluteString))
    guard !registrationResults.isEmpty else { throw RelayClientError.unavailable }
    return try registrationResults.removeFirst().get()
  }

  func approvePairing(
    userCode: String,
    profile: RelayProfile,
    controllerBearer: String
  ) async throws {
    calls.append(.approve(profile.id, userCode, controllerBearer))
    if !approvalResults.isEmpty {
      try approvalResults.removeFirst().get()
    }
  }

  func denyPairing(
    userCode: String,
    profile: RelayProfile,
    controllerBearer: String
  ) async throws {
    calls.append(.deny(profile.id, userCode, controllerBearer))
    if !denialResults.isEmpty {
      try denialResults.removeFirst().get()
    }
  }

  func fetchLatestSnapshots(
    profile: RelayProfile,
    controllerBearer: String
  ) async throws -> ControllerSnapshotListResponse {
    calls.append(.snapshots(profile.id, controllerBearer))
    guard !snapshotResults.isEmpty else {
      return ControllerSnapshotListResponse(observations: [])
    }
    return try snapshotResults.removeFirst().get()
  }

  func listDevices(
    profile: RelayProfile,
    controllerBearer: String
  ) async throws -> DeviceListResponse {
    calls.append(.devices(profile.id, controllerBearer))
    guard !deviceResults.isEmpty else {
      return DeviceListResponse(devices: [])
    }
    return try deviceResults.removeFirst().get()
  }

  func revokeDevice(
    deviceID: String,
    profile: RelayProfile,
    controllerBearer: String
  ) async throws {
    calls.append(.revoke(profile.id, deviceID, controllerBearer))
    if !revokeResults.isEmpty {
      try revokeResults.removeFirst().get()
    }
  }

  func deleteController(
    profile: RelayProfile,
    controllerBearer: String
  ) async throws {
    calls.append(.deleteController(profile.id, controllerBearer))
    if !controllerDeleteResults.isEmpty {
      try controllerDeleteResults.removeFirst().get()
    }
  }
}

@MainActor
private final class FakeRelayProfileStore: RelayProfilePersisting {
  private let loadedProfiles: Result<[RelayProfile], RelayProfileStoreError>
  private var saveErrors: [RelayProfileStoreError]
  private let operations: RelayPersistenceRecorder?
  private(set) var savedProfiles: [[RelayProfile]] = []

  init(
    loadedProfiles: Result<[RelayProfile], RelayProfileStoreError> = .success([]),
    saveErrors: [RelayProfileStoreError] = [],
    operations: RelayPersistenceRecorder? = nil
  ) {
    self.loadedProfiles = loadedProfiles
    self.saveErrors = saveErrors
    self.operations = operations
  }

  func load() throws -> [RelayProfile] {
    try loadedProfiles.get()
  }

  func save(_ profiles: [RelayProfile]) throws {
    operations?.record(.metadataSave)
    savedProfiles.append(profiles)
    if !saveErrors.isEmpty {
      throw saveErrors.removeFirst()
    }
  }
}

private final class FakeRelayCredentialStore: RelayControllerCredentialPersisting, @unchecked Sendable {
  private let lock = NSLock()
  private var tokens: [String: String]
  private let saveError: RelayControllerCredentialStoreError?
  private let loadError: RelayControllerCredentialStoreError?
  private var deleteErrors: [RelayControllerCredentialStoreError]
  private let reconcileError: RelayControllerCredentialStoreError?
  private let deleteAllError: RelayControllerCredentialStoreError?
  private let operations: RelayPersistenceRecorder?
  private(set) var reconciledReferences: Set<String>?
  private(set) var deleteAllCount = 0

  init(
    tokens: [String: String] = [:],
    saveError: RelayControllerCredentialStoreError? = nil,
    loadError: RelayControllerCredentialStoreError? = nil,
    deleteErrors: [RelayControllerCredentialStoreError] = [],
    reconcileError: RelayControllerCredentialStoreError? = nil,
    deleteAllError: RelayControllerCredentialStoreError? = nil,
    operations: RelayPersistenceRecorder? = nil
  ) {
    self.tokens = tokens
    self.saveError = saveError
    self.loadError = loadError
    self.deleteErrors = deleteErrors
    self.reconcileError = reconcileError
    self.deleteAllError = deleteAllError
    self.operations = operations
  }

  func save(_ controllerBearer: String, reference: String) throws {
    try lock.withLock {
      operations?.record(.credentialSave(reference))
      if let saveError { throw saveError }
      tokens[reference] = controllerBearer
    }
  }

  func load(reference: String) throws -> String {
    try lock.withLock {
      if let loadError { throw loadError }
      guard let token = tokens[reference] else {
        throw RelayControllerCredentialStoreError.missingCredential
      }
      return token
    }
  }

  func delete(reference: String) throws {
    try lock.withLock {
      operations?.record(.credentialDelete(reference))
      if !deleteErrors.isEmpty { throw deleteErrors.removeFirst() }
      tokens[reference] = nil
    }
  }

  func reconcile(retaining references: Set<String>) throws {
    try lock.withLock {
      if let reconcileError { throw reconcileError }
      reconciledReferences = references
    }
  }

  func deleteAll() throws {
    try lock.withLock {
      if let deleteAllError { throw deleteAllError }
      deleteAllCount += 1
      tokens.removeAll()
    }
  }

  func token(reference: String) -> String? {
    lock.withLock { tokens[reference] }
  }
}

@MainActor
private final class FakeManagedRelayEnrollmentStore: ManagedRelayEnrollmentPersisting {
  private(set) var isDisabled: Bool

  init(isDisabled: Bool = false) {
    self.isDisabled = isDisabled
  }

  func setDisabled(_ disabled: Bool) {
    isDisabled = disabled
  }
}

@MainActor
private final class FakeQuotaBarDefaultsResetter: QuotaBarDefaultsResetting {
  private(set) var deleteAllCount = 0

  func deleteAll() {
    deleteAllCount += 1
  }
}

private enum RelayPersistenceOperation: Equatable, Sendable {
  case credentialSave(String)
  case metadataSave
  case credentialDelete(String)
}

private final class RelayPersistenceRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [RelayPersistenceOperation] = []

  var values: [RelayPersistenceOperation] {
    lock.withLock { storage }
  }

  func record(_ operation: RelayPersistenceOperation) {
    lock.withLock { storage.append(operation) }
  }
}

private actor RelaySleepProbe {
  private(set) var durations: [Duration] = []
  private(set) var cancellationCount = 0

  func sleep(_ duration: Duration) async throws {
    durations.append(duration)
    do {
      try await Task.sleep(for: .seconds(60))
    } catch is CancellationError {
      cancellationCount += 1
      throw CancellationError()
    }
  }
}

private func waitForCancellationCount(_ expected: Int, probe: RelaySleepProbe) async throws {
  for _ in 0..<100 {
    if await probe.cancellationCount >= expected { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Polling did not cancel its sleeper.")
}

private func waitForSleepCount(_ expected: Int, probe: RelaySleepProbe) async throws {
  for _ in 0..<100 {
    if await probe.durations.count >= expected { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Polling did not reach the expected sleep cycle.")
}

private func sampleRelayProfile(
  id: UUID,
  host: String = "relay.example",
  mode: RelayMode = .selfHosted,
  isDefault: Bool = false
) throws -> RelayProfile {
  try RelayProfile(
    id: id,
    name: host,
    baseURL: URL(string: "https://\(host)")!,
    instanceID: "instance_\(id.uuidString.lowercased())",
    mode: mode,
    capabilities: mode == .managed ? sampleManagedRelayCapabilities : sampleRelayCapabilities,
    isDefault: isDefault
  )
}

private func sampleRelayInfo() -> RelayInfo {
  RelayInfo(
    instanceID: "relay_primary",
    mode: .selfHosted,
    version: "0.1.0",
    apiVersions: [1],
    authMethods: ["bearer"],
    capabilities: sampleRelayCapabilities
  )
}

private func sampleObservation(deviceID: String, sequence: Int) throws -> ControllerSnapshotObservation {
  let data = Data(
    #"{"observations":[{"device_id":"\#(deviceID)","sequence":\#(sequence),"captured_at":"2026-08-03T10:20:30Z","snapshot":{"provider":"codex","account":{"fingerprint":"account_synthetic","fingerprint_scope":"global"},"windows":[{"id":"weekly","title":"Weekly","used_percent":20}],"source":"synthetic","status":"available","observed_at":"2026-08-03T10:20:30Z"},"updated_at":"2026-08-03T10:20:31Z"}]}"#.utf8
  )
  let response = try QuotaWireCodec.makeDecoder().decode(
    ControllerSnapshotListResponse.self,
    from: data
  )
  return try #require(response.observations.first)
}

private func sampleDevice(deviceID: String, sequence: Int) throws -> RelayDevice {
  let data = Data(
    #"{"devices":[{"device_id":"\#(deviceID)","display_name":"Synthetic Mac","created_at":"2026-08-03T10:20:30Z","last_seen_at":"2026-08-03T10:20:31Z","last_sequence":\#(sequence),"revoked_at":null}]}"#.utf8
  )
  let response = try QuotaWireCodec.makeDecoder().decode(DeviceListResponse.self, from: data)
  return try #require(response.devices.first)
}

private let profileID1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
private let profileID2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
private let syntheticControllerBearer = "controller_synthetic_0123456789"
private let sampleRelayCapabilities = RelayCapabilities(
  realtime: false,
  persistentSnapshots: true,
  instantDeviceRevocation: true,
  history: false,
  multiTenant: false
)
private let sampleManagedRelayCapabilities = RelayCapabilities(
  realtime: false,
  persistentSnapshots: true,
  instantDeviceRevocation: true,
  history: false,
  multiTenant: true
)
