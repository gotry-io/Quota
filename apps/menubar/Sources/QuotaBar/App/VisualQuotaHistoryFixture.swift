#if DEBUG
  import Foundation
  import QuotaPresentation
  import QuotaWire

  /// Synthetic 7-day `quota_samples` for Visual QA. Not a production path.
  enum VisualQuotaHistoryFixture {
    static func samples(
      from report: QuotaCollectionReport,
      now: Date,
      days: Int = 7
    ) -> LocalServiceQuotaHistory {
      var samplesByProvider: [String: [String: [QuotaSample]]] = [:]
      for result in report.results {
        guard let snapshot = result.snapshots.first else { continue }
        var byWindow: [String: [QuotaSample]] = [:]
        for window in snapshot.windows {
          let points = samples(for: window, now: now, days: days)
          if !points.isEmpty {
            byWindow[window.id] = points
          }
        }
        if !byWindow.isEmpty {
          samplesByProvider[snapshot.provider.rawValue] = byWindow
        }
      }
      return LocalServiceQuotaHistory(
        samplesByProvider: samplesByProvider,
        utcOffsetSeconds: 0
      )
    }

    private static func samples(
      for window: QuotaWindow,
      now: Date,
      days: Int
    ) -> [QuotaSample] {
      guard let cadenceSeconds = window.durationSeconds, cadenceSeconds > 0,
        let currentReset = window.resetsAt
      else { return [] }
      let cadence = TimeInterval(cadenceSeconds)
      let horizon = now.addingTimeInterval(-TimeInterval(days) * 86_400)
      let step = min(15 * 60, max(cadence / 8, QuotaHistory.decimationSeconds))
      var result: [QuotaSample] = []
      var resetsAt = currentReset
      var isCurrent = true
      while resetsAt > horizon {
        let startedAt = resetsAt.addingTimeInterval(-cadence)
        let peak: Double
        if isCurrent {
          peak = window.usedPercent
        } else {
          let seed = Int(resetsAt.timeIntervalSince1970) & 0xffff
          peak = 25 + Double(seed % 56)
        }
        let end = min(resetsAt, now)
        guard end > startedAt else {
          resetsAt = startedAt
          isCurrent = false
          continue
        }
        let elapsedAtEnd = max(end.timeIntervalSince(startedAt) / cadence, 0.01)
        var instant = startedAt
        while instant <= end {
          if instant >= horizon {
            let elapsed = min(max(instant.timeIntervalSince(startedAt) / cadence, 0), 1)
            let used = min(
              100,
              max(0, peak * elapsed / (isCurrent ? elapsedAtEnd : 1))
            )
            result.append(
              QuotaSample(
                resetsAt: resetsAt,
                observedAt: instant,
                usedPercent: (used * 100).rounded() / 100
              )
            )
          }
          if instant == end { break }
          instant = min(instant.addingTimeInterval(step), end)
        }
        resetsAt = startedAt
        isCurrent = false
      }
      return result.sorted { $0.observedAt < $1.observedAt }
    }
  }
#endif
