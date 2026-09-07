import {
  type ProviderStatusResponseRead,
  ProviderStatusResponseReadSchema,
} from "@gotry-io/quota-protocol";

const jsonRequest = {
  credentials: "omit",
  redirect: "error",
  headers: { Accept: "application/json" },
} satisfies RequestInit;

/** The same rule QuotaBar uses: a dot is an incident, not an all-clear. */
export function showsProviderStatusDot(indicator: string): boolean {
  return indicator === "minor" || indicator === "major" || indicator === "critical";
}

export async function fetchProviderStatus(): Promise<ProviderStatusResponseRead["providers"]> {
  try {
    const response = await fetch("/api/v2/providers/status", jsonRequest);
    if (!response.ok) return [];
    const parsed = ProviderStatusResponseReadSchema.safeParse(await response.json());
    return parsed.success ? parsed.data.providers : [];
  } catch {
    return [];
  }
}
