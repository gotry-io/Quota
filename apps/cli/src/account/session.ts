import type { SessionRefreshRequest, SessionRefreshResponse } from "@gotry-io/quota-protocol";
import type { AccountClient } from "./client.ts";
import {
  type AccountStateStore,
  AccountStateStoreError,
  type ActiveAccountSessionState,
} from "./state.ts";

const REFRESH_SKEW_MILLISECONDS = 60_000;

export async function activeSessionWithFreshToken(
  store: AccountStateStore,
  client: Pick<AccountClient, "refreshSession">,
  audience: "account" | "device",
  now = new Date(),
): Promise<ActiveAccountSessionState> {
  return await store.updateActiveSession(async (current) => {
    const token = audience === "account" ? current.account : current.device;
    if (Date.parse(token.access_expires_at) > now.getTime() + REFRESH_SKEW_MILLISECONDS) {
      return current;
    }
    if (Date.parse(token.refresh_expires_at) <= now.getTime()) {
      throw new AccountStateStoreError(
        "invalid_state",
        "The Quota session expired. Sign in again.",
      );
    }
    const request = {
      protocol_version: 2,
      grant_type: "refresh_token",
      client_id: "quotacli",
      token_audience: audience,
      refresh_token: token.refresh_token,
    } satisfies SessionRefreshRequest;
    return applyRefresh(current, await client.refreshSession(request), audience);
  });
}

function applyRefresh(
  current: ActiveAccountSessionState,
  response: SessionRefreshResponse,
  audience: "account" | "device",
): ActiveAccountSessionState {
  if (response.token_audience !== audience || response.account_id !== current.account_id) {
    throw principalMismatch();
  }
  if (response.token_audience === "account") {
    return {
      ...current,
      account: { account_id: current.account_id, ...response.account_session },
    };
  }
  if (
    response.device_id !== current.device_id ||
    response.device_generation !== current.device_generation
  ) {
    throw principalMismatch();
  }
  return {
    ...current,
    device: {
      account_id: current.account_id,
      device_id: current.device_id,
      device_generation: current.device_generation,
      ...response.device_session,
    },
  };
}

function principalMismatch(): AccountStateStoreError {
  return new AccountStateStoreError(
    "invalid_state",
    "The local Quota sessions do not belong to the same account and device. Sign in again.",
  );
}
