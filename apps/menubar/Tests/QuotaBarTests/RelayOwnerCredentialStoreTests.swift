import Foundation
import Testing

@testable import QuotaBar

@Suite
struct RelayOwnerCredentialStoreTests {
  @Test
  func savesAndLoadsOwnerCredentialsFromAUserOnlyFile() throws {
    let fileURL = try temporaryOwnersFile()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = RelayOwnerCredentialStore(fileURL: fileURL)
    let reference = RelayOwnerCredentialStore.reference(
      for: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    )

    try store.save("owner_synthetic_secret", reference: reference)

    #expect(try store.load(reference: reference) == "owner_synthetic_secret")
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)
    let directoryAttributes = try FileManager.default.attributesOfItem(
      atPath: fileURL.deletingLastPathComponent().path
    )
    #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o700)

    let document = try decodeOwners(fileURL)
    #expect(document.version == 1)
    #expect(document.owners == [reference: "owner_synthetic_secret"])
  }

  @Test
  func tightensExistingDirectoryPermissionsOnSave() throws {
    let fileURL = try temporaryOwnersFile(directoryPermissions: 0o755)
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = RelayOwnerCredentialStore(fileURL: fileURL)
    let directory = fileURL.deletingLastPathComponent()

    let before = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((before[.posixPermissions] as? NSNumber)?.uint16Value == 0o755)

    try store.save("owner_synthetic_secret", reference: "relay-owner:profile")

    let after = try FileManager.default.attributesOfItem(atPath: directory.path)
    #expect((after[.posixPermissions] as? NSNumber)?.uint16Value == 0o700)
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    #expect((fileAttributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)
  }

  @Test
  func updatesExistingOwnerCredentialInPlace() throws {
    let fileURL = try temporaryOwnersFile()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = RelayOwnerCredentialStore(fileURL: fileURL)

    try store.save("owner_synthetic_secret", reference: "relay-owner:profile")
    try store.save("replacement_secret", reference: "relay-owner:profile")

    #expect(try store.load(reference: "relay-owner:profile") == "replacement_secret")
    #expect(try decodeOwners(fileURL).owners.count == 1)
  }

  @Test
  func deletesOnlyTheReferencedOwnerCredential() throws {
    let fileURL = try temporaryOwnersFile()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = RelayOwnerCredentialStore(fileURL: fileURL)

    try store.save("owner_kept", reference: "relay-owner:kept")
    try store.save("owner_drop", reference: "relay-owner:drop")
    try store.delete(reference: "relay-owner:drop")

    #expect(try store.load(reference: "relay-owner:kept") == "owner_kept")
    #expect(throws: RelayOwnerCredentialStoreError.missingCredential) {
      try store.load(reference: "relay-owner:drop")
    }
  }

  @Test
  func reconcilesOwnerCredentialsByDeletingOnlyOrphanedRecords() throws {
    let fileURL = try temporaryOwnersFile()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = RelayOwnerCredentialStore(fileURL: fileURL)

    try store.save("owner_kept", reference: "relay-owner:kept")
    try store.save("owner_orphan", reference: "relay-owner:orphan")
    try store.reconcile(retaining: ["relay-owner:kept"])

    #expect(try store.load(reference: "relay-owner:kept") == "owner_kept")
    #expect(throws: RelayOwnerCredentialStoreError.missingCredential) {
      try store.load(reference: "relay-owner:orphan")
    }
  }

  @Test
  func deletesAllOwnerCredentialsByRemovingTheFile() throws {
    let fileURL = try temporaryOwnersFile()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = RelayOwnerCredentialStore(fileURL: fileURL)

    try store.save("owner_synthetic_secret", reference: "relay-owner:profile")
    try store.deleteAll()

    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    #expect(throws: RelayOwnerCredentialStoreError.missingCredential) {
      try store.load(reference: "relay-owner:profile")
    }
  }

  @Test
  func reportsFixedMissingAndCorruptCredentialErrors() throws {
    let missingURL = try temporaryOwnersFile()
    defer { try? FileManager.default.removeItem(at: missingURL.deletingLastPathComponent()) }
    #expect(throws: RelayOwnerCredentialStoreError.missingCredential) {
      try RelayOwnerCredentialStore(fileURL: missingURL).load(reference: "relay-owner:p")
    }

    let corruptURL = try temporaryOwnersFile()
    defer { try? FileManager.default.removeItem(at: corruptURL.deletingLastPathComponent()) }
    try Data("{not-json".utf8).write(to: corruptURL)
    #expect(throws: RelayOwnerCredentialStoreError.corruptCredential) {
      try RelayOwnerCredentialStore(fileURL: corruptURL).load(reference: "relay-owner:p")
    }
  }

  @Test
  func rejectsCredentialsWithSurroundingWhitespace() throws {
    let fileURL = try temporaryOwnersFile()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = RelayOwnerCredentialStore(fileURL: fileURL)

    #expect(throws: RelayOwnerCredentialStoreError.invalidCredential) {
      try store.save(" owner_synthetic_secret", reference: "relay-owner:p")
    }
    #expect(!FileManager.default.fileExists(atPath: fileURL.path))
  }
}

private struct OwnersFileDocument: Decodable {
  var version: Int
  var owners: [String: String]
}

private func temporaryOwnersFile(directoryPermissions: Int? = nil) throws -> URL {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("quotabar-owners-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  if let directoryPermissions {
    try FileManager.default.setAttributes(
      [.posixPermissions: directoryPermissions],
      ofItemAtPath: directory.path
    )
  }
  return directory.appendingPathComponent("owners.json", isDirectory: false)
}

private func decodeOwners(_ fileURL: URL) throws -> OwnersFileDocument {
  try JSONDecoder().decode(OwnersFileDocument.self, from: Data(contentsOf: fileURL))
}
