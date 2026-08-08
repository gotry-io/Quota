import Foundation
import Testing

@testable import QuotaBar

@Suite
@MainActor
struct ProviderConfigStoreTests {
  @Test
  func savesMaskedStatusAndClearsWithoutLeavingSecretsInStatus() throws {
    let directory = try ownerOnlyTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("providers.json")
    let store = ProviderConfigStore(fileURL: fileURL)
    #expect(store.status(for: .openrouter) == .missing)

    let secret = "sk-or-v1-menubar-fixture-secret"
    try store.setApiKey(.openrouter, apiKey: secret)
    guard case .configured(let mask) = store.status(for: .openrouter) else {
      Issue.record("expected configured status")
      return
    }
    #expect(mask.contains("···"))
    #expect(!mask.contains(secret))

    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)

    let raw = try String(contentsOf: fileURL, encoding: .utf8)
    #expect(raw.contains(secret))
    #expect(raw.contains("schema_version"))

    try store.clear(.openrouter)
    #expect(store.status(for: .openrouter) == .missing)
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
  }

  @Test
  func normalizesAndRejectsInvalidBaseURLsLikeCLI() throws {
    #expect(
      ProviderConfigStore.normalizeBaseURL("https://openrouter.ai/api/v1/", allowPrivateHttp: false)
        == "https://openrouter.ai/api/v1"
    )
    #expect(
      ProviderConfigStore.normalizeBaseURL("http://evil.example", allowPrivateHttp: false) == nil
    )
    #expect(
      ProviderConfigStore.normalizeBaseURL("http://127.0.0.1:4000", allowPrivateHttp: true)
        == "http://127.0.0.1:4000"
    )
    #expect(
      ProviderConfigStore.normalizeBaseURL("http://127.0.0.1:4000", allowPrivateHttp: false) == nil
    )

    let directory = try ownerOnlyTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ProviderConfigStore(fileURL: directory.appendingPathComponent("providers.json"))
    #expect(throws: ProviderConfigStoreError.invalidBaseURL) {
      try store.setApiKey(.openrouter, apiKey: "sk-or-v1-x", baseURL: "http://evil.example")
    }
    #expect(throws: ProviderConfigStoreError.missingBaseURL) {
      try store.setApiKey(.litellm, apiKey: "sk-litellm-x", baseURL: nil)
    }
    try store.setApiKey(.litellm, apiKey: "sk-litellm-x", baseURL: "http://192.168.1.10:4000/v1")
    #expect(store.baseURL(for: .litellm) == "http://192.168.1.10:4000/v1")
  }

  @Test
  func updatesBaseURLWithoutReenteringApiKey() throws {
    let directory = try ownerOnlyTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("providers.json")
    let store = ProviderConfigStore(fileURL: fileURL)
    let secret = "sk-litellm-menubar-base-url-fixture"
    try store.setApiKey(.litellm, apiKey: secret, baseURL: "https://proxy.example")
    #expect(store.baseURL(for: .litellm) == "https://proxy.example")

    try store.updateBaseURL(.litellm, baseURL: "https://proxy.example/v1")
    #expect(store.baseURL(for: .litellm) == "https://proxy.example/v1")
    guard case .configured = store.status(for: .litellm) else {
      Issue.record("key must remain configured after base URL update")
      return
    }

    try store.updateBaseURL(.litellm, baseURL: "https://proxy.example/next")
    #expect(store.baseURL(for: .litellm) == "https://proxy.example/next")
    #expect(throws: ProviderConfigStoreError.missingKey) {
      try store.updateBaseURL(.deepseek, baseURL: "https://example")
    }
  }

  @Test
  func refusesToOverwriteCorruptConfig() throws {
    let directory = try ownerOnlyTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("providers.json")
    // Corrupt schema so load fails; setApiKey must not wipe the file.
    try #"{"schema_version":99,"providers":{"openrouter":{"api_key":"sk-or-v1-keep-me"}}}"#
      .write(to: fileURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

    let store = ProviderConfigStore(fileURL: fileURL)
    #expect(store.status(for: .openrouter) == .unreadable)
    #expect(throws: ProviderConfigStoreError.invalid) {
      try store.setApiKey(.openrouter, apiKey: "sk-or-v1-new")
    }
    let raw = try String(contentsOf: fileURL, encoding: .utf8)
    #expect(raw.contains("sk-or-v1-keep-me"))
    #expect(!raw.contains("sk-or-v1-new"))
  }

  @Test
  func refusesGroupReadableConfigFile() throws {
    let directory = try ownerOnlyTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("providers.json")
    try #"{"schema_version":1,"providers":{"openrouter":{"api_key":"sk-or-v1-secret"}}}"#
      .write(to: fileURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fileURL.path)

    let store = ProviderConfigStore(fileURL: fileURL)
    #expect(store.status(for: .openrouter) == .unreadable)
    #expect(throws: ProviderConfigStoreError.insecurePermissions) {
      try store.setApiKey(.openrouter, apiKey: "sk-or-v1-new")
    }
  }

  @Test
  func recoversWriteLockWhoseOwnerProcessNoLongerExists() throws {
    let directory = try ownerOnlyTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let fileURL = directory.appendingPathComponent("providers.json")
    let lockURL = URL(fileURLWithPath: "\(fileURL.path).lock", isDirectory: true)
    try FileManager.default.createDirectory(
      at: lockURL,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    try "2147483647\n".write(
      to: lockURL.appendingPathComponent("owner"),
      atomically: false,
      encoding: .utf8
    )

    let store = ProviderConfigStore(fileURL: fileURL)
    try store.setApiKey(.openrouter, apiKey: "sk-or-v1-after-stale-lock")
    #expect(store.status(for: .openrouter) != .missing)
  }

  private func ownerOnlyTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("quota-provider-config-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700],
      ofItemAtPath: directory.path
    )
    return directory
  }
}
