import SwiftUI

/// Inserts a Tahoe `ToolbarSpacer` on macOS 26 and nothing on 14/15, so toolbar items can
/// group into glass capsules without the rest of the app branching on availability.
enum QuotaToolbarSpacer {
  struct Flexible: ToolbarContent {
    var body: some ToolbarContent {
      if #available(macOS 26.0, *) {
        ToolbarSpacer(.flexible)
      }
    }
  }

  struct Fixed: ToolbarContent {
    var body: some ToolbarContent {
      if #available(macOS 26.0, *) {
        ToolbarSpacer(.fixed)
      }
    }
  }
}
