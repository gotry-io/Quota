import Foundation
import QuotaKeychain
import QuotaWire
import Security
#if canImport(UIKit)
  import UIKit
#endif

/// What this phone calls itself when it asks to be a Device.
///
/// The installation id is this device's own name for itself on this Account, and it is what makes
/// signing in twice one Device rather than two
/// ([ADR 0041](../../../docs/decisions/0041-ios-is-a-device-when-sync-is-paid.md)). It lives in
/// the Keychain, device-only and not synchronized, because a restore onto a second phone that
/// carried it would make two phones one Device.
protocol InstallationIdentifying: Sendable {
  /// The id this installation has, minting one the first time it is asked for.
  func identifier() throws -> String
}

enum InstallationIdentityError: Error, Equatable {
  case unreadable
  case unwritable
}

struct KeychainInstallationIdentity: InstallationIdentifying {
  let service: String
  let account: String
  private let keychain: any KeychainOperating
  private let mint: @Sendable () -> String

  init(
    service: String = "io.gotry.quota.installation",
    account: String = "installation-id",
    keychain: any KeychainOperating = SecurityKeychain(),
    mint: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() }
  ) {
    self.service = service
    self.account = account
    self.keychain = keychain
    self.mint = mint
  }

  func identifier() throws -> String {
    if let stored = try read() { return stored }
    let minted = mint()
    try write(minted)
    // A concurrent first launch could have written one between the read and the add; the item
    // that won is the installation, so it is read back rather than assumed.
    return try read() ?? minted
  }

  private func read() throws -> String? {
    let (status, data) = keychain.copyMatching([
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ])
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data,
      let value = String(data: data, encoding: .utf8),
      WireValidation.isUUID(value)
    else {
      throw InstallationIdentityError.unreadable
    }
    return value
  }

  private func write(_ value: String) throws {
    let status = keychain.add([
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecValueData as String: Data(value.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    ])
    guard status == errSecSuccess || status == errSecDuplicateItem else {
      throw InstallationIdentityError.unwritable
    }
  }
}

final class MemoryInstallationIdentity: InstallationIdentifying, @unchecked Sendable {
  private let lock = NSLock()
  private var value: String?

  init(value: String? = nil) {
    self.value = value
  }

  func identifier() throws -> String {
    lock.lock()
    defer { lock.unlock() }
    if let value { return value }
    let minted = UUID().uuidString.lowercased()
    value = minted
    return minted
  }
}

/// This phone as a Device: the installation it holds, and the name the Account lists it under.
///
/// The name is what the system calls this device. iOS answers a model name rather than the one
/// its owner typed unless the app is entitled to the real one, and either is a name a person
/// recognises in a list of their Macs.
enum ThisIPhone {
  static func registration(
    identity: any InstallationIdentifying,
    displayName: String = deviceName()
  ) -> IosDeviceRegistration? {
    guard let installationID = try? identity.identifier() else { return nil }
    return IosDeviceRegistration(installationID: installationID, displayName: displayName)
  }

  static func deviceName() -> String {
    #if canImport(UIKit)
      let name = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
      return name.isEmpty ? "iPhone" : String(name.prefix(128))
    #else
      return "iPhone"
    #endif
  }
}
