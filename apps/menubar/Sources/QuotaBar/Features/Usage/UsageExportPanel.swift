import AppKit
import UniformTypeIdentifiers

/// NSSavePanel for File › Export Usage… and the Usage toolbar Export button.
enum UsageExportPanel {
  @MainActor
  static func present(input: UsageExport.Input, on window: NSWindow?) {
    let panel = NSSavePanel()
    panel.canCreateDirectories = true
    panel.allowedContentTypes = [.commaSeparatedText, .json]
    panel.allowsOtherFileTypes = false
    panel.isExtensionHidden = false
    panel.title = "Export Usage"
    panel.nameFieldStringValue = UsageExport.filename(
      from: input.from, to: input.to, format: .csv
    ).replacingOccurrences(of: ".csv", with: "")
    let handler: (NSApplication.ModalResponse) -> Void = { response in
      guard response == .OK, let url = panel.url else { return }
      write(input: input, to: url)
    }
    if let window {
      panel.beginSheetModal(for: window, completionHandler: handler)
    } else {
      handler(panel.runModal())
    }
  }

  @MainActor
  static func write(input: UsageExport.Input, to url: URL) {
    let format: UsageExport.Format = url.pathExtension.lowercased() == "json" ? .json : .csv
    let body: String
    if format == .json {
      body = (try? UsageExport.jsonText(from: input)) ?? "{}\n"
    } else {
      body = UsageExport.csv(from: input)
    }
    try? body.write(to: url, atomically: true, encoding: .utf8)
  }
}
