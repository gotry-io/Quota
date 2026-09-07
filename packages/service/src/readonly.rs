//! Reading this Mac's last valid state without taking it over.
//!
//! `StateStore` is the service's own handle: it takes the owner lock, migrates both images,
//! and finishes work an earlier run left behind. A reader that only wants to print what is
//! already there must do none of that, so this opens `cache.sqlite` read-only, runs no
//! migration, and never touches `identity.sqlite`, which is where credentials live
//! ([ADR 0046](../../../docs/decisions/0046-a-read-only-quota-command.md)).

use std::path::{Path, PathBuf};

use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde_json::Value;

use crate::protocol::{QuotaOverviewItem, UsagePeriod};

const CACHE_NAME: &str = "cache.sqlite";

/// Why this Mac's state could not be read. There is one sentence per case and no path in it.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReadOnlyStateError {
    /// No state root, or no cache image inside it: QuotaBar has never run here.
    Missing,
    /// The image is there but this process cannot read it as it stands.
    Unreadable,
}

impl ReadOnlyStateError {
    pub const fn message(self) -> &'static str {
        match self {
            Self::Missing => "QuotaBar has no local state on this Mac yet. Open QuotaBar once.",
            Self::Unreadable => "QuotaBar's local state could not be read. Open QuotaBar.",
        }
    }
}

/// One read-only view of the disposable half of local state.
pub struct ReadOnlyState {
    connection: Connection,
}

impl ReadOnlyState {
    /// Opens the cache image under this state root, or says why it could not be read.
    ///
    /// `SQLITE_OPEN_READ_ONLY` is what makes this safe to run beside a live QuotaBar: the
    /// service keeps its own write connection, and nothing here can take the lock away from
    /// it, rebuild the image, or start a refresh.
    pub fn open(root: impl AsRef<Path>) -> Result<Self, ReadOnlyStateError> {
        // `SQLITE_OPEN_NOFOLLOW` rejects a symlink in any ancestor too, and macOS puts one in
        // several ordinary paths (`/var` -> `/private/var`), so the ancestors are resolved once
        // here and the filename itself stays protected by the flag.
        let root = std::fs::canonicalize(root.as_ref()).map_err(|_| ReadOnlyStateError::Missing)?;
        let path: PathBuf = root.join(CACHE_NAME);
        if !path.is_file() {
            return Err(ReadOnlyStateError::Missing);
        }
        let connection = Connection::open_with_flags(
            &path,
            OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )
        .map_err(|_| ReadOnlyStateError::Unreadable)?;
        // A read that cannot name the tables it wants is a cache this build does not know how
        // to read, which is the same answer to the caller as one SQLite refused.
        connection
            .query_row(
                "SELECT value FROM metadata WHERE key = 'revision'",
                [],
                |_| Ok(()),
            )
            .map_err(|_| ReadOnlyStateError::Unreadable)?;
        Ok(Self { connection })
    }

    /// The quota rows QuotaBar last published, in the order it publishes them.
    pub fn overview(&self) -> Result<Vec<QuotaOverviewItem>, ReadOnlyStateError> {
        let raw: Option<String> = self
            .connection
            .query_row(
                "SELECT value FROM metadata WHERE key = 'overview_json'",
                [],
                |row| row.get(0),
            )
            .optional()
            .map_err(|_| ReadOnlyStateError::Unreadable)?;
        let Some(raw) = raw else {
            return Ok(Vec::new());
        };
        serde_json::from_str(&raw).map_err(|_| ReadOnlyStateError::Unreadable)
    }

    /// One folded period of this Mac's own Usage, or `None` when nothing has folded it yet.
    ///
    /// The periods are read exactly as the service stored them, so the command prints the same
    /// numbers QuotaBar does rather than folding a second answer out of the same rows
    /// ([ADR 0040](../../../docs/decisions/0040-a-period-is-folded-where-its-days-already-are.md)).
    pub fn local_usage_period(
        &self,
        period: UsagePeriod,
    ) -> Result<Option<Value>, ReadOnlyStateError> {
        let raw: Option<String> = self
            .connection
            .query_row(
                "SELECT value_json FROM usage_period_cache WHERE source = 'local' AND period = ?1",
                [period_key(period)],
                |row| row.get(0),
            )
            .optional()
            .map_err(|_| ReadOnlyStateError::Unreadable)?;
        raw.map(|raw| serde_json::from_str(&raw).map_err(|_| ReadOnlyStateError::Unreadable))
            .transpose()
    }
}

const fn period_key(period: UsagePeriod) -> &'static str {
    match period {
        UsagePeriod::Today => "today",
        UsagePeriod::Last7Days => "last_7_days",
        UsagePeriod::Last30Days => "last_30_days",
        UsagePeriod::All => "all",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::StateStore;
    use serde_json::json;

    #[test]
    fn an_empty_directory_is_a_mac_quotabar_has_not_run_on() {
        let root = tempdir();
        assert_eq!(
            ReadOnlyState::open(&root).err(),
            Some(ReadOnlyStateError::Missing)
        );
    }

    #[test]
    fn reads_what_the_service_published_without_taking_its_lock() {
        let root = tempdir();
        let store = StateStore::open(&root).expect("state opens");
        store
            .set_overview(&[overview_item()])
            .expect("overview stored");
        store
            .replace_usage_periods(
                crate::protocol::UsageSource::Local,
                &[(
                    UsagePeriod::Today,
                    json!({ "totals": { "total_tokens": 42 } }),
                )],
            )
            .expect("periods stored");

        // The service still holds its own connection and its owner lock while this reads.
        let reader = ReadOnlyState::open(&root).expect("reader opens");
        let overview = reader.overview().expect("overview read");
        assert_eq!(overview.len(), 1);
        assert_eq!(overview[0].identity.provider, "codex");
        assert_eq!(
            reader
                .local_usage_period(UsagePeriod::Today)
                .expect("period read")
                .and_then(|value| value["totals"]["total_tokens"].as_u64()),
            Some(42)
        );
        assert_eq!(
            reader
                .local_usage_period(UsagePeriod::All)
                .expect("period read"),
            None
        );
    }

    fn overview_item() -> QuotaOverviewItem {
        QuotaOverviewItem {
            identity: crate::protocol::QuotaOverviewIdentity {
                provider: "codex".to_owned(),
                fingerprint: "fingerprint".to_owned(),
                scope: "source".to_owned(),
                source_id: None,
            },
            snapshot: json!({
                "provider": "codex",
                "windows": [{ "id": "five_hour", "title": "5 Hours", "used_percent": 38 }],
                "observed_at": "2026-09-06T12:00:00Z",
            }),
            sources: Vec::new(),
            selected_source_id: "local".to_owned(),
            selected_source_display_name: "This Mac".to_owned(),
            automatic_source_id: "local".to_owned(),
            automatic_source_display_name: "This Mac".to_owned(),
            is_stale: false,
            source_pin: None,
        }
    }

    fn tempdir() -> PathBuf {
        let path = std::env::temp_dir().join(format!("quota-readonly-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&path).expect("temp root");
        path
    }
}
