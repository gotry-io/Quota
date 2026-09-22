import Foundation
import QuotaPresentation

/// Stand-in for the K2s symbols `QuotaHistorySync`, `QuotaHistorySource`, and
/// `QuotaHistoryCopy.sourceCaption`. Delete this file when that package is merged;
/// call sites keep these names.
enum QuotaHistorySource: Sendable {
  case thisDevice
  case yourDevices
}

extension QuotaHistoryCopy {
  static func sourceCaption(_ source: QuotaHistorySource, deviceNoun: String) -> String {
    switch source {
    case .thisDevice: deviceNoun
    case .yourDevices: "From your devices"
    }
  }
}

enum QuotaHistorySync {
  struct Bucket: Codable, Equatable, Sendable {
    let resetsAt: Date
    let bucketStart: Date
    let usedPercent: Double
  }

  /// Buckets become samples (`observedAt` = `bucketStart`) so `QuotaRemainingHistory.fold`
  /// is unchanged.
  static func samples(from buckets: [Bucket]) -> [QuotaSample] {
    buckets.map { bucket in
      QuotaSample(
        resetsAt: bucket.resetsAt,
        observedAt: bucket.bucketStart,
        usedPercent: bucket.usedPercent
      )
    }
  }
}
