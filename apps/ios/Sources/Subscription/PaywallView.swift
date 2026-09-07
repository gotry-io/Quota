import SwiftUI

/// The one place Quota sells Quota Pro.
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
          Text(ProCopy.paywallTitle)
            .font(.title2.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
          Text(ProCopy.paywallSubtitle)
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
        ForEach(Array(ProCopy.benefits.enumerated()), id: \.offset) { _, benefit in
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
        Button(ProCopy.restore) {
          Task { await subscription.restore() }
        }
        .accessibilityIdentifier("paywall.restore")
        if subscription.isAvailable {
          Button(ProCopy.redeemOfferCode) {
            Task { await subscription.redeemOfferCode() }
          }
          .accessibilityIdentifier("paywall.redeem-offer-code")
        }
        Link(ProCopy.terms, destination: QuotaWebLinks.terms)
        Link(ProCopy.privacy, destination: QuotaWebLinks.privacy)
      } footer: {
        Text(ProCopy.sectionFooter)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("paywall.footer")
      }
    }
    .listStyle(.insetGrouped)
    .environment(\.defaultMinListRowHeight, QuotaTheme.minimumTouchTarget)
    .accessibilityIdentifier("paywall.root")
    .navigationTitle(ProCopy.paywallTitle)
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
        StatusMessage(symbolName: "exclamationmark.triangle", text: ProCopy.unavailable)
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
          StatusMessage(symbolName: "exclamationmark.triangle", text: ProCopy.offersFailed)
            .accessibilityIdentifier("paywall.offers-failed")
          Button(ProCopy.retry) {
            Task { await subscription.loadOffers(force: true) }
          }
          .accessibilityIdentifier("paywall.offers-retry")
        case .loaded(let offers):
          if offers.isEmpty {
            StatusMessage(symbolName: "exclamationmark.triangle", text: ProCopy.offersFailed)
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
        Text(ProCopy.offerDetail(offer))
          .font(.subheadline.monospacedDigit())
          // The same rule as the headline: the secondary label only nearly passes at this size.
          .foregroundStyle(Color(uiColor: .label))
          .multilineTextAlignment(.trailing)
      } label: {
        Text(offer.term.title)
          .foregroundStyle(Color.primary)
      }
    }
    .disabled(subscription.purchase == .purchasing)
    .accessibilityLabel("\(offer.term.title), \(ProCopy.offerDetail(offer))")
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
      StatusMessage(symbolName: "checkmark.circle", text: ProCopy.confirming)
        .accessibilityIdentifier("paywall.status")
    case .pending:
      StatusMessage(symbolName: "clock", text: ProCopy.pending)
        .accessibilityIdentifier("paywall.status")
    case .failed(let message):
      StatusMessage(symbolName: "exclamationmark.triangle", text: message)
        .accessibilityIdentifier("paywall.status")
    }
  }
}
