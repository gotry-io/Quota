import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

struct MacSetupGuideCard: View {
  static let downloadURL = URL(string: "https://quota.gotry.io/download")!

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Set up a Mac")
        .font(.headline)
        .accessibilityAddTraits(.isHeader)

      Text(
        "Quota shows what QuotaBar on your Mac reports. Install it on a Mac signed in with the same GitHub account."
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      Link(destination: Self.downloadURL) {
        Text("https://quota.gotry.io/download")
          .font(.subheadline)
          .frame(
            maxWidth: .infinity,
            minHeight: QuotaTheme.minimumTouchTarget,
            alignment: .leading
          )
      }
      .contentShape(Rectangle())
      .frame(minHeight: QuotaTheme.minimumTouchTarget, alignment: .leading)
      .accessibilityLabel("Download QuotaBar")
      .accessibilityHint("Opens quota.gotry.io/download")

      DownloadQRCode(url: Self.downloadURL)
        .frame(width: 160, height: 160)
        .padding(8)
        .background(Color.white, in: QuotaTheme.cardShape)
        .accessibilityHidden(true)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .quotaSurface()
    .accessibilityElement(children: .contain)
  }
}

struct DownloadQRCode: View {
  let image: UIImage?

  init(url: URL) {
    image = QRCodeImage.make(url.absoluteString)
  }

  var body: some View {
    if let image {
      Image(uiImage: image)
        .interpolation(.none)
        .resizable()
        .scaledToFit()
    }
  }
}

enum QRCodeImage {
  static func make(_ string: String) -> UIImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
    return UIImage(cgImage: cgImage)
  }
}
