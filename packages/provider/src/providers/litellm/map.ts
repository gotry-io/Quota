import type { QuotaWindow } from "@gotry-io/quota-protocol";
import { asRecord, readNumber, readString } from "../../runtime/files.ts";
import { clampPercent } from "../../runtime/time.ts";

export interface LiteLLMKeyInfo {
  userId?: string;
  teamId?: string;
  keyName?: string;
  spendUsd?: number;
}

export interface LiteLLMBudget {
  spendUsd: number;
  budgetUsd?: number;
  resetsAt?: string;
  label: string;
}

export function mapLiteLLMKeyInfo(json: unknown): LiteLLMKeyInfo | undefined {
  const root = asRecord(json);
  const info = asRecord(root?.info) ?? asRecord(root?.data) ?? root;
  if (!info) {
    return undefined;
  }
  const userId = readString(info, "user_id", "userId");
  const teamId = readString(info, "team_id", "teamId");
  const keyName = readString(info, "key_name", "keyName", "key_alias");
  const spend = readNumber(info, "spend") ?? readNumber(info, "spend_usd");
  if (!userId && !teamId && spend === undefined) {
    // Still useful if nested under key
    const nested = asRecord(info.key) ?? asRecord(info.key_info);
    if (nested) {
      return mapLiteLLMKeyInfo(nested);
    }
  }
  return {
    ...(userId ? { userId } : {}),
    ...(teamId ? { teamId } : {}),
    ...(keyName ? { keyName } : {}),
    ...(spend !== undefined ? { spendUsd: spend } : {}),
  };
}

export function mapLiteLLMUserInfo(json: unknown): LiteLLMBudget | undefined {
  const root = asRecord(json);
  const user = asRecord(root?.user_info) ?? asRecord(root?.user) ?? asRecord(root?.data) ?? root;
  if (!user) {
    return undefined;
  }
  const spend =
    readNumber(user, "spend") ??
    readNumber(user, "user_spend") ??
    readNumber(user, "spend_usd") ??
    0;
  const budget =
    readNumber(user, "max_budget") ??
    readNumber(user, "user_max_budget") ??
    readNumber(user, "budget");
  const resetsAt = readString(user, "budget_reset_at", "budget_duration_reset_at");
  return {
    spendUsd: spend,
    ...(budget !== undefined && budget > 0 ? { budgetUsd: budget } : {}),
    ...(resetsAt && !Number.isNaN(Date.parse(resetsAt)) ? { resetsAt } : {}),
    label: "Personal",
  };
}

export function mapLiteLLMTeamInfo(json: unknown, teamId: string): LiteLLMBudget | undefined {
  const root = asRecord(json);
  const team =
    asRecord(root?.team_info) ??
    asRecord(root?.team) ??
    asRecord(root?.data) ??
    findTeamInList(root, teamId) ??
    root;
  if (!team) {
    return undefined;
  }
  const spend =
    readNumber(team, "spend") ??
    readNumber(team, "team_spend") ??
    readNumber(team, "spend_usd") ??
    0;
  const budget =
    readNumber(team, "max_budget") ??
    readNumber(team, "team_max_budget") ??
    readNumber(team, "budget");
  const alias = readString(team, "team_alias", "alias", "name");
  const resetsAt = readString(team, "budget_reset_at", "budget_duration_reset_at");
  return {
    spendUsd: spend,
    ...(budget !== undefined && budget > 0 ? { budgetUsd: budget } : {}),
    ...(resetsAt && !Number.isNaN(Date.parse(resetsAt)) ? { resetsAt } : {}),
    label: alias ? `Team ${alias}` : "Team",
  };
}

export function mapLiteLLMWindows(input: {
  personal?: LiteLLMBudget;
  team?: LiteLLMBudget;
}): QuotaWindow[] {
  const windows: QuotaWindow[] = [];
  if (input.personal) {
    const w = budgetWindow("personal", input.personal);
    if (w) {
      windows.push(w);
    }
  }
  if (input.team) {
    const w = budgetWindow("team", input.team);
    if (w) {
      windows.push(w);
    }
  }
  return windows;
}

function budgetWindow(id: string, budget: LiteLLMBudget): QuotaWindow | undefined {
  if (budget.budgetUsd !== undefined && budget.budgetUsd > 0) {
    const remaining = Math.max(0, budget.budgetUsd - budget.spendUsd);
    const window: QuotaWindow = {
      id,
      title: `${budget.label} budget`,
      used_percent: clampPercent((budget.spendUsd / budget.budgetUsd) * 100),
      remaining_value: remaining,
      limit_value: budget.budgetUsd,
      value_unit: "usd",
    };
    if (budget.resetsAt) {
      window.resets_at = budget.resetsAt;
    }
    return window;
  }
  // Spend-only: no hard budget — surface absolute spend as remaining=0 of a soft window.
  if (budget.spendUsd > 0) {
    return {
      id,
      title: `${budget.label} spend`,
      used_percent: 100,
      remaining_value: 0,
      limit_value: budget.spendUsd,
      value_unit: "usd",
    };
  }
  return undefined;
}

function findTeamInList(
  root: Record<string, unknown> | undefined,
  teamId: string,
): Record<string, unknown> | undefined {
  if (!root) {
    return undefined;
  }
  const teams = root.teams ?? root.team_list;
  if (!Array.isArray(teams)) {
    return undefined;
  }
  for (const entry of teams) {
    const record = asRecord(entry);
    if (!record) {
      continue;
    }
    const id = readString(record, "team_id", "id");
    if (id === teamId) {
      return record;
    }
  }
  return undefined;
}
