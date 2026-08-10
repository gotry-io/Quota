import Foundation

private struct CachedAccountSync: Codable {
  let output: CLIAccountSyncOutput
  let refreshedAt: Date
}

/// Last-known credential-free CLI output used to paint the panel before the first sync completes.
struct LocalQuotaReportCache {
  static let storageKey = "accountSync.v2"
  private let defaults: UserDefaults

  static var live: LocalQuotaReportCache {
    LocalQuotaReportCache(defaults: .standard)
  }

  init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  func load() -> (output: CLIAccountSyncOutput, refreshedAt: Date)? {
    guard let data = defaults.data(forKey: Self.storageKey),
      let cached = try? QuotaWireCodec.makeDecoder().decode(CachedAccountSync.self, from: data)
    else { return nil }
    return (cached.output, cached.refreshedAt)
  }

  func save(output: CLIAccountSyncOutput, refreshedAt: Date) {
    let cached = CachedAccountSync(output: output, refreshedAt: refreshedAt)
    guard let data = try? QuotaWireCodec.makeEncoder().encode(cached) else { return }
    defaults.set(data, forKey: Self.storageKey)
  }

  func clear() {
    defaults.removeObject(forKey: Self.storageKey)
  }
}
