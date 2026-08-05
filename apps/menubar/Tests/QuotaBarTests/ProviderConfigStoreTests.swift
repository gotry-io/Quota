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
