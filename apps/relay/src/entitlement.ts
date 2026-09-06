import type { Entitlement } from "@gotry-io/quota-protocol";
import type { AccountState, EntitlementStatus, StoredEntitlement } from "@gotry-io/relay-core";

export const SYNC_ENTITLEMENT_ID = "sync";
export const ENTITLEMENT_CACHE_MILLISECONDS = 24 * 60 * 60 * 1000;
export const REVENUECAT_REST_TIMEOUT_MILLISECONDS = 20_000;
export const REVENUECAT_SUBSCRIBER_URL = "https://api.revenuecat.com/v1/subscribers";

const WEBHOOK_EVENT_TYPES = new Set([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "CANCELLATION",
  "EXPIRATION",
  "BILLING_ISSUE",
  "PRODUCT_CHANGE",
  "UNCANCELLATION",
  "TRANSFER",
  "TEST",
]);

const PII_EVENT_KEYS = new Set(["email", "attributes", "subscriber_attributes"]);

export interface BillingBindings {
  webhookSecret: string;
  restSecret: string;
  webPurchaseUrl: string;
  fetch?: typeof fetch;
}

export interface RevenueCatEvent {
  id?: unknown;
  type?: unknown;
  app_user_id?: unknown;
  entitlement_id?: unknown;
  entitlement_ids?: unknown;
  product_id?: unknown;
  new_product_id?: unknown;
  store?: unknown;
  expiration_at_ms?: unknown;
  transferred_from?: unknown;
  transferred_to?: unknown;
  [key: string]: unknown;
}

const noneEntitlement = {
  status: "none" as const,
  product_id: null,
  store: null,
  expires_at: null,
  will_renew: false,
};

export function isPaidSyncStatus(status: EntitlementStatus): boolean {
  return status === "active" || status === "grace";
}

export function purchaseWebUrl(base: string, accountId: string): string {
  return `${base.replace(/\/+$/, "")}/${encodeURIComponent(accountId)}`;
}

export function publicEntitlement(row: StoredEntitlement | null, stale: boolean): Entitlement {
  if (!row) {
    return { ...noneEntitlement, stale };
  }
  return {
    status: row.status,
    expires_at: row.expires_at,
    will_renew: row.will_renew,
    product_id: row.product_id,
    store: row.store,
    stale,
  };
}

export function entitlementCacheIsFresh(row: StoredEntitlement | null, now: Date): boolean {
  if (!row) return false;
  const updated = Date.parse(row.updated_at);
  if (!Number.isFinite(updated) || now.getTime() - updated > ENTITLEMENT_CACHE_MILLISECONDS) {
    return false;
  }
  if (!isPaidSyncStatus(row.status) || row.expires_at === null) return true;
  const expires = Date.parse(row.expires_at);
  return !Number.isFinite(expires) || expires > now.getTime();
}

export function sanitizeRevenueCatEvent(event: Record<string, unknown>): Record<string, unknown> {
  const sanitized: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(event)) {
    if (PII_EVENT_KEYS.has(key) || key.toLowerCase().includes("email")) continue;
    sanitized[key] = value;
  }
  return sanitized;
}

export function parseRevenueCatWebhookBody(raw: unknown): RevenueCatEvent | null {
  if (raw === null || typeof raw !== "object" || Array.isArray(raw)) return null;
  const event = (raw as { event?: unknown }).event;
  if (event === null || typeof event !== "object" || Array.isArray(event)) return null;
  return event as RevenueCatEvent;
}

export function webhookEventId(event: RevenueCatEvent): string | null {
  return typeof event.id === "string" && event.id.length > 0 ? event.id : null;
}

export function webhookAppUserId(event: RevenueCatEvent): string | null {
  return typeof event.app_user_id === "string" && event.app_user_id.length > 0
    ? event.app_user_id
    : null;
}

export function webhookEventType(event: RevenueCatEvent): string | null {
  return typeof event.type === "string" && event.type.length > 0 ? event.type : null;
}

export function eventAffectsSync(event: RevenueCatEvent): boolean {
  const ids = event.entitlement_ids;
  if (Array.isArray(ids)) {
    return ids.some((id) => id === SYNC_ENTITLEMENT_ID);
  }
  if (typeof event.entitlement_id === "string") {
    return event.entitlement_id === SYNC_ENTITLEMENT_ID;
  }
  return event.type === "TRANSFER" || event.type === "TEST";
}

export function foldWebhookEvent(
  event: RevenueCatEvent,
  now: Date,
): Omit<StoredEntitlement, "account_id" | "source" | "last_event_id" | "updated_at"> | null {
  const type = webhookEventType(event);
  if (type === null || !WEBHOOK_EVENT_TYPES.has(type)) return null;
  if (!eventAffectsSync(event)) return null;

  const expiresAt = millisecondsToInstant(event.expiration_at_ms);
  const productId = optionalText(event.new_product_id) ?? optionalText(event.product_id);
  const store = optionalText(event.store);
  const expiresMs = expiresAt === null ? Number.NaN : Date.parse(expiresAt);

  if (type === "EXPIRATION") {
    return {
      status: "expired",
      product_id: productId,
      store,
      expires_at: expiresAt,
      will_renew: false,
    };
  }
  if (type === "BILLING_ISSUE") {
    return {
      status: "grace",
      product_id: productId,
      store,
      expires_at: expiresAt,
      will_renew: true,
    };
  }
  if (type === "CANCELLATION") {
    const stillActive = Number.isFinite(expiresMs) && expiresMs > now.getTime();
    return {
      status: stillActive ? "active" : "expired",
      product_id: productId,
      store,
      expires_at: expiresAt,
      will_renew: false,
    };
  }
  return {
    status: "active",
    product_id: productId,
    store,
    expires_at: expiresAt,
    will_renew: true,
  };
}

export function transferSourceIds(event: RevenueCatEvent): string[] {
  return stringArray(event.transferred_from);
}

export function foldSubscriber(
  subscriber: RevenueCatSubscriber,
  now: Date,
): Omit<StoredEntitlement, "account_id" | "source" | "last_event_id" | "updated_at"> {
  const entitlement = subscriber.entitlements?.[SYNC_ENTITLEMENT_ID];
  if (!entitlement) return noneEntitlement;

  const productId = optionalText(entitlement.product_identifier);
  const subscription = productId ? subscriber.subscriptions?.[productId] : undefined;
  const expiresAt =
    optionalText(entitlement.expires_date) ?? optionalText(subscription?.expires_date);
  const graceUntil =
    optionalText(entitlement.grace_period_expires_date) ??
    optionalText(subscription?.grace_period_expires_date);
  const store = optionalText(subscription?.store);
  const unsubscribed = optionalText(subscription?.unsubscribe_detected_at);
  const billingIssue = optionalText(subscription?.billing_issues_detected_at);
  const nowMs = now.getTime();
  const expiresMs = expiresAt === null ? Number.NaN : Date.parse(expiresAt);
  const graceMs = graceUntil === null ? Number.NaN : Date.parse(graceUntil);

  let status: EntitlementStatus;
  if (Number.isFinite(graceMs) && graceMs > nowMs) {
    status = "grace";
  } else if (billingIssue !== null && (!Number.isFinite(expiresMs) || expiresMs > nowMs)) {
    status = "grace";
  } else if (!Number.isFinite(expiresMs) || expiresMs > nowMs) {
    status = "active";
  } else {
    status = "expired";
  }

  return {
    status,
    product_id: productId,
    store,
    expires_at: expiresAt,
    will_renew: unsubscribed === null && status !== "expired",
  };
}

export async function readEntitlement(
  state: AccountState,
  billing: BillingBindings,
  accountId: string,
  now: Date,
): Promise<Entitlement> {
  const stored = await state.getEntitlement(accountId);
  if (entitlementCacheIsFresh(stored, now)) {
    return publicEntitlement(stored, false);
  }
  if (billing.restSecret.length === 0) {
    return publicEntitlement(stored, false);
  }
  try {
    const subscriber = await fetchSubscriber(billing, accountId);
    const folded = foldSubscriber(subscriber, now);
    const row: StoredEntitlement = {
      account_id: accountId,
      ...folded,
      source: "rest",
      last_event_id: stored?.last_event_id ?? null,
      updated_at: now.toISOString(),
    };
    await state.putEntitlement(row);
    return publicEntitlement(row, false);
  } catch {
    return publicEntitlement(stored, true);
  }
}

export interface RevenueCatSubscriber {
  entitlements?: Record<string, RevenueCatEntitlementInfo | undefined>;
  subscriptions?: Record<string, RevenueCatSubscriptionInfo | undefined>;
}

interface RevenueCatEntitlementInfo {
  expires_date?: unknown;
  grace_period_expires_date?: unknown;
  product_identifier?: unknown;
}

interface RevenueCatSubscriptionInfo {
  expires_date?: unknown;
  grace_period_expires_date?: unknown;
  store?: unknown;
  unsubscribe_detected_at?: unknown;
  billing_issues_detected_at?: unknown;
}

async function fetchSubscriber(
  billing: BillingBindings,
  accountId: string,
): Promise<RevenueCatSubscriber> {
  const fetchFn = billing.fetch ?? fetch;
  const response = await fetchFn(`${REVENUECAT_SUBSCRIBER_URL}/${encodeURIComponent(accountId)}`, {
    method: "GET",
    headers: {
      Authorization: `Bearer ${billing.restSecret}`,
      "Content-Type": "application/json",
    },
    signal: AbortSignal.timeout(REVENUECAT_REST_TIMEOUT_MILLISECONDS),
  });
  if (!response.ok) {
    throw new Error("revenuecat_subscriber_failed");
  }
  const body: unknown = await response.json();
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    throw new Error("revenuecat_subscriber_invalid");
  }
  const subscriber = (body as { subscriber?: unknown }).subscriber;
  if (subscriber === null || typeof subscriber !== "object" || Array.isArray(subscriber)) {
    throw new Error("revenuecat_subscriber_invalid");
  }
  return subscriber as RevenueCatSubscriber;
}

function millisecondsToInstant(value: unknown): string | null {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return new Date(value).toISOString();
}

function optionalText(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null;
}

function stringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.filter((item): item is string => typeof item === "string" && item.length > 0);
}
