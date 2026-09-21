import type { PublicUsageResponse } from "@gotry-io/quota-protocol";

export interface WebDocumentViewer {
  displayLabel: string;
}

export interface WebDocumentPort {
  getViewer(headers: Headers): Promise<WebDocumentViewer | null>;
  /**
   * The public page published under this handle, or null when there is none.
   *
   * A document load may reach account data only through this port, and this is the second
   * thing it may ask for: a page whose whole address is the handle in the URL, with no session
   * anywhere in the answer
   * ([ADR 0037](../../../../../docs/decisions/0037-a-public-profile-shows-usage-not-quota.md)).
   */
  readPublicProfile(handle: string): Promise<PublicUsageResponse | null>;
}
