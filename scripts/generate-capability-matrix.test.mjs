import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const script = join(root, "scripts/generate-capability-matrix.mjs");
const generated = join(root, "docs/providers/README.md");
const catalogPath = join(root, "packages/provider/catalog.json");
const catalog = JSON.parse(readFileSync(catalogPath, "utf8"));

let catalogOverride;

function run(args = []) {
  return spawnSync(process.execPath, ["--experimental-strip-types", script, ...args], {
    cwd: root,
    encoding: "utf8",
    env: catalogOverride
      ? { ...process.env, QUOTA_CAPABILITY_CATALOG: catalogOverride }
      : process.env,
  });
}

/**
 * Run the generator against a changed copy of the catalog. The real file is never written:
 * `generate-reference` reads it too, `node --test` runs the two files side by side, and a write is
 * a truncate followed by a write — the reader in between parsed an empty catalog and failed main.
 */
function withCatalog(mutate, body) {
  const document = JSON.parse(readFileSync(catalogPath, "utf8"));
  const directory = mkdtempSync(join(tmpdir(), "quota-capability-catalog-"));
  try {
    mutate(document);
    catalogOverride = join(directory, "catalog.json");
    writeFileSync(catalogOverride, `${JSON.stringify(document, null, 2)}\n`);
    body();
  } finally {
    catalogOverride = undefined;
    rmSync(directory, { recursive: true, force: true });
  }
}

function provider(document, id) {
  const entry = document.providers.find((candidate) => candidate.id === id);
  assert.ok(entry, `missing provider ${id}`);
  return entry;
}

test("refuses a matrix that drops a provider row, its tier, or its strategy link", () => {
  const text = readFileSync(generated, "utf8");
  for (const entry of catalog.providers) {
    assert.match(text, new RegExp(`\\]\\(${entry.id}\\.md\\)`), entry.id);
    assert.match(text, new RegExp(`\`${entry.id}\``), entry.id);
  }
  assert.match(text, /\| First-class \|/);
  assert.match(text, /\| Best-effort \|/);
  assert.match(text, /\| Provider \| Tier \| F \| T \| L \| U \|/);
  assert.match(text, /## First-class gaps/);
  assert.match(text, /ADR 0060\]\(\.\.\/decisions\/0060-provider-freeze-and-two-tiers\.md\)/);
});

test("--check detects drift", () => {
  const original = readFileSync(generated, "utf8");
  try {
    writeFileSync(generated, `${original}<!-- drifted -->\n`);
    const result = run(["--check"]);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr + result.stdout, /out of date/);
  } finally {
    writeFileSync(generated, original);
  }
});

test("a test file that is not a file is refused", () => {
  withCatalog(
    (document) => {
      provider(document, "codex").capabilities.validated["quota.monthly"] = {
        kind: "test",
        file: "packages/service/src/providers/nowhere.rs",
        name: "maps_free_monthly_and_weekly_windows_by_duration",
      };
    },
    () => {
      const result = run(["--check"]);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr + result.stdout, /nowhere\.rs, which is not a file/);
    },
  );
});

test("a test name the file does not define is refused", () => {
  withCatalog(
    (document) => {
      provider(document, "codex").capabilities.validated["quota.monthly"].name =
        "maps_a_window_nobody_wrote";
    },
    () => {
      const result = run(["--check"]);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr + result.stdout, /defines no fn maps_a_window_nobody_wrote/);
    },
  );
});

test("a function without a test attribute is refused", () => {
  withCatalog(
    (document) => {
      // `map_credits` is production code in the same file, not a test.
      provider(document, "codex").capabilities.validated["quota.balance"].name = "map_credits";
    },
    () => {
      const result = run(["--check"]);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr + result.stdout, /defines fn map_credits, which is not a test/);
    },
  );
});

/**
 * No cell cites Swift today, so the Swift branch is exercised directly. A valid cite passes
 * provenance and is then refused only as drift, which is the proof it was accepted.
 */
test("a Swift @Test function is accepted and a plain Swift func is not", () => {
  withCatalog(
    (document) => {
      provider(document, "codex").capabilities.validated["quota.monthly"] = {
        kind: "test",
        file: "packages/apple-client/Tests/QuotaProviderWebTests/ProviderWebConformanceTests.swift",
        name: "everyProviderAnswersTheSharedConformanceFixture",
      };
    },
    () => {
      const result = run(["--check"]);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr + result.stdout, /out of date/);
      assert.doesNotMatch(result.stderr + result.stdout, /which is not a test/);
    },
  );
  withCatalog(
    (document) => {
      provider(document, "codex").capabilities.validated["quota.monthly"] = {
        kind: "test",
        file: "packages/apple-client/Sources/QuotaProviderWeb/CodexWebCollector.swift",
        name: "collectWithBearer",
      };
    },
    () => {
      const result = run(["--check"]);
      assert.notEqual(result.status, 0);
      assert.match(
        result.stderr + result.stdout,
        /defines func collectWithBearer, which is not a test/,
      );
    },
  );
});

test("a first-class provider cannot gain an unverified cell the gap list does not name", () => {
  withCatalog(
    (document) => {
      provider(document, "codex").capabilities.validated["quota.monthly"] = {
        kind: "unverified",
      };
    },
    () => {
      const result = run(["--check"]);
      assert.notEqual(result.status, 0);
      assert.match(
        result.stderr + result.stdout,
        /first-class provider codex has an unverified quota\.monthly that capabilities\.known_gaps does not name/,
      );
    },
  );
});

test("a closed gap cannot stay on the gap list, and best-effort carries none", () => {
  withCatalog(
    (document) => {
      provider(document, "codex").capabilities.known_gaps = ["quota.monthly"];
    },
    () => {
      const result = run(["--check"]);
      assert.notEqual(result.status, 0);
      assert.match(
        result.stderr + result.stdout,
        /names quota\.monthly in known_gaps and it is no longer unverified/,
      );
    },
  );
  withCatalog(
    (document) => {
      provider(document, "grok").capabilities.known_gaps = ["quota.weekly"];
    },
    () => {
      const result = run(["--check"]);
      assert.notEqual(result.status, 0);
      assert.match(
        result.stderr + result.stdout,
        /provider grok is best_effort and must leave known_gaps empty/,
      );
    },
  );
});

test("a fixture path that is not a file is refused", () => {
  withCatalog(
    (document) => {
      provider(document, "codex").capabilities.validated["quota.five_hour"] = {
        kind: "fixture",
        fixture: "packages/provider/fixtures/does-not-exist.json",
        pointer: "/codex",
      };
    },
    () => {
      const result = run(["--check"]);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr + result.stdout, /does-not-exist\.json, which is not a file/);
    },
  );
});

test("a JSON pointer that resolves to nothing is refused", () => {
  withCatalog(
    (document) => {
      provider(document, "codex").capabilities.validated["quota.five_hour"].pointer =
        "/cases/0/expect/snapshot/windows/99";
    },
    () => {
      const result = run(["--check"]);
      assert.notEqual(result.status, 0);
      assert.match(
        result.stderr + result.stdout,
        /has no \/cases\/0\/expect\/snapshot\/windows\/99/,
      );
    },
  );
});

test("a .json fixture with no pointer is refused", () => {
  withCatalog(
    (document) => {
      delete provider(document, "codex").capabilities.validated["quota.five_hour"].pointer;
    },
    () => {
      const result = run(["--check"]);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr + result.stdout, /must name the JSON pointer into it/);
    },
  );
});

test("a live date that has not happened is refused", () => {
  withCatalog(
    (document) => {
      provider(document, "codex").capabilities.validated["status.statuspage_v2"] = {
        kind: "live",
        date: "2999-01-01",
      };
    },
    () => {
      const result = run(["--check"]);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr + result.stdout, /2999-01-01, which has not happened/);
    },
  );
});

test("a capability the catalog's own fields decide cannot disagree", () => {
  withCatalog(
    (document) => {
      delete provider(document, "codex").capabilities.validated["channel.browser_session_macos"];
    },
    () => {
      const result = run(["--check"]);
      assert.notEqual(result.status, 0);
      assert.match(
        result.stderr + result.stdout,
        /must claim channel\.browser_session_macos exactly when browser_session is not null/,
      );
    },
  );
  withCatalog(
    (document) => {
      provider(document, "codex").capabilities.validated["channel.api_key"] = {
        kind: "unverified",
      };
    },
    () => {
      const result = run(["--check"]);
      assert.notEqual(result.status, 0);
      assert.match(
        result.stderr + result.stdout,
        /must claim channel\.api_key exactly when credential_config is not null/,
      );
    },
  );
});

test("a provider claiming no quota window is refused", () => {
  withCatalog(
    (document) => {
      const entry = provider(document, "deepseek");
      delete entry.capabilities.validated["quota.balance"];
    },
    () => {
      const result = run(["--check"]);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr + result.stdout, /claims no quota window/);
    },
  );
});

test("an unknown capability key is refused", () => {
  withCatalog(
    (document) => {
      provider(document, "codex").capabilities.validated["quota.hourly"] = { kind: "unverified" };
    },
    () => {
      const result = run(["--check"]);
      assert.notEqual(result.status, 0);
      assert.match(result.stderr + result.stdout, /claims unknown capability quota\.hourly/);
    },
  );
});

test("the schema and the generator agree on the capability key set", () => {
  const schema = JSON.parse(
    readFileSync(join(root, "packages/provider/catalog.schema.json"), "utf8"),
  );
  const keys = schema.$defs.capabilities.properties.validated.propertyNames.enum;
  const source = readFileSync(script, "utf8");
  for (const key of keys) {
    assert.match(source, new RegExp(`"${key.replace(".", "\\.")}"`), key);
  }
  const claimed = new Set(
    catalog.providers.flatMap((entry) => Object.keys(entry.capabilities.validated)),
  );
  for (const key of claimed) {
    assert.ok(keys.includes(key), `catalog claims ${key}, which the schema does not allow`);
  }
});
