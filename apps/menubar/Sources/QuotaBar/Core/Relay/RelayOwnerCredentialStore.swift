import Foundation

enum RelayOwnerCredentialStoreError: LocalizedError, Equatable, Sendable {
  case invalidCredential
  case missingCredential
  case corruptCredential
  case couldNotRead
  case couldNotStore
  case couldNotDelete

  var errorDescription: String? {
    switch self {
    case .invalidCredential:
      "QuotaBar's private Relay access is invalid."
    case .missingCredential:
      "QuotaBar's private access to this Relay is missing."
    case .corruptCredential:
      "QuotaBar's saved private Relay access is invalid."
    case .couldNotRead:
      "QuotaBar could not read its private Relay access."
    case .couldNotStore:
      "QuotaBar could not save its private Relay access."
    case .couldNotDelete:
      "QuotaBar could not delete its private Relay access."
    }
  }
}

/// User-only Application Support file for owner bearers. Never UserDefaults.
/// Mutations are serialized in-process so concurrent save/delete/reconcile cannot clobber each other.
final class RelayOwnerCredentialStore: @unchecked Sendable {
  static let fileName = "owners.json"
  static let applicationSupportDirectoryName = "io.gotry.quotabar"

  private let fileURL: URL
  private let lock = NSLock()

  init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? Self.defaultFileURL()
  }

  static func reference(for profileID: UUID) -> String {
    RelayProfile.credentialReference(for: profileID)
  }

  static func defaultFileURL() -> URL {
    let fileManager = FileManager.default
    let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.temporaryDirectory
    return root
      .appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
      .appendingPathComponent(fileName, isDirectory: false)
  }

  func save(_ ownerBearer: String, reference: String) throws {
    guard isValid(ownerBearer), isValidReference(reference) else {
      throw RelayOwnerCredentialStoreError.invalidCredential
    }
    try withLock {
      var document = try loadDocumentUnlocked()
      document.owners[reference] = ownerBearer
      try writeDocumentUnlocked(document)
    }
  }

  func load(reference: String) throws -> String {
    guard isValidReference(reference) else {
      throw RelayOwnerCredentialStoreError.missingCredential
    }
    return try withLock {
      let document = try loadDocumentUnlocked()
      guard let ownerBearer = document.owners[reference] else {
        throw RelayOwnerCredentialStoreError.missingCredential
      }
      guard isValid(ownerBearer) else {
        throw RelayOwnerCredentialStoreError.corruptCredential
      }
      return ownerBearer
    }
  }

  func delete(reference: String) throws {
    guard isValidReference(reference) else {
      throw RelayOwnerCredentialStoreError.missingCredential
    }
    try withLock {
      var document = try loadDocumentUnlocked()
      guard document.owners.removeValue(forKey: reference) != nil else {
        return
      }
      try writeDocumentUnlocked(document)
    }
  }

  func reconcile(retaining references: Set<String>) throws {
    try withLock {
      var document = try loadDocumentUnlocked()
      let orphans = Set(document.owners.keys).subtracting(references)
      guard !orphans.isEmpty else { return }
      for reference in orphans {
        document.owners.removeValue(forKey: reference)
      }
      try writeDocumentUnlocked(document)
    }
  }

  func deleteAll() throws {
    try withLock {
      let fileManager = FileManager.default
      guard fileManager.fileExists(atPath: fileURL.path) else { return }
      do {
        try fileManager.removeItem(at: fileURL)
      } catch {
        throw RelayOwnerCredentialStoreError.couldNotDelete
      }
    }
  }

  private func withLock<T>(_ body: () throws -> T) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
  }

  private func loadDocumentUnlocked() throws -> OwnersDocument {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return OwnersDocument(version: 1, owners: [:])
    }
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      throw RelayOwnerCredentialStoreError.couldNotRead
    }
    if data.isEmpty {
      return OwnersDocument(version: 1, owners: [:])
    }
    do {
      let document = try JSONDecoder().decode(OwnersDocument.self, from: data)
      guard document.version == 1 else {
        throw RelayOwnerCredentialStoreError.corruptCredential
      }
      return document
    } catch {
      throw RelayOwnerCredentialStoreError.corruptCredential
    }
  }

  private func writeDocumentUnlocked(_ document: OwnersDocument) throws {
    let fileManager = FileManager.default
    let directory = fileURL.deletingLastPathComponent()
    do {
      try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      throw RelayOwnerCredentialStoreError.couldNotStore
    }

    let data: Data
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      data = try encoder.encode(document)
    } catch {
      throw RelayOwnerCredentialStoreError.couldNotStore
    }

    let temporaryURL = directory.appendingPathComponent(
      "\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)",
      isDirectory: false
    )
    do {
      try data.write(to: temporaryURL, options: .withoutOverwriting)
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
      if fileManager.fileExists(atPath: fileURL.path) {
        _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
      } else {
        try fileManager.moveItem(at: temporaryURL, to: fileURL)
      }
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    } catch {
      try? fileManager.removeItem(at: temporaryURL)
      throw RelayOwnerCredentialStoreError.couldNotStore
    }
  }

  private func isValid(_ ownerBearer: String) -> Bool {
    !ownerBearer.isEmpty
      && ownerBearer == ownerBearer.trimmingCharacters(in: .whitespacesAndNewlines)
      && ownerBearer.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
  }

  private func isValidReference(_ reference: String) -> Bool {
    !reference.isEmpty
      && reference == reference.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private struct OwnersDocument: Codable, Equatable, Sendable {
  var version: Int
  var owners: [String: String]
}
