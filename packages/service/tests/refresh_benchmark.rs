//! What a refresh costs on a machine with a long Usage history.
//!
//! Ignored by default: it writes roughly 200 MB of Claude-style JSONL to a temporary
//! directory, which is the point — the first scan is allowed to be slow, and the two refreshes
//! after it are what a person waits for.
//!
//! ```sh
//! cargo test --release -p quota-service --test refresh_benchmark -- --ignored --nocapture
//! ```

use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use quota_service::state::StateStore;
use quota_service::usage::{
    DEFAULT_PARSER_REVISION, UsageAgent, UsageScanOptions, scan_local_usage,
};

const FILES: usize = 2_000;
const LINES_PER_FILE: usize = 100;
const BUDGET: Duration = Duration::from_secs(1);

#[test]
#[ignore = "writes ~200 MB of fixture JSONL"]
fn a_refresh_on_a_long_history_costs_what_changed() {
    let root = std::env::temp_dir().join(format!("quota-bench-{}", uuid::Uuid::new_v4()));
    let home = root.join("home");
    let projects = home.join(".claude").join("projects").join("bench");
    fs::create_dir_all(&projects).expect("fixture directory");
    fs::create_dir_all(root.join("state")).expect("state directory");

    let bytes = write_history(&projects);
    println!("fixture: {FILES} files, {} MB", bytes / (1024 * 1024));

    let store = StateStore::open(root.join("state")).expect("state");

    let (first, first_requests) = refresh(&store, &home);
    println!("first full scan:      {first:?}");

    let (unchanged, unchanged_requests) = refresh(&store, &home);
    println!("refresh, no changes:  {unchanged:?}");

    append_one_kibibyte(&projects.join("session-0000.jsonl"));
    let (appended, appended_requests) = refresh(&store, &home);
    println!("refresh, 1 KiB added: {appended:?}");

    drop(store);
    let _ = fs::remove_dir_all(&root);

    // Every record reached the store, and a refresh that reads less still answers for all of it.
    let expected = (FILES * LINES_PER_FILE) as u64;
    assert_eq!(first_requests, expected);
    assert_eq!(unchanged_requests, expected);
    assert_eq!(appended_requests, expected + 1);
    assert!(unchanged < BUDGET, "unchanged refresh took {unchanged:?}");
    assert!(appended < BUDGET, "appended refresh took {appended:?}");
}

/// One refresh, as the service performs it: scan the agent's sources, apply what changed, and
/// fold the four periods a reader asks for.
fn refresh(store: &StateStore, home: &Path) -> (Duration, u64) {
    let started = Instant::now();
    let file_index = store
        .usage_file_index(UsageAgent::ClaudeCode)
        .expect("file index");
    let options = UsageScanOptions {
        home_directory: Some(home.to_path_buf()),
        environment: HashMap::new(),
        roots: None,
        start_at: "2020-01-01T00:00:00Z".into(),
        end_at: "2030-01-01T00:00:00Z".into(),
        cancelled: None,
        parser_revision: DEFAULT_PARSER_REVISION.into(),
        file_index,
    };
    let scan = scan_local_usage(UsageAgent::ClaudeCode, &options).expect("scan");
    let scan_version = store.next_usage_scan_version().expect("scan version");
    store
        .apply_usage_scan(UsageAgent::ClaudeCode, &scan, scan_version)
        .expect("apply");
    let mut requests = 0u64;
    for range in [
        Some(("2026-08-02", "2026-08-02")),
        Some(("2026-07-27", "2026-08-02")),
        Some(("2026-07-04", "2026-08-02")),
        None,
    ] {
        let (rows, _) = store.usage_period_rows(range).expect("period");
        requests = rows.iter().map(|row| row.requests).sum();
    }
    (started.elapsed(), requests)
}

fn write_history(projects: &Path) -> u64 {
    let mut bytes = 0u64;
    for file in 0..FILES {
        let path = projects.join(format!("session-{file:04}.jsonl"));
        let mut out = std::io::BufWriter::new(fs::File::create(&path).expect("fixture file"));
        for line in 0..LINES_PER_FILE {
            let record = record(file, line);
            bytes += record.len() as u64 + 1;
            writeln!(out, "{record}").expect("write record");
        }
        out.flush().expect("flush");
    }
    bytes
}

/// A Claude-style assistant record, padded to roughly a kilobyte the way a real transcript
/// line is: the text around the usage block is most of the bytes.
fn record(file: usize, line: usize) -> String {
    let hour = line % 24;
    let day = 2 + (file % 28);
    let text = "the quick brown fox jumps over the lazy dog. ".repeat(20);
    format!(
        r#"{{"timestamp":"2026-08-{day:02}T{hour:02}:{minute:02}:00.000Z","type":"assistant","message":{{"role":"assistant","model":"claude-sonnet-4-{model}","content":[{{"type":"text","text":"{text}"}}],"usage":{{"input_tokens":{input},"output_tokens":{output},"cache_creation_input_tokens":25,"cache_read_input_tokens":10}}}}}}"#,
        minute = line % 60,
        model = file % 3,
        input = 100 + line,
        output = 50 + line,
    )
}

fn append_one_kibibyte(path: &PathBuf) {
    let mut file = fs::OpenOptions::new()
        .append(true)
        .open(path)
        .expect("append");
    let record = record(0, LINES_PER_FILE + 1);
    writeln!(file, "{record}").expect("append record");
}
