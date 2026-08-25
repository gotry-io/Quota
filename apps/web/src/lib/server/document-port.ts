import type { AccountSummary } from "@gotry-io/quota-protocol";

export interface WebDocumentViewer {
  displayLabel: string;
}

export type AccountSummaryDocumentResult =
  | { status: "ok"; summary: AccountSummary }
  | { status: "unauthorized" }
  | { status: "error" };

export interface WebDocumentPort {
  getViewer(headers: Headers): Promise<WebDocumentViewer | null>;
  getAccountSummary?(headers: Headers): Promise<AccountSummaryDocumentResult>;
}
