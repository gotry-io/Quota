import AppKit
import Foundation

private func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("\(message)\n".utf8))
  exit(1)
}

guard CommandLine.arguments.count == 2 else {
  fail("usage: validate-menubar-screenshot <png>")
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let data = try? Data(contentsOf: url),
  let image = NSBitmapImageRep(data: data),
  image.pixelsWide > 0,
  image.pixelsHigh > 0
else {
  fail("could not decode PNG pixels")
}

var transparentPixels = 0
var darkPixels = 0
var lightPixels = 0
var minimumLuminance = 1.0
var maximumLuminance = 0.0

for y in 0..<image.pixelsHigh {
  for x in 0..<image.pixelsWide {
    guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(NSColorSpace.sRGB) else {
      fail("could not decode an sRGB pixel")
    }
    if color.alphaComponent < 0.999 {
      transparentPixels += 1
    }

    let luminance =
      (0.2126 * Double(color.redComponent))
      + (0.7152 * Double(color.greenComponent))
      + (0.0722 * Double(color.blueComponent))
    minimumLuminance = min(minimumLuminance, luminance)
    maximumLuminance = max(maximumLuminance, luminance)
    if luminance < 0.4 { darkPixels += 1 }
    if luminance > 0.6 { lightPixels += 1 }
  }
}

guard transparentPixels == 0 else {
  fail("screenshot contains \(transparentPixels) transparent pixels")
}
guard maximumLuminance - minimumLuminance >= 0.5 else {
  fail("screenshot luminance range is too small to contain readable hierarchy")
}
guard darkPixels >= 100, lightPixels >= 100 else {
  fail("screenshot does not contain both foreground and background contrast")
}

print(
  "pixels=\(image.pixelsWide)x\(image.pixelsHigh) "
    + "luminance=\(String(format: "%.3f", minimumLuminance))..."
    + String(format: "%.3f", maximumLuminance)
)
