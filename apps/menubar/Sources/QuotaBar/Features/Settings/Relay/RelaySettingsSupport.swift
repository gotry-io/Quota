import SwiftUI

enum RelayFormValidationError: LocalizedError, Equatable {
  case invalidOrigin(String)
  case missingPairingCode

  var errorDescription: String? {
    switch self {
    case .invalidOrigin(let message):
      message
    case .missingPairingCode:
      "Enter the pairing code shown by QuotaCLI."
    }
  }
}

enum RelayPairingCodeValidation {
  /// Relay user codes are 8 chars from a confusable-safe alphabet, displayed as ABCD-EFGH.
  static let codeLength = 8
  static let alphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

  /// Returns canonical `ABCD-EFGH` or throws.
  static func validate(_ userCode: String) throws -> String {
    let normalized = normalize(userCode)
    guard normalized.count == codeLength else {
      throw RelayFormValidationError.missingPairingCode
    }
    guard normalized.allSatisfy({ alphabet.contains($0) }) else {
      throw RelayFormValidationError.missingPairingCode
    }
    let chars = Array(normalized)
    return "\(String(chars[0..<4]))-\(String(chars[4..<8]))"
  }

  /// Uppercases and strips separators/spaces; keeps only alphabet characters (max 8).
  static func normalize(_ raw: String) -> String {
    var scalars: [Character] = []
    for character in raw.uppercased() {
      guard alphabet.contains(character) else { continue }
      scalars.append(character)
      if scalars.count == codeLength { break }
    }
    return String(scalars)
  }

  static func isComplete(_ raw: String) -> Bool {
    let normalized = normalize(raw)
    return normalized.count == codeLength && normalized.allSatisfy({ alphabet.contains($0) })
  }
}

enum RelaySettingsErrorPresentation {
  static func message(for error: Error, fallback: String) -> String? {
    if error is CancellationError {
      return nil
    }
    if let modelError = error as? RelayStateModelError {
      return modelError.issue.message
    }
    if let formError = error as? RelayFormValidationError {
      return formError.errorDescription
    }
    return fallback
  }
}

struct RelayPairCommandPresentation: Equatable {
  let command: String
  let canCopy: Bool

  static func make(
    selectedURL: URL?,
    officialURL: URL,
    isOtherChoice: Bool
  ) -> RelayPairCommandPresentation {
    guard let selectedURL else {
      return RelayPairCommandPresentation(
        command: isOtherChoice
          ? "quotacli relay pair --relay <relay-url>"
          : "quotacli relay pair",
        canCopy: false
      )
    }

    return RelayPairCommandPresentation(
      command: selectedURL == officialURL
        ? "quotacli relay pair"
        : "quotacli relay pair --relay \(selectedURL.absoluteString)",
      canCopy: true
    )
  }
}

struct RelayCard<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(QuotaDesign.Layout.cardPadding)
      .clipShape(RoundedRectangle(cornerRadius: QuotaDesign.Layout.cardCornerRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: QuotaDesign.Layout.cardCornerRadius, style: .continuous)
          .stroke(QuotaPalette.hairlineBorder, lineWidth: 1)
      }
  }
}

struct RelaySecondaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .quotaFont(.rowTitle)
      .foregroundStyle(isEnabled ? QuotaPalette.ink : QuotaPalette.body)
      .padding(.horizontal, QuotaDesign.Layout.panelHorizontalPadding)
      .frame(minHeight: 34)
      .background(
        QuotaPalette.soft.opacity(configuration.isPressed && isEnabled ? 1.2 : 0.85)
      )
      .clipShape(Capsule())
      .overlay {
        Capsule()
          .stroke(QuotaPalette.hairlineBorder, lineWidth: 1)
      }
  }
}

/// Compact single-line field with a small corner radius.
struct RelayRoundedTextFieldStyle: TextFieldStyle {
  private let cornerRadius: CGFloat = 6

  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration
      .textFieldStyle(.plain)
      .padding(.horizontal, 10)
      .frame(minHeight: 30)
      .background(QuotaPalette.soft)
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(QuotaPalette.hairlineBorder, lineWidth: 1)
      }
  }
}

/// Eight fixed cells for Relay user codes (`ABCD-EFGH`).
struct PairingCodeEntryView: View {
  @Binding var code: String
  var isDisabled = false
  var showsError = false
  /// Bump after a failed attempt so the same complete code can auto-submit again.
  var retryToken: Int = 0
  var onComplete: ((String) -> Void)?

  @FocusState private var focusedIndex: Int?
  @State private var cells: [String] = Array(repeating: "", count: RelayPairingCodeValidation.codeLength)
  @State private var lastSubmitted: String?

  // Fit eight boxes inside panelContentWidth (320 - 16*2 = 288):
  // 8*box + 6*boxGap + 2*groupGap + dash ≈ content width.
  private let boxSize = QuotaDesign.Layout.minimumInteractiveDimension
  private let boxGap: CGFloat = 5
  private let groupGap: CGFloat = 8

  var body: some View {
    HStack(spacing: groupGap) {
      HStack(spacing: boxGap) {
        ForEach(0..<4, id: \.self) { index in
          codeBox(index)
        }
      }
      Text("—")
        .font(QuotaDesign.Typography.pairingSeparator)
        .foregroundStyle(QuotaPalette.mute)
      HStack(spacing: boxGap) {
        ForEach(4..<8, id: \.self) { index in
          codeBox(index)
        }
      }
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Pairing code")
    .onAppear {
      applyNormalized(RelayPairingCodeValidation.normalize(code), emitComplete: false)
      focusedIndex = isDisabled ? nil : firstEmptyIndex
    }
    .onChange(of: code) { _, newValue in
      let normalized = RelayPairingCodeValidation.normalize(newValue)
      if normalized != cells.joined() {
        applyNormalized(normalized, emitComplete: false)
      }
    }
    .onChange(of: isDisabled) { _, disabled in
      if disabled {
        focusedIndex = nil
      } else if focusedIndex == nil {
        focusedIndex = firstEmptyIndex
      }
    }
    .onChange(of: retryToken) { _, _ in
      lastSubmitted = nil
    }
  }

  private var firstEmptyIndex: Int {
    cells.firstIndex(where: \.isEmpty) ?? (RelayPairingCodeValidation.codeLength - 1)
  }

  private func codeBox(_ index: Int) -> some View {
    TextField("", text: binding(for: index))
      .textFieldStyle(.plain)
      .multilineTextAlignment(.center)
      .font(QuotaDesign.Typography.pairingCode)
      .frame(width: boxSize, height: boxSize)
      .background(QuotaPalette.soft)
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(
            showsError
              ? QuotaPalette.critical.opacity(0.85)
              : (focusedIndex == index
                ? QuotaPalette.accent.opacity(0.75)
                : QuotaPalette.hairlineBorder),
            lineWidth: focusedIndex == index || showsError ? 1.5 : 1
          )
      }
      .focused($focusedIndex, equals: index)
      .disabled(isDisabled)
      .accessibilityLabel("Pairing code character \(index + 1) of 8")
      .accessibilityValue(cells[index].isEmpty ? "Empty" : cells[index])
      .accessibilityHint(
        index == 0 ? "You can paste the complete pairing code into this field." : "Enter one character."
      )
      .onChange(of: cells[index]) { _, newValue in
        handleEdit(at: index, raw: newValue)
      }
  }

  private func binding(for index: Int) -> Binding<String> {
    Binding(
      get: { cells[index] },
      set: { cells[index] = $0 }
    )
  }

  private func handleEdit(at index: Int, raw: String) {
    // Paste or multi-character entry into one box: redistribute from this index.
    let incoming = RelayPairingCodeValidation.normalize(raw)
    if raw.count > 1 || incoming.count > 1 {
      let prefix = cells.prefix(index).joined()
      let normalized = RelayPairingCodeValidation.normalize(prefix + raw)
      applyNormalized(normalized, emitComplete: true)
      focusedIndex = min(
        RelayPairingCodeValidation.normalize(normalized).count,
        RelayPairingCodeValidation.codeLength - 1
      )
      if RelayPairingCodeValidation.isComplete(normalized) {
        focusedIndex = nil
      }
      return
    }

    if incoming.isEmpty {
      cells[index] = ""
      syncCodeBinding()
      if index > 0 {
        focusedIndex = index - 1
      }
      lastSubmitted = nil
      return
    }

    let character = String(incoming.prefix(1))
    cells[index] = character
    syncCodeBinding()
    if index < RelayPairingCodeValidation.codeLength - 1 {
      focusedIndex = index + 1
    } else {
      focusedIndex = nil
    }
    emitCompletionIfNeeded()
  }

  private func applyNormalized(_ normalized: String, emitComplete: Bool) {
    var next = Array(repeating: "", count: RelayPairingCodeValidation.codeLength)
    for (offset, character) in normalized.prefix(RelayPairingCodeValidation.codeLength).enumerated() {
      next[offset] = String(character)
    }
    cells = next
    syncCodeBinding()
    if emitComplete {
      emitCompletionIfNeeded()
    }
  }

  private func syncCodeBinding() {
    let normalized = cells.joined()
    if code != normalized {
      code = normalized
    }
  }

  private func emitCompletionIfNeeded() {
    let normalized = cells.joined()
    guard RelayPairingCodeValidation.isComplete(normalized) else { return }
    guard lastSubmitted != normalized else { return }
    lastSubmitted = normalized
    if let canonical = try? RelayPairingCodeValidation.validate(normalized) {
      onComplete?(canonical)
    }
  }
}
