//! Whether a local agent is writing its logs right now (ADR 0063).
//!
//! Automatic asks this once a minute, so it is a bounded walk of modification times and never
//! opens a file. The newest subdirectories are walked first, because a new session lands in a
//! new file and a new file touches its directory.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use chrono::{DateTime, Utc};

use crate::usage::{UsageAgent, UsageScanOptions, roots_for};

/// Entries one probe of one agent may look at.
const ENTRY_BUDGET: usize = 5_000;
const MAX_DEPTH: usize = 6;

/// The newest write under `agent`'s log roots, stopping early at one newer than `enough`.
pub fn newest_write(
    agent: UsageAgent,
    home: &Path,
    environment: &HashMap<String, String>,
    enough: DateTime<Utc>,
) -> Option<DateTime<Utc>> {
    let options = UsageScanOptions {
        home_directory: Some(home.to_path_buf()),
        environment: environment.clone(),
        ..UsageScanOptions::default()
    };
    let enough = SystemTime::from(enough);
    let mut budget = ENTRY_BUDGET;
    let mut newest: Option<SystemTime> = None;
    for root in roots_for(agent, &options) {
        walk(&root, 0, enough, &mut budget, &mut newest);
        if newest.is_some_and(|newest| newest >= enough) || budget == 0 {
            break;
        }
    }
    newest.map(DateTime::<Utc>::from)
}

fn walk(
    path: &Path,
    depth: usize,
    enough: SystemTime,
    budget: &mut usize,
    newest: &mut Option<SystemTime>,
) {
    // A root may be a link someone made on purpose; nothing below it is followed.
    let metadata = if depth == 0 {
        fs::metadata(path)
    } else {
        fs::symlink_metadata(path)
    };
    let Ok(metadata) = metadata else {
        return;
    };
    if metadata.is_file() {
        if let Ok(modified) = metadata.modified() {
            *newest = Some(newest.map_or(modified, |newest| newest.max(modified)));
        }
        return;
    }
    if !metadata.is_dir() || depth >= MAX_DEPTH {
        return;
    }
    let Ok(entries) = fs::read_dir(path) else {
        return;
    };
    let mut children: Vec<(SystemTime, PathBuf)> = Vec::new();
    for entry in entries.flatten() {
        if *budget == 0 {
            break;
        }
        *budget -= 1;
        let Ok(metadata) = entry.metadata() else {
            continue;
        };
        let Ok(modified) = metadata.modified() else {
            continue;
        };
        if metadata.is_file() {
            *newest = Some(newest.map_or(modified, |newest| newest.max(modified)));
        } else if metadata.is_dir() {
            children.push((modified, entry.path()));
        }
    }
    if newest.is_some_and(|newest| newest >= enough) {
        return;
    }
    children.sort_by_key(|child| std::cmp::Reverse(child.0));
    for (_, child) in children {
        if *budget == 0 || newest.is_some_and(|newest| newest >= enough) {
            return;
        }
        walk(&child, depth + 1, enough, budget, newest);
    }
}
