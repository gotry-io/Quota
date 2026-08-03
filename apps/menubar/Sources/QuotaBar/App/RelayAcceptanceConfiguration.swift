#if VISUAL_TEST
  import AppKit
  import Foundation

  struct RelayAcceptanceConfiguration {
    static let flag = "--relay-acceptance-origin"

    enum Mode: String {
      case selfHosted = "self-hosted"
      case managed
    }

    let mode: Mode
    let relayOrigin: String
    let controllerTokenPath: URL?
    let coordinationDirectory: URL
    let defaultsSuite: String
    let keychainService: String
    let screenshotOutputPath: URL

    init?(arguments: [String]) {
      guard
        let relayOriginInput = Self.value(for: Self.flag, in: arguments),
        let relayURL = try? RelayOrigin.canonicalURL(from: relayOriginInput),
        let mode = Self.value(for: "--relay-acceptance-mode", in: arguments)
          .flatMap(Mode.init(rawValue:)),
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
        keychainService.hasPrefix("io.gotry.quotabar.relay-controller.e2e."),
        let screenshotOutputPath = Self.absolutePath(for: "--screenshot-output", in: arguments)
      else {
        return nil
      }

      let controllerTokenPath = Self.absolutePath(
        for: "--relay-acceptance-controller-token-file",
        in: arguments
      )
      guard mode == .managed || controllerTokenPath != nil else { return nil }

      self.mode = mode
      self.relayOrigin = relayURL.absoluteString
      self.controllerTokenPath = controllerTokenPath
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
      let managedRelayConfiguration: ManagedRelayConfiguration? =
        switch mode {
        case .selfHosted: nil
        case .managed:
          ManagedRelayConfiguration(
            name: "E2E Managed",
            baseURL: URL(string: relayOrigin)!
          )
        }
      return RelayStateModel(
        client: RelayClient(transport: URLSessionRelayHTTPTransport()),
        profileStore: RelayProfileStore(defaults: defaults),
        credentialStore: credentialStore,
        managedEnrollmentStore: ManagedRelayEnrollmentStore(defaults: defaults),
        managedRelayConfiguration: managedRelayConfiguration
      )
    }

    var defaults: UserDefaults {
      guard let defaults = UserDefaults(suiteName: defaultsSuite) else {
        preconditionFailure("Invalid Relay acceptance defaults suite.")
      }
      return defaults
    }

    var credentialStore: RelayControllerCredentialStore {
      RelayControllerCredentialStore(
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
        Task { @MainActor in
          await fail(configuration: configuration, model: model, profileID: nil)
        }
        return
      }

      Task { @MainActor in
        var profileID: UUID?
        do {
          let profile: RelayProfile
          switch configuration.mode {
          case .selfHosted:
            guard let controllerTokenPath = configuration.controllerTokenPath else {
              throw RelayAcceptanceError.invalidInput
            }
            let controllerToken = try readSmallText(from: controllerTokenPath, limit: 4_096)
            profile = try await model.relayStateModel.addSelfHostedProfile(
              name: "E2E Self-Hosted",
              origin: configuration.relayOrigin,
              controllerBearer: controllerToken
            )
            try FileManager.default.removeItem(at: controllerTokenPath)
          case .managed:
            await model.relayStateModel.ensureManagedControllerProfile()
            guard model.relayStateModel.profiles.count == 1,
              let managedProfile = model.relayStateModel.profiles.first,
              managedProfile.mode == .managed
            else {
              throw RelayAcceptanceError.validationFailed
            }
            profile = managedProfile
          }
          profileID = profile.id

          let controllerToken = try configuration.credentialStore.load(
            reference: profile.credentialReference
          )
          guard !controllerToken.isEmpty else {
            throw RelayAcceptanceError.validationFailed
          }
          try writeJSON(
            [
              "mode": configuration.mode.rawValue,
              "profile_id": profile.id.uuidString,
              "relay_origin": profile.baseURL.absoluteString,
            ],
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
              == controllerToken
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
          guard
            model.relayStateModel.state(for: profile.id)?.devices.contains(where: {
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
          try await model.relayStateModel.deleteProfile(profile.id)
          profileID = nil
          if configuration.mode == .managed {
            do {
              _ = try await RelayClient(transport: URLSessionRelayHTTPTransport())
                .fetchLatestSnapshots(
                  profile: profile,
                  controllerBearer: controllerToken
                )
              throw RelayAcceptanceError.validationFailed
            } catch let error as RelayClientError where error.category == .authentication {
              // The deleted managed controller token must no longer authorize remote reads.
            }
          }
          guard configuration.makeRelayStateModel().profiles.isEmpty else {
            throw RelayAcceptanceError.validationFailed
          }
          do {
            _ = try configuration.credentialStore.load(reference: profile.credentialReference)
            throw RelayAcceptanceError.validationFailed
          } catch RelayControllerCredentialStoreError.missingCredential {
            // Expected after deleting the profile.
          }
          configuration.defaults.removePersistentDomain(forName: configuration.defaultsSuite)
          try writeJSON(
            ["cleaned": true, "mode": configuration.mode.rawValue],
            to: configuration.file("completed.json")
          )
          NSApplication.shared.terminate(nil)
        } catch {
          await fail(configuration: configuration, model: model, profileID: profileID)
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

      guard
        case .content(let providers, let warning) = model.overviewState(
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
    ) async {
      if let profileID {
        try? await model.relayStateModel.deleteProfile(profileID)
        try? configuration.credentialStore.delete(
          reference: RelayControllerCredentialStore.reference(for: profileID)
        )
      }
      configuration.defaults.removePersistentDomain(forName: configuration.defaultsSuite)
      if let controllerTokenPath = configuration.controllerTokenPath {
        try? FileManager.default.removeItem(at: controllerTokenPath)
      }
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
