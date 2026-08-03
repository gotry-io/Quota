import SwiftUI

struct ValidatedRelayAddForm: Equatable {
  let name: String
  let origin: String
  let ownerBearer: String
}

enum RelayAddFormValidation {
  static func validate(
    name: String,
    origin: String,
    ownerBearer: String
  ) throws -> ValidatedRelayAddForm {
    let canonicalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !canonicalName.isEmpty else {
      throw RelayFormValidationError.missingName
    }

    let canonicalOrigin: URL
    do {
      canonicalOrigin = try RelayOrigin.canonicalURL(from: origin)
    } catch let error as RelayOriginError {
      throw RelayFormValidationError.invalidOrigin(
        error.errorDescription ?? "The Relay address is invalid."
      )
    }

    guard !ownerBearer.isEmpty,
      ownerBearer == ownerBearer.trimmingCharacters(in: .whitespacesAndNewlines),
      ownerBearer.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7f })
    else {
      throw RelayFormValidationError.invalidOwnerCredential
    }

    return ValidatedRelayAddForm(
      name: canonicalName,
      origin: canonicalOrigin.absoluteString,
      ownerBearer: ownerBearer
    )
  }
}

enum RelayFormValidationError: LocalizedError, Equatable {
  case missingName
  case invalidOrigin(String)
  case invalidOwnerCredential
  case missingPairingCode

  var errorDescription: String? {
    switch self {
    case .missingName:
      "Enter a Relay profile name."
    case .invalidOrigin(let message):
      message
    case .invalidOwnerCredential:
      "Enter a valid Relay owner credential."
    case .missingPairingCode:
      "Enter the pairing code shown by QuotaCLI."
    }
  }
}

enum RelayPairingCodeValidation {
  static func validate(_ userCode: String) throws -> String {
    let canonicalCode = userCode.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !canonicalCode.isEmpty else {
      throw RelayFormValidationError.missingPairingCode
    }
    return canonicalCode
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

struct RelayCard<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
      .background(QuotaPalette.soft.opacity(0.18))
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(QuotaPalette.hairline, lineWidth: 1)
      }
  }
}

struct RelayStatusTag: View {
  let text: String
  var systemImage: String?

  var body: some View {
    HStack(spacing: 3) {
      if let systemImage {
        Image(systemName: systemImage)
      }
      Text(text)
    }
    .font(QuotaDesign.Typography.statusTag)
    .foregroundStyle(QuotaPalette.charcoal)
    .padding(.horizontal, 5)
    .padding(.vertical, 2)
    .overlay {
      RoundedRectangle(cornerRadius: QuotaDesign.Layout.tagCornerRadius)
        .stroke(QuotaPalette.hairline, lineWidth: 1)
    }
  }
}

struct RelaySecondaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(.subheadline, weight: .medium))
      .foregroundStyle(isEnabled ? QuotaPalette.ink : QuotaPalette.body)
      .padding(.horizontal, 16)
      .frame(minHeight: 34)
      .background(QuotaPalette.soft.opacity(configuration.isPressed && isEnabled ? 0.7 : 0.25))
      .clipShape(Capsule())
      .overlay {
        Capsule()
          .stroke(QuotaPalette.hairline, lineWidth: 1)
      }
  }
}

struct RelayPillTextFieldStyle: TextFieldStyle {
  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration
      .textFieldStyle(.plain)
      .padding(.horizontal, 14)
      .frame(minHeight: 40)
      .background(QuotaPalette.soft.opacity(0.18))
      .clipShape(Capsule())
      .overlay {
        Capsule()
          .stroke(QuotaPalette.hairline, lineWidth: 1)
      }
  }
}

extension RelayMode {
  var displayName: String {
    switch self {
    case .managed: "Managed"
    case .selfHosted: "Self-hosted"
    }
  }
}

extension RelayDevice {
  var shortID: String {
    guard deviceID.count > 12 else { return deviceID }
    return "\(deviceID.prefix(8))…\(deviceID.suffix(4))"
  }

  var sequenceLabel: String {
    lastSequence < 0 ? "No reports yet" : "Sequence \(lastSequence)"
  }
}
