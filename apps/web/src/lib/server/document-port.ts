import type { AccountSummaryV3DeviceHealth } from "@gotry-io/quota-protocol";

export interface WebDocumentViewer {
  displayLabel: string;
}

export type AccountSummaryDocumentResult =
  | { status: "ok"; summary: AccountSummaryV3DeviceHealth }
  | { status: "unauthorized" }
  | { status: "error" };

export type PublicProfileDocumentResult =
  | { status: "exists" }
  | { status: "missing" }
  | { status: "rate_limited"; retryAfterSeconds: number };

export interface WebDocumentPort {
  getViewer(headers: Headers): Promise<WebDocumentViewer | null>;
  getAccountSummary?(headers: Headers): Promise<AccountSummaryDocumentResult>;
  lookupPublicProfile(username: string): Promise<PublicProfileDocumentResult>;
}
