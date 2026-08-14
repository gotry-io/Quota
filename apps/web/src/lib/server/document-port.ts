export interface WebDocumentViewer {
  displayLabel: string;
}

export type PublicProfileDocumentResult =
  | { status: "exists" }
  | { status: "missing" }
  | { status: "rate_limited"; retryAfterSeconds: number };

export interface WebDocumentPort {
  getViewer(headers: Headers): Promise<WebDocumentViewer | null>;
  lookupPublicProfile(username: string): Promise<PublicProfileDocumentResult>;
}
