import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const script = join(root, "scripts/generate-capability-matrix.mjs");
const generated = join(root, "docs/providers/README.md");
const catalogPath = join(root, "packages/provider/catalog.json");
const catalog = JSON.parse(readFileSync(catalogPath, "utf8"));

function run(args = []) {
  return spawnSync(process.execPath, ["--experimental-strip-types", script, ...args], {
    cwd: root,
    encoding: "utf8",
  });
}

/** Rewrite the catalog, run the generator, and put the original back whatever happens. */
function withCatalog(mutate, body) {
  const original = readFileSync(catalogPath, "utf8");
  const document = JSON.parse(original);
  try {
    mutate(document);
    writeFileSync(catalogPath, `${JSON.stringify(document, null, 2)}\n`);
    body();
  } finally {
    writeFileSync(catalogPath, original);
  }
}

function provider(document, id) {
  const entry = document.providers.find((candidate) => candidate.id === id);
  assert.ok(entry, `missing provider ${id}`);
  return entry;
}

test("rejects extra arguments", () => {
  const result = run(["--check", "--oops"]);
  assert.notEqual(result.status, 0);
  assert.match(result.stderr + result.stdout, /Usage: generate-capability-matrix\.mjs \[--check\]/);
});

test("--check passes on the generated matrix", () => {
  const result = run(["--check"]);
  assert.equal(result.status, 0, result.stderr + result.stdout);
  assert.match(result.stdout, /is current/);
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

test("generate is deterministic", () => {
  const first = run();
  assert.equal(first.status, 0, first.stderr + first.stdout);
  const snapshot = readFileSync(generated, "utf8");
  const second = run();
  assert.equal(second.status, 0, second.stderr + second.stdout);
  assert.equal(readFileSync(generated, "utf8"), snapshot);
  const check = run(["--check"]);
  assert.equal(check.status, 0, check.stderr + check.stdout);
});

test("the matrix names every provider, its tier, and its strategy file", () => {
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

test("every test claim in the catalog names a test function that exists", () => {
  for (const entry of catalog.providers) {
    for (const [key, validation] of Object.entries(entry.capabilities.validated)) {
      if (validation.kind !== "test") continue;
      const text = readFileSync(join(root, validation.file), "utf8");
      const keyword = validation.file.endsWith(".swift") ? "func" : "fn";
      assert.match(
        text,
        new RegExp(`${keyword}\\s+${validation.name}\\s*\\(`),
        `${entry.id} ${key}`,
      );
    }
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

test("every fixture claim in the catalog names a file that exists", () => {
  for (const entry of catalog.providers) {
    for (const [key, validation] of Object.entries(entry.capabilities.validated)) {
      if (validation.kind !== "fixture") continue;
      const text = readFileSync(join(root, validation.fixture), "utf8");
      assert.ok(text.trim().length > 0, `${entry.id} ${key}`);
    }
  }
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
