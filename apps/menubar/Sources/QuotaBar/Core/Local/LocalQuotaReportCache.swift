import Foundation

private struct CachedQuotaReport: Codable {
  let report: QuotaCollectionReport
  let refreshedAt: Date
}

struct LocalQuotaReportCache {
  static let storageKey = "localQuotaReport.v1"
  private let defaults: UserDefaults

  static var live: LocalQuotaReportCache {
    LocalQuotaReportCache(defaults: .standard)
  }

  init(defaults: UserDefaults) {
    self.defaults = defaults
  }

  func load() -> (report: QuotaCollectionReport, refreshedAt: Date)? {
    guard let data = defaults.data(forKey: Self.storageKey),
      let cached = try? QuotaWireCodec.makeDecoder().decode(CachedQuotaReport.self, from: data),
      cached.report.schemaVersion == 1
    else {
      return nil
    }
    return (cached.report, cached.refreshedAt)
  }

  func save(report: QuotaCollectionReport, refreshedAt: Date) {
    let cached = CachedQuotaReport(report: report, refreshedAt: refreshedAt)
    guard let data = try? QuotaWireCodec.makeEncoder().encode(cached) else { return }
    defaults.set(data, forKey: Self.storageKey)
  }
}
