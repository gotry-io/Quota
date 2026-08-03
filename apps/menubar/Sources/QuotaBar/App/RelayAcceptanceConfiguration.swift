#if VISUAL_TEST
  import AppKit
  import Foundation

  struct RelayAcceptanceConfiguration {
    static let flag = "--relay-acceptance-origin"

    let relayOrigin: String
    let ownerTokenPath: URL
    let coordinationDirectory: URL
    let defaultsSuite: String
    let keychainService: String
    let screenshotOutputPath: URL

    init?(arguments: [String]) {
      guard
        let relayOrigin = Self.value(for: Self.flag, in: arguments),
        let ownerTokenPath = Self.absolutePath(
          for: "--relay-acceptance-owner-token-file",
          in: arguments
        ),
        let coordinationDirectory = Self.absolutePath(
          for: "--relay-acceptance-directory",
          in: arguments
        ),
        let defaultsSuite = Self.value(for: "--relay-acceptance-defaults-suite", in: arguments),
        defaultsSuite.hasPrefix("io.gotry.quotabar.e2e."),
        let keychainService = Self.value(
          for: "--relay-acceptance-keychain-service",
          in: arguments
        ),
        keychainService.hasPrefix("io.gotry.quotabar.relay-owner.e2e."),
        let screenshotOutputPath = Self.absolutePath(for: "--screenshot-output", in: arguments)
      else {
        return nil
      }

      self.relayOrigin = relayOrigin
      self.ownerTokenPath = ownerTokenPath
      self.coordinationDirectory = coordinationDirectory
      self.defaultsSuite = defaultsSuite
      self.keychainService = keychainService
      self.screenshotOutputPath = screenshotOutputPath
    }

    @MainActor
    func makeModel() -> MenuBarViewModel {
      MenuBarViewModel(
        reportCache: nil,
        relayStateModel: makeRelayStateModel()
      )
    }

    @MainActor
    func makeRelayStateModel() -> RelayStateModel {
      RelayStateModel(
        client: RelayClient(transport: URLSessionRelayHTTPTransport()),
        profileStore: RelayProfileStore(defaults: defaults),
        credentialStore: credentialStore
      )
    }

    var defaults: UserDefaults {
      guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
        preconditionFailure("Invalid Relay acceptance defaults suite.")
      }
      return defaults
    }

    var credentialStore: RelayOwnerCredentialStore {
      RelayOwnerCredentialStore(
        operations: SystemRelayKeychainOperations(),
        service: keychainService
      )
    }

    func file(_ name: String) -> URL {
      coordinationDirectory.appendingPathComponent(name, isDirectory: false)
    }

    private static func value(for flag: String, in arguments: [String]) -> String? {
      guard let index = arguments.firstIndex(of: flag) else { return nil }
      let valueIndex = arguments.index(after: index)
      guard valueIndex < arguments.endIndex else { return nil }
      let value = arguments[valueIndex]
      guard !value.isEmpty else { return nil }
      return value
    }

    private static func absolutePath(for flag: String, in arguments: [String]) -> URL? {
      guard let value = value(for: flag, in: arguments),
        (value as NSString).isAbsolutePath
      else {
        return nil
      }
      return URL(fileURLWithPath: value)
    }
  }

  @MainActor
  enum RelayAcceptanceRunner {
    private static var hasStarted = false
    private static let timeout: Duration = .seconds(30)

    static func start(
      configuration: RelayAcceptanceConfiguration,
      model: MenuBarViewModel
    ) {
      guard !hasStarted else { return }
      hasStarted = true

      do {
        try writeText(
          String(ProcessInfo.processInfo.processIdentifier),
          to: configuration.file("app.pid")
        )
      } catch {
        fail(configuration: configuration, model: model, profileID: nil)
        return
      }

      Task { @MainActor in
        var profileID: UUID?
        do {
          let ownerToken = try readSmallText(from: configuration.ownerTokenPath, limit: 4_096)
          let profile = try await model.relayStateModel.addSelfHostedProfile(
            name: "E2E Self-Hosted",
            origin: configuration.relayOrigin,
            ownerBearer: ownerToken
          )
          profileID = profile.id
          try FileManager.default.removeItem(at: configuration.ownerTokenPath)

          guard try configuration.credentialStore.load(reference: profile.credentialReference)
            == ownerToken
          else {
            throw RelayAcceptanceError.validationFailed
          }
          try writeJSON(
            ["profile_id": profile.id.uuidString, "relay_origin": profile.baseURL.absoluteString],
            to: configuration.file("ready.json")
          )

          let pairingCodePath = configuration.file("pairing-code.txt")
          try await waitForNonemptyFile(
            pairingCodePath,
            cancellationPath: configuration.file("cancel")
          )
          let pairingCode = try readSmallText(from: pairingCodePath, limit: 128)
          try? FileManager.default.removeItem(at: pairingCodePath)
          try await model.relayStateModel.approvePairing(
            profileID: profile.id,
            userCode: pairingCode
          )
          try writeText("approved", to: configuration.file("pairing-approved"))

          try await waitForNonemptyFile(
            configuration.file("report-ready"),
            cancellationPath: configuration.file("cancel")
          )
          await model.relayStateModel.refreshProfile(profile.id)
          let result = try validateRemoteState(
            model: model,
            profileID: profile.id,
            relayInstanceID: profile.instanceID
          )

          let restoredModel = configuration.makeRelayStateModel()
          guard restoredModel.profiles.map(\.id) == [profile.id],
            try configuration.credentialStore.load(reference: profile.credentialReference)
              == ownerToken
          else {
            throw RelayAcceptanceError.validationFailed
          }
          await restoredModel.refreshProfile(profile.id)
          guard restoredModel.state(for: profile.id)?.observations.count == 1 else {
            throw RelayAcceptanceError.validationFailed
          }

          VisualTestWindowCapture.schedule(to: configuration.screenshotOutputPath)
          try await waitForNonemptyFile(
            configuration.screenshotOutputPath,
            cancellationPath: configuration.file("cancel")
          )
          try writeJSON(
            result.merging(["restored": true]) { _, new in new },
            to: configuration.file("snapshot.json")
          )

          try await waitForNonemptyFile(
            configuration.file("revoke-request"),
            cancellationPath: configuration.file("cancel")
          )
          guard let deviceID = result["device_id"] as? String else {
            throw RelayAcceptanceError.validationFailed
          }
          try await model.relayStateModel.revokeDevice(
            profileID: profile.id,
            deviceID: deviceID
          )
          guard model.relayStateModel.state(for: profile.id)?.devices.contains(where: {
            $0.deviceID == deviceID && $0.revokedAt != nil
          }) == true
          else {
            throw RelayAcceptanceError.validationFailed
          }
          try writeText("revoked", to: configuration.file("revoked"))

          try await waitForNonemptyFile(
            configuration.file("rejection-confirmed"),
            cancellationPath: configuration.file("cancel")
          )
          try model.relayStateModel.deleteProfile(profile.id)
          profileID = nil
          guard configuration.makeRelayStateModel().profiles.isEmpty else {
            throw RelayAcceptanceError.validationFailed
          }
          do {
            _ = try configuration.credentialStore.load(reference: profile.credentialReference)
            throw RelayAcceptanceError.validationFailed
          } catch RelayOwnerCredentialStoreError.missingCredential {
            // Expected after deleting the profile.
          }
          configuration.defaults.removePersistentDomain(forName: configuration.defaultsSuite)
          try writeJSON(["cleaned": true], to: configuration.file("completed.json"))
          NSApplication.shared.terminate(nil)
        } catch {
          fail(configuration: configuration, model: model, profileID: profileID)
        }
      }
    }

    private static func validateRemoteState(
      model: MenuBarViewModel,
      profileID: UUID,
      relayInstanceID: String
    ) throws -> [String: Any] {
      guard let state = model.relayStateModel.state(for: profileID),
        state.refreshIssue == nil,
        state.observations.count == 1,
        let observation = state.observations.first,
        observation.snapshot.provider == .codex,
        observation.snapshot.account.fingerprint == "e2e-codex-account",
        let window = observation.snapshot.windows.first,
        window.id == "five_hour",
        window.usedPercent == 42,
        window.remainingPercent == 58,
        let device = state.devices.first(where: { $0.deviceID == observation.deviceID }),
        device.revokedAt == nil,
        device.lastSequence == 0
      else {
        throw RelayAcceptanceError.validationFailed
      }

      guard case .content(let providers, let warning) = model.overviewState(
        enabledProviders: [.codex]
      ), warning == nil,
        let account = providers.first?.accounts.first,
        account.identity.fingerprint == "e2e-codex-account",
        account.sourceSummary == "Remote",
        account.selectedSource
          == .remote(relayInstanceID: relayInstanceID, deviceID: observation.deviceID)
      else {
        throw RelayAcceptanceError.validationFailed
      }

      return [
        "device_id": observation.deviceID,
        "fingerprint": account.identity.fingerprint,
        "provider": account.identity.provider.rawValue,
        "remaining_percent": window.remainingPercent,
        "source": account.sourceSummary,
        "used_percent": window.usedPercent,
        "window_id": window.id,
      ]
    }

    private static func fail(
      configuration: RelayAcceptanceConfiguration,
      model: MenuBarViewModel,
      profileID: UUID?
    ) {
      if let profileID {
        try? model.relayStateModel.deleteProfile(profileID)
        try? configuration.credentialStore.delete(
          reference: RelayOwnerCredentialStore.reference(for: profileID)
        )
      }
      configuration.defaults.removePersistentDomain(forName: configuration.defaultsSuite)
      try? FileManager.default.removeItem(at: configuration.ownerTokenPath)
      try? writeText("relay acceptance failed", to: configuration.file("failed"))
      fputs("relay acceptance failed\n", stderr)
      NSApplication.shared.terminate(nil)
    }

    private static func waitForNonemptyFile(
      _ url: URL,
      cancellationPath: URL
    ) async throws {
      let deadline = ContinuousClock.now + timeout
      while ContinuousClock.now < deadline {
        if FileManager.default.fileExists(atPath: cancellationPath.path) {
          throw CancellationError()
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let size = attributes[.size] as? NSNumber,
          size.intValue > 0
        {
          return
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw RelayAcceptanceError.timedOut
    }

    private static func readSmallText(from url: URL, limit: Int) throws -> String {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      guard let size = attributes[.size] as? NSNumber,
        size.intValue > 0,
        size.intValue <= limit
      else {
        throw RelayAcceptanceError.invalidInput
      }
      let value = try String(contentsOf: url, encoding: .utf8)
      guard !value.isEmpty,
        value == value.trimmingCharacters(in: .whitespacesAndNewlines)
      else {
        throw RelayAcceptanceError.invalidInput
      }
      return value
    }

    private static func writeText(_ value: String, to url: URL) throws {
      try Data(value.utf8).write(to: url, options: .atomic)
    }

    private static func writeJSON(_ value: [String: Any], to url: URL) throws {
      let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
      try data.write(to: url, options: .atomic)
    }
  }

  private enum RelayAcceptanceError: Error {
    case invalidInput
    case timedOut
    case validationFailed
  }
#endif
