import AppKit
import SnapshotTesting
import SwiftUI
import Testing

@testable import QuotaBar

@Test @MainActor
func menuBarOverviewSnapshots() throws {
  try assertOverviewSnapshot(fixture: "content", name: "content-light", colorScheme: .light)
  try assertOverviewSnapshot(fixture: "empty", name: "empty-dark", colorScheme: .dark)
}

@MainActor
private func assertOverviewSnapshot(
  fixture: String,
  name: String,
  colorScheme: ColorScheme
) throws {
  let referenceDate = Date(timeIntervalSince1970: 1_785_752_430)
  let configuration = try #require(
    VisualTestConfiguration(
      arguments: ["--data-source", "fixture", "--fixture", fixture],
      referenceDate: referenceDate
    )
  )
  configuration.prepareEnvironment()
  let view = QuotaOverviewView(
    model: configuration.makeModel(),
    enabledProviders: ProviderDisplayOrder.enabledProviders(),
    now: referenceDate,
    onOpenSettings: {}
  )
  .frame(width: 320, height: 420, alignment: .top)
  .background(QuotaPalette.panelWash)
  .environment(\.colorScheme, colorScheme)
  .environment(\.locale, Locale(identifier: "en_US_POSIX"))
  .environment(\.calendar, Calendar(identifier: .gregorian))
  .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)

  let host = NSHostingView(rootView: view)
  host.frame = NSRect(x: 0, y: 0, width: 320, height: 420)
  assertSnapshot(
    of: host,
    as: .image(precision: 0.99, perceptualPrecision: 0.98, size: host.frame.size),
    named: name
  )
}
