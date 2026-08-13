import Foundation
import Testing

@testable import QuotaBar

struct AppUpdateApplyTests {
  @Test
  func stagesQuotaBarAppSoALaterUnmountDoesNotRemoveTheReplacement() throws {
    let mount = FileManager.default.temporaryDirectory
      .appending(path: "QuotaBarMount-\(UUID().uuidString)", directoryHint: .isDirectory)
    let mountedApp = mount.appending(path: "QuotaBar.app")
    try FileManager.default.createDirectory(
      at: mountedApp.appending(path: "Contents"), withIntermediateDirectories: true)
    let marker = mountedApp.appending(path: "Contents/PkgInfo")
    try "APPL????".write(to: marker, atomically: true, encoding: .utf8)

    let staged = try AppUpdateService().stageAppForReplace(mountedApp)
    try FileManager.default.removeItem(at: mount)

    #expect(!FileManager.default.fileExists(atPath: mountedApp.path))
    #expect(
      FileManager.default.fileExists(atPath: staged.appending(path: "Contents/PkgInfo").path)
    )
    #expect(try String(contentsOf: staged.appending(path: "Contents/PkgInfo"), encoding: .utf8) == "APPL????")
  }
}
