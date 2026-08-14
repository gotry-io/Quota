import { type AccountUsageSummary, AccountUsageResponseSchema } from "@gotry-io/quota-protocol";

export type AccountUsageDayResult =
  | { status: "ok"; usage: AccountUsageSummary }
  | { status: "unauthorized" }
  | { status: "error" }
  | { status: "aborted" };

export function accountUsageDayPath(date: string): string {
  const params = new URLSearchParams({
    usage_agents: "all",
    cost_mode: "calculate",
    model_catalog: "1",
    from: date,
    to: date,
  });
  return `/api/v2/account/usage/summary?${params.toString()}`;
}

export function parseAccountUsageDayResponse(
  status: number,
  body: unknown,
): Exclude<AccountUsageDayResult, { status: "aborted" }> {
  if (status === 401) return { status: "unauthorized" };
  if (status < 200 || status >= 300) return { status: "error" };
  const parsed = AccountUsageResponseSchema.safeParse(body);
  return parsed.success ? { status: "ok", usage: parsed.data.usage } : { status: "error" };
}
