<!-- Draft — pending owner review -->

# Export compliance (Quota iOS)

App Store Connect › Export Compliance, and the Info.plist key
`ITSAppUsesNonExemptEncryption`.

**Answer: this app uses only exempt encryption. Set `ITSAppUsesNonExemptEncryption` to
`false`.**

## What the app uses

- **System TLS.** Account traffic is `URLSession` HTTPS to the fixed origin
  `https://quota.gotry.io`. Certificate validation is the platform’s. There is no bundled
  TLS stack, no custom cipher, and no certificate pinning beyond the system.
- **Keychain.** The `quota-ios` session is one generic-password item with
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Keychain is the system credential store,
  not an encryption product the app ships.
- **App Group file protection.** The widget snapshot uses
  `completeFileProtectionUntilFirstUserAuthentication` (complete protection until first
  unlock). That is iOS Data Protection, not a non-exempt algorithm.

## What the app does not use

- No proprietary or non-Apple cryptographic library.
- No in-app implementation of AES, RSA, ECC, or similar beyond calling the system.
- No encrypted calling, encrypted messaging, or user-controlled end-to-end encryption.
- No encryption of content the user then exports.

## Basis

Apple’s export-compliance guidance treats HTTPS/TLS as implemented in the operating system,
and encryption incidental to authentication and data protection (Keychain, Data Protection),
as exempt. Quota iOS does not add a non-exempt encryption product on top of that.

The same key belongs on the app target and the widget-extension target. WP-3.10a sets it in
`apps/ios/Sources/Info.plist` and `apps/ios/Widgets/Info.plist`.
