use super::{
    BillingChannel, ChannelSource, ContextBucket, CoverageReasonCode, CoverageStatus,
    DEFAULT_PARSER_REVISION, InferenceProvider, MAX_JSONL_LINE_BYTES, MAX_USAGE_MODELS,
    MAX_USAGE_ROWS, NormalizedUsageEvent, UsageAgent, UsageFileIndex, UsageHourlyFact,
    UsageScanOptions, aggregate_usage_events, build_local_usage_summary, fold_usage_facts,
    scan_claude_usage, scan_codex_usage, scan_cursor_usage, scan_grok_usage, scan_local_usage,
    scan_opencode_usage, scan_pi_usage,
};
use crate::pricing::{
    CalculatedUsageRowCost, PricingCatalog, PricingCatalogEntry, PricingRates, UsageCostAssumption,
    UsageCostBasis, UsageCostMode, UsageCostStatus, UsageUnpricedReason, calculate_usage_cost,
    calculate_usage_row_cost, validate_pricing_catalog,
};
use num_bigint::BigUint;
use rusqlite::{Connection, params};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

const RANGE_START: &str = "2026-08-02T00:00:00Z";
const RANGE_END: &str = "2026-08-03T00:00:00Z";

fn fixture(name: &str) -> &'static str {
    match name {
        "codex" => {
            include_str!("../../fixtures/usage/codex.jsonl")
        }
        "claude" => {
            include_str!("../../fixtures/usage/claude.jsonl")
        }
        "grok" => {
            include_str!("../../fixtures/usage/grok.jsonl")
        }
        "pi" => include_str!("../../fixtures/usage/pi.jsonl"),
        "cursor" => include_str!("../../fixtures/usage/cursor.jsonl"),
        "opencode" => include_str!("../../fixtures/usage/opencode-message.jsonl"),
        "pricing" => {
            include_str!("../../fixtures/usage/pricing.json")
        }
        _ => panic!("unknown fixture"),
    }
}

fn root(name: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!("quota-usage-{name}-{}", std::process::id()));
    fs::create_dir_all(&path).expect("create temporary Usage root");
    path
}

fn options(path: &Path) -> UsageScanOptions {
    UsageScanOptions {
        roots: Some(vec![path.to_path_buf()]),
        start_at: RANGE_START.into(),
        end_at: RANGE_END.into(),
        ..UsageScanOptions::default()
    }
}

fn epoch_millis(value: &str) -> i64 {
    chrono::DateTime::parse_from_rfc3339(value)
        .expect("valid test timestamp")
        .timestamp_millis()
}

#[test]
fn parser_fixtures_preserve_normalized_fields_and_coverage() {
    let cases = [
        (UsageAgent::Codex, "codex", 2usize),
        (UsageAgent::ClaudeCode, "claude", 2usize),
        (UsageAgent::Grok, "grok", 1usize),
        (UsageAgent::Pi, "pi", 1usize),
        (UsageAgent::Cursor, "cursor", 2usize),
    ];
    for (agent, name, expected_records) in cases {
        let path = root(name);
        let filename = if agent == UsageAgent::Codex {
            format!("rollout-{name}.jsonl")
        } else if agent == UsageAgent::Grok {
            "updates.jsonl".into()
        } else {
            format!("{name}.jsonl")
        };
        fs::write(path.join(filename), fixture(name)).expect("write fixture");
        let result = scan_local_usage(agent, &options(&path)).expect("scan fixture");
        assert_eq!(
            result.coverage.status,
            CoverageStatus::Complete,
            "fixture {name}"
        );
        assert_eq!(result.records.len(), expected_records, "fixture {name}");
        assert!(
            result
                .records
                .iter()
                .all(|record| !record.event.model.eq("unknown"))
        );
        match agent {
            UsageAgent::Codex => {
                assert_eq!(result.records[0].event.model, "gpt-5.2-codex");
                assert_eq!(result.records[0].event.input_tokens, 1_000);
                assert_eq!(result.records[0].event.cache_read_tokens, 200);
                assert_eq!(result.records[0].event.cache_write_inferred_tokens, 100);
                assert_eq!(result.records[0].event.output_tokens, 200);
                assert_eq!(result.records[0].event.reasoning_tokens, 50);
                assert_eq!(
                    result.records[0].event.context_bucket,
                    ContextBucket::Le128k
                );
                assert_eq!(result.records[0].event.service_tier, "unknown");
                assert_eq!(result.records[0].event.speed, "unknown");
                assert_eq!(result.records[1].event.input_tokens, 130_000);
                assert_eq!(
                    result.records[1].event.context_bucket,
                    ContextBucket::Gt128kLe200k
                );
                assert_eq!(result.records[1].event.service_tier, "priority");
                assert_eq!(result.records[1].event.speed, "fast");
            }
            UsageAgent::ClaudeCode => {
                let synthetic = &result.records[0].event;
                assert_eq!(synthetic.model, "synthetic");
                assert_eq!(synthetic.billing_channel, BillingChannel::Unknown);
                assert_eq!(synthetic.input_tokens, 135);
                assert_eq!(synthetic.cache_write_inferred_tokens, 25);
                assert_eq!(synthetic.output_tokens, 50);
                assert_eq!(synthetic.source_cost_microusd.as_deref(), Some("120000"));
                assert_eq!(synthetic.source_cost_covered_requests, 1);
                let detailed = &result.records[1].event;
                assert_eq!(detailed.billing_channel, BillingChannel::AnthropicDirect);
                assert_eq!(detailed.cache_write_5m_tokens, 100);
                assert_eq!(detailed.cache_write_1h_tokens, 200);
                assert_eq!(detailed.reasoning_tokens, 40);
                assert_eq!(detailed.billable_tools.web_search, 2);
                assert_eq!(detailed.billable_tools.web_fetch, 1);
                assert_eq!(detailed.service_tier, "priority");
                assert_eq!(detailed.speed, "fast");
                assert_eq!(detailed.inference_geo, "us");
            }
            UsageAgent::Grok => {
                let event = &result.records[0].event;
                assert_eq!(event.billing_channel, BillingChannel::XaiDirect);
                assert_eq!(event.input_tokens, 125);
                assert_eq!(event.cache_read_tokens, 20);
                assert_eq!(event.cache_write_inferred_tokens, 5);
                assert_eq!(event.output_tokens, 30);
                assert_eq!(event.reasoning_tokens, 10);
                assert_eq!(event.requests, 3);
                assert_eq!(event.source_cost_covered_requests, 3);
                assert_eq!(event.source_cost_microusd.as_deref(), Some("12"));
                assert_eq!(event.occurred_at, "2026-08-02T09:01:00.000Z");
            }
            UsageAgent::Pi => {
                let event = &result.records[0].event;
                assert_eq!(event.billing_channel, BillingChannel::AnthropicDirect);
                assert_eq!(event.input_tokens, 130);
                assert_eq!(event.cache_read_tokens, 20);
                assert_eq!(event.cache_write_inferred_tokens, 10);
                assert_eq!(event.output_tokens, 40);
                assert_eq!(event.reasoning_tokens, 5);
                assert_eq!(event.source_cost_microusd.as_deref(), Some("20000"));
            }
            UsageAgent::Cursor => {
                let native = &result.records[0].event;
                assert_eq!(native.model, "gpt-5");
                assert_eq!(native.billing_channel, BillingChannel::Unknown);
                assert_eq!(native.input_tokens, 1_000);
                assert_eq!(native.output_tokens, 200);
                assert_eq!(native.occurred_at, "2026-08-02T10:00:00.000Z");
                let api = &result.records[1].event;
                assert_eq!(api.model, "claude-4.6-sonnet");
                assert_eq!(api.billing_channel, BillingChannel::AnthropicDirect);
                assert_eq!(api.input_tokens, 95);
                assert_eq!(api.cache_read_tokens, 10);
                assert_eq!(api.cache_write_inferred_tokens, 5);
                assert_eq!(api.output_tokens, 20);
            }
            UsageAgent::OpenCode => unreachable!(),
        }
        let _ = fs::remove_dir_all(path);
    }
}

#[test]
fn codex_preserves_opaque_provider_model_names() {
    let path = root("codex-opaque-models");
    let log = r#"{"type":"turn_context","payload":{"model":"GPT-5.5[1m]"}}
{"timestamp":"2026-08-02T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":2}}}}
{"type":"turn_context","payload":{"model":"openrouter-3o[1m]"}}
{"timestamp":"2026-08-02T10:03:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"output_tokens":3}}}}
"#;
    fs::write(path.join("rollout-opaque.jsonl"), log).expect("write Codex fixture");
    let result = scan_codex_usage(&options(&path)).expect("scan opaque Codex models");
    assert_eq!(result.coverage.status, CoverageStatus::Complete);
    assert_eq!(
        result
            .records
            .iter()
            .map(|record| record.event.model.as_str())
            .collect::<Vec<_>>(),
        ["GPT-5.5[1m]", "openrouter-3o[1m]"]
    );
}

#[test]
fn codex_uses_only_explicit_known_model_provider_channels() {
    let path = root("codex-model-provider");
    let log = r#"{"type":"turn_context","payload":{"model":"gpt-5","model_provider":"openai"}}
{"timestamp":"2026-08-02T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":2}}}}
{"type":"turn_context","payload":{"model":"custom","model_provider":"my-gateway"}}
{"timestamp":"2026-08-02T10:03:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"output_tokens":3}}}}
"#;
    fs::write(path.join("rollout-provider.jsonl"), log).expect("write Codex provider fixture");
    let result = scan_codex_usage(&options(&path)).expect("scan Codex providers");
    assert_eq!(result.records.len(), 2);
    assert_eq!(
        result.records[0].event.billing_channel,
        BillingChannel::OpenaiDirect
    );
    assert_eq!(
        result.records[0].event.channel_source,
        super::ChannelSource::Explicit
    );
    assert_eq!(
        result.records[1].event.billing_channel,
        BillingChannel::Unknown
    );
    assert_eq!(
        result.records[1].event.channel_source,
        super::ChannelSource::Unknown
    );
}

#[test]
fn codex_invalid_context_does_not_reuse_the_previous_model() {
    let path = root("codex-stale-model");
    let invalid_model = "m".repeat(129);
    let log = format!(
        "{}\n{}\n{}\n{}\n{}\n",
        json!({"type":"turn_context","payload":{"model":"old-model"}}),
        json!({"timestamp":"2026-08-02T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"output_tokens":1}}}}),
        json!({"type":"turn_context","payload":{"model":invalid_model}}),
        json!({"timestamp":"2026-08-02T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":20,"output_tokens":2}}}}),
        json!({"type":"turn_context","payload":{"model":"new-model"}}),
    ) + &json!({"timestamp":"2026-08-02T10:02:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":30,"output_tokens":3}}}}).to_string();
    fs::write(path.join("rollout-stale-model.jsonl"), log).expect("write stale model fixture");
    let result = scan_codex_usage(&options(&path)).expect("scan stale model fixture");
    assert_eq!(result.records.len(), 2);
    assert_eq!(result.records[0].event.model, "old-model");
    assert_eq!(result.records[1].event.model, "new-model");
    assert!(
        result
            .records
            .iter()
            .all(|record| record.event.model != invalid_model)
    );
    let _ = fs::remove_dir_all(path);
}

#[test]
fn claude_zero_cost_empty_rows_and_unsafe_input_totals_match_legacy_parser() {
    let path = root("claude-edge");
    let lines = [
        json!({
            "timestamp": "2026-08-02T12:00:00Z",
            "message": {
                "role": "assistant",
                "model": "claude-sonnet-4-6",
                "usage": {"input_tokens": 0, "output_tokens": 0}
            },
            "costUSD": 0
        }),
        json!({
            "timestamp": "2026-08-02T12:01:00Z",
            "message": {
                "role": "assistant",
                "model": "claude-sonnet-4-6",
                "usage": {"input_tokens": 1, "output_tokens": 0}
            },
            "costUSD": 0
        }),
        json!({
            "timestamp": "2026-08-02T12:02:00Z",
            "message": {
                "role": "assistant",
                "model": "claude-sonnet-4-6",
                "usage": {
                    "input_tokens": super::MAX_SAFE_COUNT,
                    "output_tokens": 1
                }
            }
        }),
    ];
    fs::write(
        path.join("claude-edge.jsonl"),
        lines
            .iter()
            .map(serde_json::Value::to_string)
            .collect::<Vec<_>>()
            .join("\n"),
    )
    .expect("write Claude edge fixture");
    let result = scan_claude_usage(&options(&path)).expect("scan Claude edge fixture");
    assert_eq!(result.records.len(), 1);
    assert_eq!(result.records[0].event.input_tokens, 1);
    assert_eq!(
        result.records[0].event.source_cost_microusd.as_deref(),
        Some("0")
    );
    assert_eq!(result.records[0].event.source_cost_covered_requests, 1);
    assert_eq!(result.coverage.status, CoverageStatus::Partial);
    assert!(
        result
            .coverage
            .reasons
            .iter()
            .any(|reason| reason.code == CoverageReasonCode::InvalidUsage)
    );
    let _ = fs::remove_dir_all(path);
}

#[test]
fn codex_duplicate_cumulative_totals_do_not_emit_duplicate_requests() {
    let path = root("codex-duplicate");
    fs::write(path.join("rollout-fixture.jsonl"), fixture("codex")).expect("write fixture");
    let result = scan_codex_usage(&options(&path)).expect("scan codex");
    assert_eq!(result.records.len(), 2);
    assert_eq!(result.records[0].event.cache_read_tokens, 200);
    assert_eq!(result.records[1].event.model, "gpt-5.3-codex");
    let _ = fs::remove_dir_all(path);
}

#[test]
fn codex_attributes_leading_usage_and_thread_settings() {
    let path = root("codex-state");
    let lines = [
        json!({
            "timestamp": "2026-08-02T10:01:00.000Z",
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {"last_token_usage": {"input_tokens": 10, "cached_input_tokens": 2, "output_tokens": 1}}
            }
        }),
        json!({
            "timestamp": "2026-08-02T10:01:01.000Z",
            "type": "turn_context",
            "payload": {"model": "gpt-5.6-sol"}
        }),
        json!({
            "timestamp": "2026-08-02T10:02:00.000Z",
            "type": "event_msg",
            "payload": {
                "type": "thread_settings_applied",
                "thread_settings": {"service_tier": "fast"}
            }
        }),
        json!({
            "timestamp": "2026-08-02T10:03:00.000Z",
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {"last_token_usage": {"input_tokens": 20, "output_tokens": 4}}
            }
        }),
    ];
    fs::write(
        path.join("rollout-state.jsonl"),
        lines
            .iter()
            .map(serde_json::Value::to_string)
            .collect::<Vec<_>>()
            .join("\n"),
    )
    .expect("write Codex state fixture");

    let result = scan_codex_usage(&options(&path)).expect("scan Codex state");
    assert_eq!(result.records.len(), 2);
    assert_eq!(result.records[0].event.model, "gpt-5.6-sol");
    assert_eq!(result.records[0].event.input_tokens, 10);
    assert_eq!(result.records[0].event.service_tier, "unknown");
    assert_eq!(result.records[1].event.service_tier, "priority");
    assert_eq!(result.records[1].event.speed, "fast");
    let _ = fs::remove_dir_all(path);
}

#[test]
fn parser_limits_and_invalid_records_are_partial_without_payload_leakage() {
    let path = root("parser-limits");
    let invalid_lines = [
        json!({
            "timestamp": "2026-08-02T10:00:00.000Z",
            "type": "turn_context",
            "payload": {"model": "gpt-5.2-codex"}
        }),
        json!({
            "timestamp": "2026-08-02T10:01:00.000Z",
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {"last_token_usage": {"input_tokens": 10, "cached_input_tokens": 11, "output_tokens": 1}}
            }
        }),
        json!({
            "timestamp": "2026-08-02T10:02:00.000Z",
            "type": "event_msg",
            "payload": {
                "type": "token_count",
                "info": {"last_token_usage": {"input_tokens": 9007199254740992u64, "output_tokens": 1}}
            }
        }),
        json!({"type": "future_usage", "usage": {"tokens": 1, "tool_payload": "secret"}}),
    ];
    fs::write(
        path.join("rollout-invalid.jsonl"),
        format!(
            "{}\n{{\"timestamp\":\"2026-08-02T10:03:00.000Z\",\"type\":\"event_msg\"",
            invalid_lines
                .iter()
                .map(serde_json::Value::to_string)
                .collect::<Vec<_>>()
                .join("\n")
        ),
    )
    .expect("write invalid Codex fixture");

    let result = scan_codex_usage(&options(&path)).expect("scan invalid Codex fixture");
    assert!(result.records.is_empty());
    assert_eq!(result.coverage.status, CoverageStatus::Partial);
    assert_eq!(
        result
            .coverage
            .reasons
            .iter()
            .map(|reason| reason.code)
            .collect::<Vec<_>>(),
        vec![
            CoverageReasonCode::InvalidUsage,
            CoverageReasonCode::UnknownRecord,
            CoverageReasonCode::TruncatedTail,
        ]
    );
    let serialized = serde_json::to_string(
        &result
            .records
            .iter()
            .map(|record| &record.event)
            .collect::<Vec<_>>(),
    )
    .unwrap_or_default();
    assert!(!serialized.contains("tool_payload"));
    let _ = fs::remove_dir_all(path);
}

#[test]
fn file_index_skips_replaces_cleans_deleted_and_invalidates_by_revision() {
    let path = root("file-index");
    let source_path = path.join("rollout-file-index.jsonl");
    fs::write(&source_path, fixture("codex")).expect("write fixture");

    let first = scan_codex_usage(&options(&path)).expect("initial scan");
    assert_eq!(first.scanned_source_count, 1);
    assert_eq!(first.skipped_source_count, 0);
    assert_eq!(first.sources.len(), 1);
    assert_eq!(first.sources[0].records.len(), 2);
    assert!(first.replacement_scan_complete());
    let source = &first.sources[0].source;
    let source_id = source.source_file_id.clone();
    let index: HashMap<String, UsageFileIndex> = [(
        source_id.clone(),
        UsageFileIndex {
            source_file_id: source_id.clone(),
            identity: source.identity.clone(),
            size: source.size,
            modified_ns: source.modified_ns,
            parser_revision: first.sources[0].index.parser_revision.clone(),
        },
    )]
    .into_iter()
    .collect();

    let unchanged_options = UsageScanOptions {
        file_index: index.clone(),
        ..options(&path)
    };
    let unchanged = scan_codex_usage(&unchanged_options).expect("unchanged scan");
    assert_eq!(unchanged.scanned_source_count, 0);
    assert_eq!(unchanged.skipped_source_count, 1);
    assert!(unchanged.records.is_empty());
    assert_eq!(unchanged.unchanged_source_file_ids, vec![source_id.clone()]);
    assert!(unchanged.sources.is_empty());
    assert!(!unchanged.replacement_scan_complete());

    let invalidated = UsageScanOptions {
        parser_revision: "usage-rust-test-revision".into(),
        file_index: index.clone(),
        ..options(&path)
    };
    let invalidated_result = scan_codex_usage(&invalidated).expect("revision invalidation");
    assert_eq!(invalidated_result.scanned_source_count, 1);
    assert_eq!(invalidated_result.skipped_source_count, 0);
    assert_eq!(invalidated_result.sources[0].records.len(), 2);
    assert!(invalidated_result.replacement_scan_complete());

    let updated = format!(
        "{}\n{}\n",
        fixture("codex").trim_end(),
        r#"{"timestamp":"2026-08-02T12:00:00.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"output_tokens":20}}}}"#
    );
    fs::write(&source_path, updated).expect("replace source contents");
    let changed = scan_codex_usage(&unchanged_options).expect("changed scan");
    assert_eq!(changed.scanned_source_count, 1);
    assert_eq!(changed.skipped_source_count, 0);
    assert_eq!(changed.records.len(), 3);
    assert_eq!(changed.sources.len(), 1);
    assert_eq!(changed.sources[0].records.len(), 3);
    assert!(changed.replacement_scan_complete());

    fs::remove_file(&source_path).expect("delete source");
    let deleted = scan_codex_usage(&unchanged_options).expect("deleted scan");
    assert_eq!(deleted.scanned_source_count, 0);
    assert_eq!(deleted.skipped_source_count, 0);
    assert!(deleted.records.is_empty());
    assert_eq!(deleted.deleted_source_file_ids, vec![source_id]);
    assert!(deleted.replacement_scan_complete());

    let _ = fs::remove_dir_all(path);
}

#[test]
fn opencode_legacy_and_pricing_are_protocol_safe() {
    let path = root("opencode");
    fs::write(path.join("message.json"), fixture("opencode")).expect("write fixture");
    let result = scan_opencode_usage(&options(&path)).expect("scan opencode");
    assert_eq!(result.records.len(), 1);
    assert_eq!(
        result.records[0].event.billing_channel,
        BillingChannel::OpenaiDirect
    );
    let rows = aggregate_usage_events(
        &result
            .records
            .iter()
            .map(|record| record.event.clone())
            .collect::<Vec<_>>(),
        "UTC",
    )
    .expect("aggregate Usage");
    assert_eq!(
        fold_usage_facts(&rows).expect("fold totals").input_tokens,
        160
    );
    let catalog_value: Value = serde_json::from_str(fixture("pricing")).expect("pricing JSON");
    let validation = validate_pricing_catalog(&catalog_value);
    assert!(validation.valid, "pricing fixture should validate");
    let catalog = validation.catalog.expect("validated catalog");
    let cost = calculate_usage_cost(&rows, Some(&catalog), UsageCostMode::Calculate)
        .expect("calculate cost");
    assert_eq!(cost.status, UsageCostStatus::Complete);
    assert_eq!(cost.amount_microusd.as_deref(), Some("335"));
    let _ = fs::remove_dir_all(path);
}

#[test]
fn opencode_sqlite_reads_completed_or_created_and_ignores_empty_models() {
    let path = root("opencode-sqlite");
    let database_path = path.join("opencode.db");
    let connection = Connection::open(&database_path).expect("open SQLite fixture");
    connection
        .execute_batch(
            "CREATE TABLE message(
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                time_created INTEGER NOT NULL,
                time_updated INTEGER NOT NULL,
                data TEXT NOT NULL
            )",
        )
        .expect("create OpenCode schema");
    let insert = "INSERT INTO message(id, session_id, time_created, time_updated, data)
                  VALUES (?1, 'session', ?2, ?2, ?3)";
    let timestamp = epoch_millis("2026-08-02T10:00:00Z");
    let message = json!({
        "role": "assistant",
        "modelID": "gpt-5.6-sol",
        "providerID": "openai",
        "time": {"created": timestamp, "completed": timestamp + 60_000},
        "tokens": {"input": 100, "output": 20, "reasoning": 5, "cache": {"read": 50, "write": 10}},
        "cost": 0.01
    });
    connection
        .execute(
            insert,
            params!["message-usage", timestamp, message.to_string()],
        )
        .expect("insert OpenCode usage");
    let empty = json!({
        "role": "assistant",
        "modelID": "unknown",
        "providerID": "openai",
        "time": {"created": timestamp + 1},
        "tokens": {"input": 0, "output": 0, "reasoning": 0, "cache": {"read": 0, "write": 0}},
        "cost": 0
    });
    connection
        .execute(
            insert,
            params!["message-empty", timestamp + 1, empty.to_string()],
        )
        .expect("insert empty OpenCode usage");
    connection.close().expect("close SQLite fixture");

    let result = scan_opencode_usage(&options(&path)).expect("scan OpenCode SQLite");
    assert_eq!(result.coverage.status, CoverageStatus::Complete);
    assert_eq!(result.records.len(), 1);
    let event = &result.records[0].event;
    assert_eq!(event.occurred_at, "2026-08-02T10:01:00.000Z");
    assert_eq!(event.input_tokens, 160);
    assert_eq!(event.cache_read_tokens, 50);
    assert_eq!(event.cache_write_inferred_tokens, 10);
    assert_eq!(event.output_tokens, 20);
    assert_eq!(event.reasoning_tokens, 5);
    assert_eq!(event.source_cost_microusd.as_deref(), Some("10000"));
    assert_eq!(result.sources.len(), 1);
    let _ = fs::remove_dir_all(path);
}

#[test]
fn opencode_resolves_registered_moonshot_and_deepseek_provider_ids() {
    let path = root("opencode-moonshot-deepseek");
    let database_path = path.join("opencode.db");
    let connection = Connection::open(&database_path).expect("open SQLite fixture");
    connection
        .execute_batch(
            "CREATE TABLE message(
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL,
                time_created INTEGER NOT NULL,
                time_updated INTEGER NOT NULL,
                data TEXT NOT NULL
            )",
        )
        .expect("create OpenCode schema");
    let insert = "INSERT INTO message(id, session_id, time_created, time_updated, data)
                  VALUES (?1, 'session', ?2, ?2, ?3)";
    let timestamp = epoch_millis("2026-08-02T10:00:00Z");
    // Registered provider ids resolve a channel; an unregistered gateway spelling
    // of the same vendor stays unknown because the collector never reads the model.
    for (index, (provider, model)) in [
        ("kimi-for-coding", "k2p5"),
        ("moonshotai", "kimi-k2"),
        ("deepseek", "deepseek-v4-flash"),
        ("kimi-for-coding-oauth", "kimi-for-coding"),
    ]
    .into_iter()
    .enumerate()
    {
        let occurred = timestamp + index as i64 * 60_000;
        let message = json!({
            "role": "assistant",
            "modelID": model,
            "providerID": provider,
            "time": {"created": occurred, "completed": occurred},
            "tokens": {"input": 100, "output": 20, "reasoning": 0, "cache": {"read": 0, "write": 0}},
            "cost": 0
        });
        connection
            .execute(
                insert,
                params![format!("message-{index}"), occurred, message.to_string()],
            )
            .expect("insert OpenCode usage");
    }
    connection.close().expect("close SQLite fixture");

    let result = scan_opencode_usage(&options(&path)).expect("scan OpenCode SQLite");
    assert_eq!(result.coverage.status, CoverageStatus::Complete);
    let resolved: Vec<(&str, BillingChannel, ChannelSource)> = result
        .records
        .iter()
        .map(|record| {
            (
                record.event.model.as_str(),
                record.event.billing_channel,
                record.event.channel_source,
            )
        })
        .collect();
    assert_eq!(
        resolved,
        vec![
            (
                "k2p5",
                BillingChannel::MoonshotDirect,
                ChannelSource::Explicit
            ),
            (
                "kimi-k2",
                BillingChannel::MoonshotDirect,
                ChannelSource::Explicit
            ),
            (
                "deepseek-v4-flash",
                BillingChannel::DeepseekDirect,
                ChannelSource::Explicit
            ),
            (
                "kimi-for-coding",
                BillingChannel::Unknown,
                ChannelSource::Unknown
            ),
        ]
    );

    // A source already indexed under the revision that produced the unknown channel must be
    // re-derived, not skipped, so history reclassifies instead of only new rows.
    let indexed = |revision: &str| -> HashMap<String, UsageFileIndex> {
        result
            .sources
            .iter()
            .map(|source| {
                (
                    source.source.source_file_id.clone(),
                    UsageFileIndex {
                        parser_revision: revision.to_owned(),
                        ..source.index.clone()
                    },
                )
            })
            .collect()
    };
    let current = scan_opencode_usage(&UsageScanOptions {
        file_index: indexed(DEFAULT_PARSER_REVISION),
        ..options(&path)
    })
    .expect("scan at the current revision");
    assert_eq!(current.skipped_source_count, 1);
    assert!(current.records.is_empty());

    let stale = scan_opencode_usage(&UsageScanOptions {
        file_index: indexed("usage-rust-v5"),
        ..options(&path)
    })
    .expect("scan at a stale revision");
    assert_eq!(stale.skipped_source_count, 0);
    assert_eq!(
        stale
            .records
            .iter()
            .map(|record| record.event.billing_channel)
            .collect::<Vec<_>>(),
        vec![
            BillingChannel::MoonshotDirect,
            BillingChannel::MoonshotDirect,
            BillingChannel::DeepseekDirect,
            BillingChannel::Unknown,
        ]
    );
    let _ = fs::remove_dir_all(path);
}

#[test]
fn cursor_transcripts_without_usage_are_complete_and_empty() {
    let path = root("cursor-empty-jsonl");
    fs::write(
        path.join("session.jsonl"),
        r#"{"role":"user","message":{"content":[{"type":"text","text":"hello"}]}}
{"role":"assistant","message":{"content":[{"type":"text","text":"world"}]}}
"#,
    )
    .expect("write Cursor transcript");
    let result = scan_cursor_usage(&options(&path)).expect("scan Cursor transcript");
    assert_eq!(result.coverage.status, CoverageStatus::Complete);
    assert!(result.records.is_empty());
    let _ = fs::remove_dir_all(path);
}

#[test]
fn cursor_preserves_unknown_model_when_usage_is_nonempty() {
    let path = root("cursor-unknown-model");
    fs::write(
        path.join("session.jsonl"),
        r#"{"role":"assistant","createdAt":"2026-08-02T10:00:00Z","model":"unknown","tokenCount":{"inputTokens":25,"outputTokens":5}}
"#,
    )
    .expect("write Cursor usage");
    let result = scan_cursor_usage(&options(&path)).expect("scan Cursor usage");
    assert_eq!(result.coverage.status, CoverageStatus::Complete);
    assert_eq!(result.records.len(), 1);
    assert_eq!(result.records[0].event.model, "unknown");
    assert_eq!(result.records[0].event.input_tokens, 25);
    assert_eq!(result.records[0].event.output_tokens, 5);
    let _ = fs::remove_dir_all(path);
}

#[test]
fn cursor_sqlite_pairs_bubble_tokens_and_ignores_context_meters() {
    let path = root("cursor-sqlite");
    let database_path = path.join("state.vscdb");
    let connection = Connection::open(&database_path).expect("open Cursor SQLite");
    connection
        .execute_batch("CREATE TABLE cursorDiskKV (key TEXT PRIMARY KEY, value BLOB)")
        .expect("create Cursor schema");
    let composer = "aaaa1111-2222-3333-4444-555566667777";
    let insert = "INSERT INTO cursorDiskKV(key, value) VALUES (?1, ?2)";
    connection
        .execute(
            insert,
            params![
                format!("composerData:{composer}"),
                json!({
                    "promptTokenBreakdown": { "totalUsedTokens": 80_000 },
                    "contextTokensUsed": 42_000,
                    "createdAt": epoch_millis("2026-08-02T09:00:00Z")
                })
                .to_string()
            ],
        )
        .expect("insert composer snapshot");
    connection
        .execute(
            insert,
            params![
                format!("bubbleId:{composer}:user-1"),
                json!({
                    "type": 1,
                    "createdAt": "2026-08-02T10:00:00Z",
                    "tokenCount": { "inputTokens": 6_000, "outputTokens": 0 },
                    "text": "prompt that must not be estimated"
                })
                .to_string()
            ],
        )
        .expect("insert user bubble");
    connection
        .execute(
            insert,
            params![
                format!("bubbleId:{composer}:asst-1"),
                json!({
                    "type": 2,
                    "createdAt": "2026-08-02T10:00:01Z",
                    "tokenCount": { "inputTokens": 0, "outputTokens": 900 },
                    "modelInfo": { "modelName": "gpt-5" }
                })
                .to_string()
            ],
        )
        .expect("insert assistant bubble");
    connection
        .execute(
            insert,
            params![
                format!("bubbleId:{composer}:empty-1"),
                json!({
                    "type": 2,
                    "createdAt": "2026-08-02T10:00:02Z",
                    "tokenCount": { "inputTokens": 0, "outputTokens": 0 },
                    "modelInfo": { "modelName": "gpt-5" },
                    "text": "zero token reply"
                })
                .to_string()
            ],
        )
        .expect("insert empty assistant");
    connection.close().expect("close Cursor SQLite");

    let result = scan_cursor_usage(&options(&path)).expect("scan Cursor SQLite");
    assert_eq!(result.coverage.status, CoverageStatus::Complete);
    assert_eq!(result.records.len(), 1);
    let event = &result.records[0].event;
    assert_eq!(event.agent, UsageAgent::Cursor);
    assert_eq!(event.model, "gpt-5");
    assert_eq!(event.input_tokens, 6_000);
    assert_eq!(event.output_tokens, 900);
    assert_eq!(event.billing_channel, BillingChannel::Unknown);
    assert!(
        result.records.iter().all(
            |record| record.event.input_tokens != 80_000 && record.event.input_tokens != 42_000
        )
    );
    let _ = fs::remove_dir_all(path);
}

#[test]
fn cursor_store_db_reads_usage_shaped_blobs() {
    let path = root("cursor-store");
    let database_path = path.join("store.db");
    let connection = Connection::open(&database_path).expect("open Cursor store");
    connection
        .execute_batch("CREATE TABLE blobs (id TEXT, data TEXT)")
        .expect("create store schema");
    connection
        .execute(
            "INSERT INTO blobs(id, data) VALUES (?1, ?2)",
            params![
                "asst-1",
                json!({
                    "role": "assistant",
                    "createdAt": "2026-08-02T10:30:00Z",
                    "model": "composer-1.5",
                    "tokenCount": { "inputTokens": 120, "outputTokens": 40 }
                })
                .to_string()
            ],
        )
        .expect("insert store usage");
    connection
        .execute(
            "INSERT INTO blobs(id, data) VALUES (?1, ?2)",
            params![
                "text-only",
                json!({
                    "role": "assistant",
                    "message": { "content": [{ "type": "text", "text": "no usage" }] }
                })
                .to_string()
            ],
        )
        .expect("insert store transcript");
    connection.close().expect("close Cursor store");

    let result = scan_cursor_usage(&options(&path)).expect("scan Cursor store");
    assert_eq!(result.coverage.status, CoverageStatus::Complete);
    assert_eq!(result.records.len(), 1);
    assert_eq!(result.records[0].event.model, "composer-1.5");
    assert_eq!(result.records[0].event.input_tokens, 120);
    assert_eq!(result.records[0].event.output_tokens, 40);
    let _ = fs::remove_dir_all(path);
}

#[test]
fn cursor_default_roots_cover_home_and_desktop_state() {
    let home = root("cursor-home");
    let options = UsageScanOptions {
        home_directory: Some(home.clone()),
        environment: HashMap::new(),
        roots: None,
        start_at: RANGE_START.into(),
        end_at: RANGE_END.into(),
        ..UsageScanOptions::default()
    };
    let roots = super::scan::roots_for(UsageAgent::Cursor, &options);
    assert!(roots.iter().any(|path| path == &home.join(".cursor")));
    assert!(roots.iter().any(|path| path.ends_with("state.vscdb")));
    let _ = fs::remove_dir_all(home);
}

#[test]
fn grok_ticks_are_exact_and_overflow_is_partial() {
    let path = root("grok-ticks");
    let lines = [
        json!({"method":"_x.ai/session/update","timestamp":1785661260_u64,"params":{"update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":1,"outputTokens":1,"totalTokens":2,"cachedReadTokens":0,"cacheCreationTokens":0,"reasoningTokens":0,"modelCalls":1,"costUsdTicks":5000,"modelUsage":{"grok-4.5":{"inputTokens":1,"outputTokens":1,"totalTokens":2,"cachedReadTokens":0,"cacheCreationTokens":0,"reasoningTokens":0,"modelCalls":1,"costUsdTicks":5000}},"numTurns":1}}}}),
        json!({"method":"_x.ai/session/update","timestamp":1785661320_u64,"params":{"update":{"sessionUpdate":"turn_completed","usage":{"inputTokens":1,"outputTokens":1,"totalTokens":2,"cachedReadTokens":0,"cacheCreationTokens":0,"reasoningTokens":0,"modelCalls":1,"costUsdTicks":u64::MAX,"modelUsage":{"grok-4.5":{"inputTokens":1,"outputTokens":1,"totalTokens":2,"cachedReadTokens":0,"cacheCreationTokens":0,"reasoningTokens":0,"modelCalls":1,"costUsdTicks":u64::MAX}},"numTurns":1}}}}),
    ];
    fs::write(
        path.join("updates.jsonl"),
        lines
            .iter()
            .map(serde_json::Value::to_string)
            .collect::<Vec<_>>()
            .join("\n"),
    )
    .expect("write Grok ticks fixture");
    fs::write(path.join("events.jsonl"), fixture("grok")).expect("write ignored old Grok log");
    let result = scan_grok_usage(&options(&path)).expect("scan Grok ticks");
    assert_eq!(result.scanned_source_count, 1);
    assert_eq!(result.records.len(), 1);
    assert_eq!(
        result.records[0].event.source_cost_microusd.as_deref(),
        Some("1")
    );
    assert_eq!(result.coverage.status, CoverageStatus::Partial);
    assert!(
        result
            .coverage
            .reasons
            .iter()
            .any(|reason| { matches!(reason.code, CoverageReasonCode::InvalidUsage) })
    );
    let _ = fs::remove_dir_all(path);
}

#[test]
fn pi_unknown_provider_is_explicit_and_outer_timestamp_is_supported() {
    let path = root("pi-edge");
    let value = json!({
        "type": "message",
        "timestamp": "2026-08-02T11:00:00Z",
        "message": {
            "role": "assistant",
            "provider": "custom-provider",
            "model": "custom-model",
            "usage": {
                "input": 10,
                "output": 4,
                "cacheRead": 2,
                "cacheWrite": 1,
                "reasoning": 2,
                "cost": {"total": 0.000001}
            }
        }
    });
    let unsafe_timestamp = json!({
        "type": "message",
        "message": {
            "role": "assistant",
            "provider": "anthropic",
            "model": "claude-sonnet-4-6",
            "timestamp": super::MAX_SAFE_COUNT + 1,
            "usage": {"input": 1, "output": 0, "cacheRead": 0, "cacheWrite": 0}
        }
    });
    fs::write(
        path.join("session.jsonl"),
        format!("{}\n{}", value, unsafe_timestamp),
    )
    .expect("write Pi fixture");
    let result = scan_pi_usage(&options(&path)).expect("scan Pi edge");
    assert_eq!(result.records.len(), 1);
    let event = &result.records[0].event;
    assert_eq!(event.occurred_at, "2026-08-02T11:00:00.000Z");
    assert_eq!(event.billing_channel, BillingChannel::Unknown);
    assert_eq!(event.channel_source, super::ChannelSource::Unknown);
    assert_eq!(event.input_tokens, 13);
    assert_eq!(event.reasoning_tokens, 2);
    assert_eq!(event.source_cost_microusd.as_deref(), Some("1"));
    assert_eq!(result.coverage.status, CoverageStatus::Partial);
    assert!(
        result
            .coverage
            .reasons
            .iter()
            .any(|reason| reason.code == CoverageReasonCode::InvalidTimestamp)
    );
    let _ = fs::remove_dir_all(path);
}

#[test]
fn aggregation_preserves_fractional_offsets_and_dst_fallback_hours() {
    let fractional = aggregate_usage_events(
        &[
            test_event("2026-08-02T00:10:00Z", "gpt-5", 100),
            test_event("2026-08-02T00:20:00Z", "gpt-5", 200),
        ],
        "Asia/Kathmandu",
    )
    .expect("fractional-offset aggregation");
    assert_eq!(fractional.len(), 2);
    assert!(
        fractional
            .iter()
            .all(|row| row.bucket_start_utc == "2026-08-02T00:00:00Z")
    );
    assert_eq!(
        fractional
            .iter()
            .map(|row| row.usage_hour)
            .collect::<Vec<_>>(),
        vec![5, 6]
    );
    assert_eq!(
        fold_usage_facts(&fractional)
            .expect("fractional totals")
            .input_tokens,
        300
    );

    let fallback = aggregate_usage_events(
        &[
            test_event("2026-11-01T08:30:00Z", "gpt-5", 100),
            test_event("2026-11-01T09:30:00Z", "gpt-5", 200),
        ],
        "America/Los_Angeles",
    )
    .expect("DST fallback aggregation");
    assert_eq!(fallback.len(), 2);
    assert!(
        fallback
            .iter()
            .all(|row| row.usage_date == "2026-11-01" && row.usage_hour == 1)
    );
    assert_eq!(
        fallback
            .iter()
            .map(|row| row.bucket_start_utc.as_str())
            .collect::<Vec<_>>(),
        vec!["2026-11-01T08:00:00Z", "2026-11-01T09:00:00Z"]
    );
}

#[test]
fn aggregation_merges_dimensions_and_conserves_source_cost_subsets() {
    let mut first = test_event("2026-08-02T00:01:00Z", "gpt-5", 1_000);
    first.cache_read_tokens = 100;
    first.output_tokens = 200;
    first.reasoning_tokens = 50;
    first.source_cost_microusd = Some("123".into());
    first.source_cost_covered_requests = 1;
    let mut second = test_event("2026-08-02T00:02:00Z", "gpt-5", 2_000);
    second.cache_write_5m_tokens = 500;
    second.output_tokens = 300;
    second.reasoning_tokens = 75;
    second.source_cost_microusd = Some("456".into());
    second.source_cost_covered_requests = 1;

    let rows = aggregate_usage_events(&[first, second], "UTC").expect("merged aggregation");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].input_tokens, 3_000);
    assert_eq!(rows[0].cache_read_tokens, 100);
    assert_eq!(rows[0].cache_write_5m_tokens, 500);
    assert_eq!(rows[0].output_tokens, 500);
    assert_eq!(rows[0].reasoning_tokens, 125);
    assert_eq!(rows[0].requests, 2);
    assert_eq!(rows[0].source_cost_microusd.as_deref(), Some("579"));
    assert_eq!(rows[0].source_cost_covered_requests, 2);
    let totals = fold_usage_facts(&rows).expect("merged totals");
    assert_eq!(totals.input_tokens, 3_000);
    assert_eq!(totals.output_tokens, 500);
    assert_eq!(totals.source_cost_microusd.as_deref(), Some("579"));
}

#[test]
fn aggregation_rejects_invalid_ranges_subsets_timezones_and_safe_integer_overflow() {
    assert!(aggregate_usage_events(&[test_event("2026-08-02", "gpt-5", 0)], "UTC").is_err());
    assert!(
        aggregate_usage_events(
            &[test_event("2026-08-02T00:01:00Z", "gpt-5", 0)],
            "Mars/Olympus_Mons"
        )
        .is_err()
    );
    let mut invalid_subset = test_event("2026-08-02T00:01:00Z", "gpt-5", 1);
    invalid_subset.cache_read_tokens = 2;
    assert!(aggregate_usage_events(&[invalid_subset], "UTC").is_err());

    let mut first = test_event("2026-08-02T00:01:00Z", "gpt-5", super::MAX_SAFE_COUNT);
    let second = test_event("2026-08-02T00:02:00Z", "gpt-5", 1);
    first.requests = 1;
    assert!(aggregate_usage_events(&[first, second], "UTC").is_err());
}

#[test]
fn usage_internal_rows_and_models_preserve_limits_semantics() {
    let models = (0..=64)
        .map(|index| test_event("2026-08-02T00:01:00Z", &format!("gpt-{index}"), 0))
        .collect::<Vec<_>>();
    let model_rows = aggregate_usage_events(&models, "UTC").expect("internal model aggregation");
    assert_eq!(model_rows.len(), 65);
    assert_eq!(
        fold_usage_facts(&model_rows)
            .expect("internal model totals")
            .requests,
        65
    );

    let rows = (0..=MAX_USAGE_ROWS)
        .map(|index| {
            let mut event = test_event("2026-08-02T00:01:00Z", "gpt-5", 0);
            event.speed = format!("speed{index}");
            event
        })
        .collect::<Vec<_>>();
    let internal_rows = aggregate_usage_events(&rows, "UTC").expect("internal row aggregation");
    assert_eq!(internal_rows.len(), MAX_USAGE_ROWS + 1);
    let internal_totals = fold_usage_facts(&internal_rows).expect("internal row totals");
    assert_eq!(internal_totals.requests, (MAX_USAGE_ROWS + 1) as u64);
}

#[test]
fn scan_accepts_long_retention_ranges_and_marks_oversized_jsonl_partial() {
    let path = root("scan-limits");
    let mut range = options(&path);
    range.start_at = "2026-08-01T00:00:00Z".into();
    range.end_at = "2026-09-02T00:00:00Z".into();
    assert!(scan_codex_usage(&range).is_ok());

    let oversized = format!(
        "{{\"type\":\"future_record\",\"payload\":\"{}\"}}\n",
        "x".repeat(MAX_JSONL_LINE_BYTES)
    );
    fs::write(path.join("rollout-oversized.jsonl"), oversized).expect("write oversized line");
    let result = scan_codex_usage(&options(&path)).expect("scan oversized line");
    assert!(result.records.is_empty());
    assert_eq!(result.coverage.status, CoverageStatus::Partial);
    assert!(
        result
            .coverage
            .reasons
            .iter()
            .any(|reason| reason.code == CoverageReasonCode::LineTooLarge)
    );
    let _ = fs::remove_dir_all(path);
}

#[test]
fn pricing_wildcard_resolution_selects_specific_entry() {
    let mut fallback = pricing_entry("fallback");
    fallback.service_tier = "*".into();
    fallback.speed = "*".into();
    fallback.inference_geo = "*".into();
    fallback.context_bucket = "*".into();
    fallback.rates.uncached_input_per_million = Some("1".into());
    let mut exact = pricing_entry("exact");
    exact.rates.uncached_input_per_million = Some("2".into());
    let wildcard_catalog = pricing_catalog(vec![fallback.clone(), exact]);
    assert!(validate_pricing_catalog_value(&wildcard_catalog));
    let calculated = calculate_usage_cost(
        &[test_fact_with_input("2026-08-02T12:00:00Z", "gpt-5", 1)],
        Some(&wildcard_catalog),
        UsageCostMode::Calculate,
    )
    .expect("wildcard calculation");
    assert_eq!(calculated.amount_microusd.as_deref(), Some("2"));

    let wildcard_only = pricing_catalog(vec![fallback]);
    let wildcard_cost = calculate_usage_cost(
        &[test_fact_with_input("2026-08-02T12:00:00Z", "gpt-5", 1)],
        Some(&wildcard_only),
        UsageCostMode::Calculate,
    )
    .expect("wildcard fallback calculation");
    assert_eq!(
        wildcard_cost.assumptions,
        vec![
            UsageCostAssumption::AgentDefaultChannel,
            UsageCostAssumption::WildcardContextBucket,
            UsageCostAssumption::WildcardInferenceGeo,
            UsageCostAssumption::WildcardServiceTier,
            UsageCostAssumption::WildcardSpeed,
        ]
    );
}

#[test]
fn pricing_validation_rejects_malformed_entries() {
    let mut malformed_entry = pricing_entry("malformed");
    malformed_entry.source_url = "https://".into();
    malformed_entry.rates.uncached_input_per_million = Some("01".into());
    assert!(!validate_pricing_catalog_value(&pricing_catalog(vec![
        malformed_entry
    ])));
}

#[test]
fn pricing_never_crosses_billing_channels() {
    let channels = [
        BillingChannel::OpenaiDirect,
        BillingChannel::AzureOpenai,
        BillingChannel::AnthropicDirect,
        BillingChannel::AwsBedrock,
        BillingChannel::GoogleVertex,
        BillingChannel::Openrouter,
        BillingChannel::XaiDirect,
    ];
    let entries = channels
        .iter()
        .enumerate()
        .map(|(index, channel)| {
            let mut entry = pricing_entry(&format!("channel-{index}"));
            entry.billing_channel = *channel;
            entry.rates.uncached_input_per_million = Some((index + 1).to_string());
            entry
        })
        .collect::<Vec<_>>();
    let catalog = pricing_catalog(entries);
    assert!(validate_pricing_catalog_value(&catalog));
    for (index, channel) in channels.into_iter().enumerate() {
        let mut row = test_fact_with_input("2026-08-02T12:00:00Z", "gpt-5", 1);
        row.billing_channel = channel;
        row.channel_source = if channel == BillingChannel::OpenaiDirect {
            super::ChannelSource::AgentDefault
        } else {
            super::ChannelSource::Explicit
        };
        let cost = calculate_usage_cost(&[row], Some(&catalog), UsageCostMode::Calculate)
            .expect("channel pricing");
        let expected = (index + 1).to_string();
        assert_eq!(cost.amount_microusd.as_deref(), Some(expected.as_str()));
    }
}

#[test]
fn usage_wire_enums_preserve_protocol_values() {
    for agent in UsageAgent::ALL {
        let encoded = serde_json::to_string(&agent).expect("serialize agent");
        assert_eq!(encoded, format!("\"{}\"", agent.as_str()));
        assert_eq!(
            serde_json::from_str::<UsageAgent>(&encoded).expect("deserialize agent"),
            agent
        );
    }
    for bucket in [
        ContextBucket::Le128k,
        ContextBucket::Gt128kLe200k,
        ContextBucket::Gt200kLe256k,
        ContextBucket::Gt256kLe272k,
        ContextBucket::Gt272k,
    ] {
        let encoded = serde_json::to_string(&bucket).expect("serialize context bucket");
        assert_eq!(encoded, format!("\"{}\"", bucket.as_str()));
        assert_eq!(
            serde_json::from_str::<ContextBucket>(&encoded).expect("deserialize context bucket"),
            bucket
        );
    }
}

#[test]
fn pricing_uses_exact_half_up_rates_for_cache_output_and_tools() {
    let mut entry = pricing_entry("cache-tools");
    entry.rates = PricingRates {
        uncached_input_per_million: Some("1.25".into()),
        cache_read_per_million: Some("0.125".into()),
        cache_write_5m_per_million: Some("2".into()),
        cache_write_1h_per_million: Some("4".into()),
        cache_write_inferred_per_million: Some("3".into()),
        output_per_million: Some("10".into()),
        web_search_per_request: Some("0.01".into()),
        web_fetch_per_request: Some("0.0025".into()),
    };
    let catalog = pricing_catalog(vec![entry]);
    let mut row = test_fact_with_input("2026-08-02T12:00:00Z", "gpt-5", 1_000);
    row.cache_read_tokens = 100;
    row.cache_write_5m_tokens = 50;
    row.cache_write_1h_tokens = 25;
    row.cache_write_inferred_tokens = 25;
    row.output_tokens = 200;
    row.reasoning_tokens = 150;
    row.web_search_requests = 1;
    row.web_fetch_requests = 2;
    match calculate_usage_row_cost(&catalog, &row).expect("cache/tools pricing") {
        CalculatedUsageRowCost::Priced {
            amount_microusd,
            assumptions,
            entry_id,
        } => {
            assert_eq!(amount_microusd, BigUint::from(18_288u32));
            assert_eq!(entry_id, "cache-tools");
            assert_eq!(
                assumptions,
                vec![UsageCostAssumption::CacheWriteInferredRate]
            );
        }
        CalculatedUsageRowCost::Unpriced(reason) => {
            panic!("unexpected unpriced result: {reason:?}")
        }
    }

    let mut half = pricing_entry("half");
    half.rates = PricingRates {
        uncached_input_per_million: Some("0.5".into()),
        cache_read_per_million: None,
        cache_write_5m_per_million: None,
        cache_write_1h_per_million: None,
        cache_write_inferred_per_million: None,
        output_per_million: None,
        web_search_per_request: None,
        web_fetch_per_request: None,
    };
    let half_cost = calculate_usage_cost(
        &[
            test_fact_with_input("2026-08-02T12:00:00Z", "gpt-5", 1),
            test_fact_with_input("2026-08-02T13:00:00Z", "gpt-5", 1),
        ],
        Some(&pricing_catalog(vec![half])),
        UsageCostMode::Calculate,
    )
    .expect("half-up pricing");
    assert_eq!(half_cost.amount_microusd.as_deref(), Some("2"));
}

#[test]
fn pricing_keeps_large_counts_exact_and_reports_unpriced_reasons() {
    let mut exact = pricing_entry("exact-large");
    exact.rates.uncached_input_per_million = Some("1".into());
    let exact_cost = calculate_usage_cost(
        &[test_fact_with_input(
            "2026-08-02T12:00:00Z",
            "gpt-5",
            super::MAX_SAFE_COUNT,
        )],
        Some(&pricing_catalog(vec![exact.clone()])),
        UsageCostMode::Calculate,
    )
    .expect("large integer pricing");
    assert_eq!(
        exact_cost.amount_microusd.as_deref(),
        Some("9007199254740991")
    );

    let unknown = calculate_usage_cost(
        &[test_fact_with_input(
            "2026-08-02T12:00:00Z",
            "unknown-model",
            0,
        )],
        Some(&pricing_catalog(vec![exact.clone()])),
        UsageCostMode::Calculate,
    )
    .expect("unknown model pricing");
    assert_eq!(unknown.status, UsageCostStatus::Unavailable);
    assert_eq!(unknown.amount_microusd, None);
    assert_eq!(unknown.unpriced_rows, 1);
    assert_eq!(
        unknown.unpriced[0].reason,
        UsageUnpricedReason::UnknownModel
    );

    let mut inferred = test_fact_with_input("2026-08-02T12:00:00Z", "gpt-5", 1);
    inferred.cache_write_inferred_tokens = 1;
    let missing = calculate_usage_cost(
        &[inferred],
        Some(&pricing_catalog(vec![exact])),
        UsageCostMode::Calculate,
    )
    .expect("missing rate pricing");
    assert_eq!(missing.status, UsageCostStatus::Unavailable);
    assert_eq!(missing.unpriced[0].reason, UsageUnpricedReason::MissingRate);
}

#[test]
fn pricing_caps_unpriced_detail_without_losing_rows_or_status() {
    let rows = (0..101)
        .map(|index| {
            test_fact_with_input("2026-08-02T12:00:00Z", &format!("opaque-model-{index}"), 1)
        })
        .collect::<Vec<_>>();
    let outcome = calculate_usage_cost(
        &rows,
        Some(&pricing_catalog(Vec::new())),
        UsageCostMode::Calculate,
    )
    .expect("unpriced detail is bounded");
    assert_eq!(outcome.unpriced_rows, 101);
    assert_eq!(outcome.unpriced.len(), 100);
    assert!(outcome.unpriced_truncated);
    assert_eq!(outcome.status, UsageCostStatus::Unavailable);
}

#[test]
fn local_summary_caps_model_detail_without_failing_totals() {
    let rows = (0..=MAX_USAGE_MODELS)
        .map(|index| test_fact_with_input("2026-08-02T12:00:00Z", &format!("model-{index}"), 1))
        .collect::<Vec<_>>();
    let summary = build_local_usage_summary(&rows, None, None).expect("bounded models");
    assert_eq!(
        summary.clients[0].providers[0].models.len(),
        MAX_USAGE_MODELS
    );
    assert!(summary.models_truncated);
    assert_eq!(summary.totals.messages, (MAX_USAGE_MODELS + 1) as u64);
}

#[test]
fn model_key_collision_keeps_canonical_and_raw_groups_separate() {
    let catalog = serde_json::from_value::<crate::model_catalog::ModelCatalog>(json!({
        "schema_version": 1,
        "revision": "test-1",
        "models": [{
            "canonical_id": "gpt-5.5",
            "aliases": [{"reported_model":"gpt-5.5-alias","provider":"openai"}]
        }]
    }))
    .expect("model catalog");
    let rows = vec![
        test_fact("2026-08-02T12:00:00Z", "gpt-5.5"),
        test_fact("2026-08-02T13:00:00Z", "GPT-5.5"),
    ];
    let summary = build_local_usage_summary(&rows, None, Some(&catalog)).expect("summary");
    let models = &summary.clients[0].providers[0].models;
    assert!(!summary.models_truncated);
    assert_eq!(models.len(), 2);
    assert_eq!(
        models.iter().map(|item| item.totals.messages).sum::<u64>(),
        2
    );
    assert_eq!(
        models
            .iter()
            .map(|item| item.model.as_str())
            .collect::<Vec<_>>(),
        vec!["gpt-5.5", "GPT-5.5"]
    );
}

#[test]
fn model_catalog_revision_regroups_retained_rows_without_rewriting_them() {
    let mut catalog = serde_json::from_value::<crate::model_catalog::ModelCatalog>(json!({
        "schema_version": 1,
        "revision": "test-before",
        "models": [{
            "canonical_id": "gpt-5.5",
            "aliases": [{"reported_model":"gpt-5.5-alias","provider":"openai"}]
        }]
    }))
    .expect("model catalog");
    let rows = vec![test_fact("2026-08-02T12:00:00Z", "GPT-5.5[1m]")];
    let summarize = |catalog: &crate::model_catalog::ModelCatalog| {
        build_local_usage_summary(&rows, None, Some(catalog))
            .expect("summary")
            .clients
            .into_iter()
            .next()
            .and_then(|client| client.providers.into_iter().next())
            .and_then(|provider| provider.models.into_iter().next())
            .expect("model group")
    };

    let before = summarize(&catalog);
    catalog.revision = "test-after".into();
    catalog.models[0].aliases.push(
        serde_json::from_value(json!({
            "reported_model": "GPT-5.5[1m]",
            "provider": "openai",
            "client": "codex",
            "effective_from": "2026-04-24"
        }))
        .expect("alias"),
    );
    let after = summarize(&catalog);

    assert_eq!(before.model, "GPT-5.5[1m]");
    assert_eq!(after.model, "gpt-5.5");
    assert_eq!(after.totals, before.totals);
    assert_eq!(after.cost, before.cost);
    assert_eq!(rows[0].model, "GPT-5.5[1m]");
}

#[test]
fn local_summary_groups_client_provider_model_and_counts_output_messages() {
    let mut codex = test_fact("2026-08-02T12:00:00Z", "gpt-5.5");
    codex.input_tokens = 100;
    codex.cache_read_tokens = 20;
    codex.cache_write_5m_tokens = 10;
    codex.output_tokens = 40;
    codex.reasoning_tokens = 15;
    codex.requests = 2;
    let mut anthropic = test_fact("2026-08-02T13:00:00Z", "gpt-5.5");
    anthropic.agent = UsageAgent::Codex;
    anthropic.billing_channel = BillingChannel::AnthropicDirect;
    anthropic.input_tokens = 50;
    anthropic.cache_write_inferred_tokens = 5;
    anthropic.output_tokens = 10;
    anthropic.requests = 1;

    let summary = build_local_usage_summary(&[codex, anthropic], None, None).expect("summary");

    assert_eq!(summary.totals.total_tokens, 200);
    assert_eq!(summary.totals.input_tokens, 150);
    assert_eq!(summary.totals.output_tokens, 50);
    assert_eq!(summary.totals.cache_read_input_tokens, 20);
    assert_eq!(summary.totals.cache_write_input_tokens, 15);
    assert_eq!(summary.totals.reasoning_tokens, 15);
    assert_eq!(summary.totals.messages, 3);
    assert_eq!(summary.clients.len(), 1);
    assert_eq!(summary.clients[0].client, UsageAgent::Codex);
    assert_eq!(summary.clients[0].providers.len(), 2);
    assert_eq!(
        summary.clients[0].providers[0].provider,
        InferenceProvider::Openai
    );
    assert_eq!(summary.clients[0].providers[0].models[0].model, "gpt-5.5");
    assert_eq!(
        summary.clients[0].providers[1].provider,
        InferenceProvider::Anthropic
    );
    assert_eq!(summary.clients[0].providers[1].models[0].model, "gpt-5.5");
}

#[test]
fn local_summary_uses_complete_source_cost_when_catalog_cannot_price_a_model() {
    let mut grok = test_fact("2026-08-02T12:00:00Z", "grok-4.5-build");
    grok.agent = UsageAgent::Grok;
    grok.billing_channel = BillingChannel::XaiDirect;
    grok.input_tokens = 100;
    grok.output_tokens = 20;
    grok.requests = 3;
    grok.source_cost_microusd = Some("12699".into());
    grok.source_cost_covered_requests = 3;
    let catalog = pricing_catalog(Vec::new());

    let summary = build_local_usage_summary(&[grok], Some(&catalog), None).expect("summary");

    assert_eq!(summary.cost.mode, UsageCostMode::Auto);
    assert_eq!(summary.cost.basis, UsageCostBasis::Reported);
    assert_eq!(summary.cost.status, UsageCostStatus::Complete);
    assert_eq!(summary.cost.amount_microusd.as_deref(), Some("12699"));
    assert_eq!(
        summary.clients[0].providers[0].models[0]
            .cost
            .amount_microusd
            .as_deref(),
        Some("12699")
    );
}

#[test]
fn protocol_amount_and_source_cost_bounds_fail_explicitly_instead_of_truncating() {
    let no_cost_wire = serde_json::to_value(test_fact("2026-08-02T12:00:00Z", "gpt-5"))
        .expect("serialize no-cost hourly fact");
    assert!(no_cost_wire.get("source_cost_microusd").is_none());
    let mut cost_fact = test_fact("2026-08-02T12:00:00Z", "gpt-5");
    cost_fact.source_cost_microusd = Some("123".into());
    cost_fact.source_cost_covered_requests = 1;
    let cost_wire = serde_json::to_value(cost_fact).expect("serialize reported-cost fact");
    assert_eq!(cost_wire["source_cost_microusd"], "123");
    let totals_wire = serde_json::to_value(fold_usage_facts(&[]).expect("empty totals"))
        .expect("serialize nullable totals");
    assert!(
        totals_wire
            .get("source_cost_microusd")
            .is_some_and(Value::is_null)
    );
    let empty_cost =
        calculate_usage_cost(&[], None, UsageCostMode::Calculate).expect("empty cost outcome");
    let cost_outcome_wire = serde_json::to_value(empty_cost).expect("serialize nullable cost");
    assert!(
        cost_outcome_wire
            .get("amount_microusd")
            .is_some_and(Value::is_null)
    );
    assert!(
        cost_outcome_wire
            .get("catalog_revision")
            .is_some_and(Value::is_null)
    );
    let rates_wire = serde_json::to_value(pricing_rates()).expect("serialize nullable rates");
    assert!(
        rates_wire
            .get("cache_write_inferred_per_million")
            .is_some_and(Value::is_null)
    );
    let entry_wire = serde_json::to_value(pricing_entry("wire-shape"))
        .expect("serialize nullable pricing entry");
    assert!(entry_wire.get("effective_to").is_some_and(Value::is_null));

    let mut noncanonical = test_fact("2026-08-02T12:00:00Z", "gpt-5");
    noncanonical.source_cost_microusd = Some("00".into());
    noncanonical.source_cost_covered_requests = 1;
    assert!(fold_usage_facts(&[noncanonical]).is_err());

    let mut source_left = test_fact("2026-08-02T12:00:00Z", "gpt-5");
    source_left.source_cost_microusd = Some("9".repeat(32));
    source_left.source_cost_covered_requests = 1;
    let mut source_right = test_fact("2026-08-02T13:00:00Z", "gpt-5");
    source_right.source_cost_microusd = Some("9".repeat(32));
    source_right.source_cost_covered_requests = 1;
    let source_error = fold_usage_facts(&[source_left, source_right])
        .expect_err("source cost total protocol bound");
    assert!(source_error.0.contains("source cost total"));

    let mut huge = pricing_entry("huge-request-rate");
    huge.rates = PricingRates {
        uncached_input_per_million: None,
        cache_read_per_million: None,
        cache_write_5m_per_million: None,
        cache_write_1h_per_million: None,
        cache_write_inferred_per_million: None,
        output_per_million: None,
        web_search_per_request: Some("99999999999999999999999999999999".into()),
        web_fetch_per_request: None,
    };
    let mut tool_row = test_fact("2026-08-02T12:00:00Z", "gpt-5");
    tool_row.web_search_requests = 1;
    let amount_error = calculate_usage_cost(
        &[tool_row],
        Some(&pricing_catalog(vec![huge])),
        UsageCostMode::Calculate,
    )
    .expect_err("calculated amount protocol bound");
    assert!(amount_error.0.contains("cost amount"));
}

#[test]
fn pricing_source_reported_is_only_used_when_fully_covered_and_requested() {
    let reported = test_fact_with_input("2026-08-02T12:00:00Z", "unknown-model", 0);
    let mut reported = reported;
    reported.source_cost_microusd = Some("1234".into());
    reported.source_cost_covered_requests = 1;
    let empty_catalog = pricing_catalog(Vec::new());

    let calculated = calculate_usage_cost(
        &[reported.clone()],
        Some(&empty_catalog),
        UsageCostMode::Calculate,
    )
    .expect("calculate mode");
    assert_eq!(calculated.status, UsageCostStatus::Unavailable);
    assert_eq!(calculated.amount_microusd, None);

    let auto = calculate_usage_cost(
        &[reported.clone()],
        Some(&empty_catalog),
        UsageCostMode::Auto,
    )
    .expect("auto mode");
    assert_eq!(auto.status, UsageCostStatus::Complete);
    assert_eq!(auto.basis, UsageCostBasis::Reported);
    assert_eq!(auto.amount_microusd.as_deref(), Some("1234"));
    assert!(
        auto.assumptions
            .contains(&UsageCostAssumption::SourceReported)
    );

    let reported_mode = calculate_usage_cost(&[reported.clone()], None, UsageCostMode::Reported)
        .expect("reported mode");
    assert_eq!(reported_mode.status, UsageCostStatus::Complete);
    assert_eq!(reported_mode.catalog_revision, None);
    assert_eq!(reported_mode.amount_microusd.as_deref(), Some("1234"));

    let mut partial = reported;
    partial.requests = 2;
    partial.source_cost_covered_requests = 1;
    let partial_outcome =
        calculate_usage_cost(&[partial], Some(&empty_catalog), UsageCostMode::Auto)
            .expect("partial reported mode");
    assert_eq!(partial_outcome.status, UsageCostStatus::Unavailable);
    assert_eq!(partial_outcome.amount_microusd, None);
    assert_eq!(
        partial_outcome.unpriced[0].reason,
        UsageUnpricedReason::UnknownModel
    );
}

#[test]
fn pricing_prepared_rows_can_be_folded_by_breakdown_without_reresolution() {
    let catalog = pricing_catalog(vec![pricing_entry("priced")]);
    let mut reported = test_fact_with_input("2026-08-02T12:00:00Z", "reported-model", 0);
    reported.source_cost_microusd = Some("1234".into());
    reported.source_cost_covered_requests = 1;
    let rows = vec![
        test_fact_with_input("2026-08-02T12:00:00Z", "gpt-5", 1_000_000),
        reported,
        test_fact_with_input("2026-08-02T12:00:00Z", "unpriced-model", 0),
    ];
    let prepared = crate::pricing::prepare_usage_costs(&rows, Some(&catalog), UsageCostMode::Auto)
        .expect("prepare pricing rows");
    let all =
        crate::pricing::fold_prepared_usage_costs(&prepared, None).expect("fold prepared rows");
    let direct = calculate_usage_cost(&rows, Some(&catalog), UsageCostMode::Auto)
        .expect("direct pricing rows");
    assert_eq!(all, direct);
    let subset = crate::pricing::fold_prepared_usage_costs(&prepared, Some(&[0, 2]))
        .expect("fold pricing subset");
    let direct_subset = calculate_usage_cost(
        &[rows[0].clone(), rows[2].clone()],
        Some(&catalog),
        UsageCostMode::Auto,
    )
    .expect("direct pricing subset");
    assert_eq!(subset, direct_subset);
    assert!(crate::pricing::fold_prepared_usage_costs(&prepared, Some(&[3])).is_err());
}

#[test]
fn malformed_and_truncated_lines_make_coverage_partial_without_exporting_payload() {
    let path = root("partial");
    fs::write(
        path.join("rollout-partial.jsonl"),
        format!("{}\n{{\"type\":\"event_msg\"", fixture("codex")),
    )
    .expect("write partial fixture");
    let result = scan_codex_usage(&options(&path)).expect("scan partial");
    assert_eq!(result.coverage.status, CoverageStatus::Partial);
    assert!(!result.replacement_scan_complete());
    assert!(
        result
            .coverage
            .reasons
            .iter()
            .any(|reason| matches!(reason.code, super::CoverageReasonCode::TruncatedTail))
    );
    let serialized = serde_json::to_string(
        &result
            .records
            .iter()
            .map(|record| &record.event)
            .collect::<Vec<_>>(),
    )
    .expect("serialize normalized events");
    assert!(!serialized.contains("payload"));
    let _ = fs::remove_dir_all(path);
}

#[test]
fn invalid_reason_counts_are_saturated_and_not_limited_to_sample_capacity() {
    let path = root("reason-counts");
    let invalid_model = "m".repeat(129);
    let lines = (0..200)
        .map(|index| {
            json!({
                "timestamp": format!("2026-08-02T00:{:02}:00Z", index % 60),
                "type": "event_msg",
                "payload": {
                    "type": "token_count",
                    "info": {
                        "model": invalid_model,
                        "last_token_usage": {"input_tokens": 1, "output_tokens": 1}
                    }
                }
            })
            .to_string()
        })
        .collect::<Vec<_>>();
    fs::write(
        path.join("rollout-reason-counts.jsonl"),
        format!("{}\n", lines.join("\n")),
    )
    .expect("write invalid records");

    let result = scan_codex_usage(&options(&path)).expect("scan invalid records");
    let count = result
        .coverage
        .reasons
        .iter()
        .find(|reason| reason.code == CoverageReasonCode::InvalidModel)
        .map(|reason| reason.count);
    assert_eq!(count, Some(200));
    assert!(result.records.is_empty());
    let _ = fs::remove_dir_all(path);
}

fn test_event(occurred_at: &str, model: &str, input_tokens: u64) -> NormalizedUsageEvent {
    NormalizedUsageEvent {
        occurred_at: occurred_at.into(),
        agent: UsageAgent::Codex,
        model: model.into(),
        billing_channel: BillingChannel::OpenaiDirect,
        channel_source: super::ChannelSource::AgentDefault,
        input_tokens,
        cache_read_tokens: 0,
        cache_write_5m_tokens: 0,
        cache_write_1h_tokens: 0,
        cache_write_inferred_tokens: 0,
        output_tokens: 0,
        reasoning_tokens: 0,
        requests: 1,
        context_bucket: ContextBucket::Le128k,
        service_tier: "default".into(),
        speed: "standard".into(),
        inference_geo: "global".into(),
        billable_tools: super::BillableTools::default(),
        source_cost_microusd: None,
        source_cost_covered_requests: 0,
    }
}

fn test_fact(bucket_start_utc: &str, model: &str) -> UsageHourlyFact {
    UsageHourlyFact {
        bucket_start_utc: bucket_start_utc.into(),
        usage_date: bucket_start_utc[..10].into(),
        usage_hour: bucket_start_utc[11..13]
            .parse()
            .expect("valid test UTC hour"),
        agent: UsageAgent::Codex,
        billing_channel: BillingChannel::OpenaiDirect,
        channel_source: super::ChannelSource::AgentDefault,
        model: model.into(),
        context_bucket: ContextBucket::Le128k,
        service_tier: "default".into(),
        speed: "standard".into(),
        inference_geo: "global".into(),
        input_tokens: 0,
        cache_read_tokens: 0,
        cache_write_5m_tokens: 0,
        cache_write_1h_tokens: 0,
        cache_write_inferred_tokens: 0,
        output_tokens: 0,
        reasoning_tokens: 0,
        requests: 1,
        web_search_requests: 0,
        web_fetch_requests: 0,
        source_cost_microusd: None,
        source_cost_covered_requests: 0,
    }
}

fn test_fact_with_input(bucket_start_utc: &str, model: &str, input_tokens: u64) -> UsageHourlyFact {
    let mut fact = test_fact(bucket_start_utc, model);
    fact.input_tokens = input_tokens;
    fact
}

fn pricing_rates() -> PricingRates {
    PricingRates {
        uncached_input_per_million: Some("1".into()),
        cache_read_per_million: Some("0.1".into()),
        cache_write_5m_per_million: Some("1.25".into()),
        cache_write_1h_per_million: Some("2".into()),
        cache_write_inferred_per_million: None,
        output_per_million: Some("10".into()),
        web_search_per_request: None,
        web_fetch_per_request: None,
    }
}

fn pricing_entry(entry_id: &str) -> PricingCatalogEntry {
    PricingCatalogEntry {
        entry_id: entry_id.into(),
        billing_channel: BillingChannel::OpenaiDirect,
        model: "gpt-5".into(),
        aliases: Vec::new(),
        effective_from: "2026-01-01".into(),
        effective_to: None,
        service_tier: "default".into(),
        speed: "standard".into(),
        inference_geo: "global".into(),
        context_bucket: "le_128k".into(),
        currency: "USD".into(),
        rates: pricing_rates(),
        source_url: "https://example.com/pricing".into(),
        verified_at: "2026-08-02T00:00:00Z".into(),
    }
}

fn pricing_catalog(entries: Vec<PricingCatalogEntry>) -> PricingCatalog {
    PricingCatalog {
        protocol_version: 2,
        revision: "pricing_fixture_1".into(),
        published_at: "2026-08-02T00:00:00Z".into(),
        entries,
    }
}

fn validate_pricing_catalog_value(catalog: &PricingCatalog) -> bool {
    validate_pricing_catalog(&serde_json::to_value(catalog).expect("serialize test catalog")).valid
}
