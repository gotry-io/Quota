import SwiftUI

/// The one place Quota sells paid sync.
///
/// Drawn by the app rather than by a remote template so the copy is reviewed with the rest of
/// `DESIGN.md`, the offline visual fixtures can render it, and the accessibility audit covers it.
struct PaywallView: View {
  @Bindable var model: AppModel
  @Environment(\.dismiss) private var dismiss

  private var subscription: SubscriptionModel { model.subscription }

  var body: some View {
    List {
      Section {
        VStack(alignment: .leading, spacing: 8) {
          Text(SyncCopy.paywallTitle)
            .font(.title2.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
          Text(SyncCopy.paywallSubtitle)
            .font(.subheadline)
            // Full label contrast, not `.secondary`: at subheadline size the secondary label
            // only nearly passes the audit's 4.5:1, and this sentence is what is being sold.
            .foregroundStyle(Color(uiColor: .label))
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("paywall.headline")
      }

      Section {
        ForEach(Array(SyncCopy.benefits.enumerated()), id: \.offset) { _, benefit in
          Label {
            Text(benefit)
              .fixedSize(horizontal: false, vertical: true)
          } icon: {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(QuotaTheme.emerald)
          }
        }
      }
      .accessibilityIdentifier("paywall.benefits")

      plansSection

      Section {
        Button(SyncCopy.restore) {
          Task { await subscription.restore() }
        }
        .accessibilityIdentifier("paywall.restore")
        Link(SyncCopy.terms, destination: QuotaWebLinks.terms)
        Link(SyncCopy.privacy, destination: QuotaWebLinks.privacy)
      } footer: {
        Text(SyncCopy.sectionFooter)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("paywall.footer")
      }
    }
    .listStyle(.insetGrouped)
    .environment(\.defaultMinListRowHeight, QuotaTheme.minimumTouchTarget)
    .accessibilityIdentifier("paywall.root")
    .navigationTitle(SyncCopy.paywallTitle)
    .navigationBarTitleDisplayMode(.inline)
    .task { await subscription.loadOffers() }
    .onChange(of: model.isSyncOn) { _, isOn in
      if isOn {
        subscription.entitlementConfirmed()
        dismiss()
      }
    }
  }

  @ViewBuilder
  private var plansSection: some View {
    Section {
      if !subscription.isAvailable {
        StatusMessage(symbolName: "exclamationmark.triangle", text: SyncCopy.unavailable)
          .accessibilityIdentifier("paywall.unavailable")
      } else {
        switch subscription.offers {
        case .idle, .loading:
          HStack(spacing: 12) {
            ProgressView()
            Text("Loading plans…")
          }
          .accessibilityElement(children: .combine)
          .accessibilityValue("Loading plans")
          .accessibilityIdentifier("paywall.loading")
        case .failed:
          StatusMessage(symbolName: "exclamationmark.triangle", text: SyncCopy.offersFailed)
            .accessibilityIdentifier("paywall.offers-failed")
          Button(SyncCopy.retry) {
            Task { await subscription.loadOffers(force: true) }
          }
          .accessibilityIdentifier("paywall.offers-retry")
        case .loaded(let offers):
          if offers.isEmpty {
            StatusMessage(symbolName: "exclamationmark.triangle", text: SyncCopy.offersFailed)
              .accessibilityIdentifier("paywall.offers-failed")
          } else {
            ForEach(offers) { offer in
              planRow(offer)
            }
          }
        }
        purchaseStatus
      }
    }
  }

  private func planRow(_ offer: SubscriptionOffer) -> some View {
    Button {
      Task { await subscription.buy(offer) }
    } label: {
      LabeledContent {
        Text(SyncCopy.offerDetail(offer))
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.trailing)
      } label: {
        Text(offer.term.title)
          .foregroundStyle(Color.primary)
      }
    }
    .disabled(subscription.purchase == .purchasing)
    .accessibilityLabel("\(offer.term.title), \(SyncCopy.offerDetail(offer))")
    .accessibilityIdentifier("paywall.plan.\(offer.term.rawValue)")
  }

  @ViewBuilder
  private var purchaseStatus: some View {
    switch subscription.purchase {
    case .idle:
      if let message = subscription.restoreMessage {
        StatusMessage(symbolName: "exclamationmark.triangle", text: message)
          .accessibilityIdentifier("paywall.status")
      }
    case .purchasing:
      HStack(spacing: 12) {
        ProgressView()
        Text("Working…")
      }
      .accessibilityElement(children: .combine)
      .accessibilityValue("Working")
      .accessibilityIdentifier("paywall.working")
    case .confirming:
      StatusMessage(symbolName: "checkmark.circle", text: SyncCopy.confirming)
        .accessibilityIdentifier("paywall.status")
    case .pending:
      StatusMessage(symbolName: "clock", text: SyncCopy.pending)
        .accessibilityIdentifier("paywall.status")
    case .failed(let message):
      StatusMessage(symbolName: "exclamationmark.triangle", text: message)
        .accessibilityIdentifier("paywall.status")
    }
  }
}
