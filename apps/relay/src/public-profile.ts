import {
  PublicProfileHandleSchema,
  type ModelCatalog,
  type PricingCatalog,
  type PublicUsageResponse,
} from "@gotry-io/quota-protocol";
import type { AccountState, UsageState } from "@gotry-io/relay-core";
import { buildPublicUsage } from "./public-usage.ts";
import { canonicalDigest } from "./security.ts";

/** How long a shared cache may hold a public page's answer before asking again. */
export const PUBLIC_PROFILE_MAX_AGE_SECONDS = 300;

/** A public read folds at most this many stored rows, the same bound the owner's read uses. */
const maximumPublicDailyRows = 100_000;

/**
 * How far back `all` reaches, in UTC days. The same window the Account summary answers with:
 * an answer that grows with an account's whole history eventually cannot be given.
 */
const publicUsageAllDays = 730;

export interface PublicProfileReadInput {
  state: Pick<AccountState, "findEnabledPublicProfile" | "accountUsageVersionStamp">;
  usageState: Pick<UsageState, "queryDailyUsage">;
  catalog: PricingCatalog;
  modelCatalog: ModelCatalog;
  handle: string;
  checkedAt: Date;
}

export interface PublicProfileRead {
  /** The validator for this answer, already quoted. */
  etag: string;
  /**
   * The answer itself, folded only when a caller asks for it.
   *
   * The validator is derived from aggregates over the rows the page projects, so a caller
   * holding the current answer is told so without the rollup being read at all. A public page
   * is the one read anyone may repeat, which is what makes that worth separating here.
   */
  payload(): Promise<PublicUsageResponse>;
}

/**
 * One public page, or nothing.
 *
 * A handle that is not a handle, one nobody holds, and one whose owner has switched the page
 * off are the same answer here, so nothing about them reaches the caller to be told apart.
 * There is no session in this path at all: the handle is the whole address, and what it
 * resolves to is a page rather than an Account
 * ([ADR 0037](../../../docs/decisions/0037-a-public-profile-shows-usage-not-quota.md)).
 */
export async function readPublicProfile(
  input: PublicProfileReadInput,
): Promise<PublicProfileRead | null> {
  // A handle is stored lowercase, and a link is retyped in whatever case the typist used, so a
  // read folds case before it asks. The page answers under the handle it was published as.
  const handle = input.handle.toLowerCase();
  if (!PublicProfileHandleSchema.safeParse(handle).success) return null;
  const profile = await input.state.findEnabledPublicProfile(handle);
  if (!profile) return null;
  const stamp = await input.state.accountUsageVersionStamp(profile.account_id);
  // The answer turns over on the UTC day even with no write behind it: both periods and the
  // heatmap are bounded by today's UTC date.
  const etag = `"${await canonicalDigest({
    public_profile: 1,
    handle: profile.handle,
    published_at: profile.created_at,
    updated_at: profile.updated_at,
    show_models: profile.show_models,
    show_cost: profile.show_cost,
    stamp,
    pricing_revision: input.catalog.revision,
    model_catalog_revision: input.modelCatalog.revision,
    rollover: input.checkedAt.toISOString().slice(0, 10),
  })}"`;
  return {
    etag,
    async payload(): Promise<PublicUsageResponse> {
      const allFrom = new Date(input.checkedAt.getTime() - (publicUsageAllDays - 1) * 86_400_000)
        .toISOString()
        .slice(0, 10);
      const daily = await input.usageState.queryDailyUsage(profile.account_id, {
        from: allFrom,
        limit: maximumPublicDailyRows,
      });
      return buildPublicUsage({
        handle: profile.handle,
        publishedAt: profile.created_at,
        generatedAt: input.checkedAt,
        daily: daily.rows,
        showModels: profile.show_models,
        showCost: profile.show_cost,
        catalog: input.catalog,
        modelCatalog: input.modelCatalog,
      });
    },
  };
}
