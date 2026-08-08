import type { CollectionOutcome, ProviderId, QuotaSnapshot } from "@gotry-io/quota-protocol";

export interface ProviderSession {
  provider: ProviderId;
  session_id: string;
  display_label: string;
  credential_source: string;
}

export interface ProviderDiagnostic {
  provider: ProviderId;
  available: boolean;
  credential_source: string;
}

export interface CollectionContext {
  signal?: AbortSignal;
  now?: Date;
}

export type ProviderErrorCategory = Exclude<CollectionOutcome, "success">;

export class ProviderCollectionError extends Error {
  readonly category: ProviderErrorCategory;
  readonly source?: string;

  constructor(category: ProviderErrorCategory, message: string, source?: string) {
    super(message);
    this.name = "ProviderCollectionError";
    this.category = category;
    if (source !== undefined) {
      this.source = source;
    }
  }
}

export interface ProviderCollector {
  readonly provider: ProviderId;
  discover(): Promise<ProviderSession[]>;
  collect(session: ProviderSession, context?: CollectionContext): Promise<QuotaSnapshot>;
}
