import conformanceJson from "../../protocol/fixtures/account-settings-conformance.json" with {
  type: "json",
};
import { describe, expect, it } from "vitest";
import {
  type AccountSettingsEdit,
  type FirstSyncAccountDocument,
  normalizeAccountSettings,
  planFirstSync,
  reapplyEdit,
} from "../src/index.ts";
import type { AccountSettings } from "@gotry-io/quota-protocol";

type NormalizeCase = {
  name: string;
  input: unknown;
  expected: { ok: AccountSettings } | { refused: true };
};

type FirstSyncCase = {
  name: string;
  local: AccountSettings;
  account: FirstSyncAccountDocument;
  expected: {
    action: "seed" | "adopt" | "adopt_and_merge";
    local: AccountSettings;
    write: AccountSettings | null;
  };
};

type ReapplyCase = {
  name: string;
  edit: AccountSettingsEdit;
  fresh: AccountSettings;
  expected: AccountSettings;
};

const fixture = conformanceJson as unknown as {
  normalize: NormalizeCase[];
  first_sync: FirstSyncCase[];
  reapply: ReapplyCase[];
};

describe("account settings conformance", () => {
  it("normalizes every case in the shared fixture", () => {
    expect(fixture.normalize.length).toBeGreaterThanOrEqual(8);
    for (const testCase of fixture.normalize) {
      expect(normalizeAccountSettings(testCase.input), testCase.name).toEqual(testCase.expected);
    }
  });

  it("plans first sync for every case in the shared fixture", () => {
    expect(fixture.first_sync.length).toBeGreaterThanOrEqual(4);
    for (const testCase of fixture.first_sync) {
      expect(planFirstSync(testCase.local, testCase.account), testCase.name).toEqual(
        testCase.expected,
      );
    }
  });

  it("reapplies every 412 edit in the shared fixture", () => {
    expect(fixture.reapply.length).toBeGreaterThanOrEqual(3);
    for (const testCase of fixture.reapply) {
      expect(reapplyEdit(testCase.edit, testCase.fresh), testCase.name).toEqual(testCase.expected);
    }
  });
});
