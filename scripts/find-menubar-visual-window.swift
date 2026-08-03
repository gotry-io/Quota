import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 3,
      let requestedPID = Int32(CommandLine.arguments[1])
else {
  FileHandle.standardError.write(Data("usage: find-menubar-visual-window <pid> <title>\n".utf8))
  exit(2)
}

let requestedTitle = CommandLine.arguments[2]
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
  as? [[String: Any]]
else {
  exit(1)
}

for window in windows {
  let reportedTitle = window[kCGWindowName as String] as? String
  // macOS may redact window names before Screen Recording is granted. The caller supplies the
  // exact child PID, so an unnamed, visible layer-zero window remains safely process-scoped.
  guard
    (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == requestedPID,
    (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
    reportedTitle == requestedTitle || reportedTitle?.isEmpty != false,
    let windowID = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
    let bounds = window[kCGWindowBounds as String] as? [String: Any],
    let width = (bounds["Width"] as? NSNumber)?.doubleValue,
    let height = (bounds["Height"] as? NSNumber)?.doubleValue,
    width > 0,
    height > 0
  else {
    continue
  }

  print("\(windowID)\t\(Int(width))\t\(Int(height))")
  exit(0)
}

exit(1)
