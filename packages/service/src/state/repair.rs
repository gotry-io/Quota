//! Repair classification, session persistence, and the single `run_repair` entry.

use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use rusqlite::Connection;
use serde::{Deserialize, Serialize};

use super::salvage;
use super::{
    StateError, StateStore, bump_revision, metadata_flag, metadata_value,
    recover_interrupted_attempts, write_metadata_flag,
};
use crate::protocol::{
    RepairPhase, RepairRecoveryAction, RepairSession, RepairSeverity, RepairStatus,
};
use crate::state::now_rfc3339;

const REPAIR_SESSION_KEY: &str = "repair_session_json";
const AUTOMATIC_SALVAGE_DAY_KEY: &str = "automatic_salvage_utc_day";
const USAGE_ISOLATED_KEY: &str = "usage_isolated";
const DERIVED_DROP_PENDING_KEY: &str = "derived_drop_pending";
const MAX_SESSION_BYTES: usize = 4 * 1024;
const REQUIRED_COPY_PROGRESS_TOTAL: i64 = 7;

const DURABLE_TITLE: &str = "Repairing local data";
const DURABLE_GUIDANCE: &str = "Keep QuotaBar open. You can close this menu.";
const DERIVED_TITLE: &str = "Rebuilding Usage history";
const DERIVED_GUIDANCE: &str = "Quota and Account stay available. Usage history is catching up.";
const STUCK_GUIDANCE: &str = "Repair stopped responding. You can retry.";
const FAILED_GUIDANCE: &str = "Reinstall QuotaBar to repair local data.";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RepairClass {
    DurableImage,
    ProcessResidue,
    StaleHealthEvidence,
    DerivedState,
    ScheduledProgress,
    UserAction,
    TransientExternal,
    UntrustedInput,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RepairSite {
    Open,
    RefreshStart,
    RefreshWorker,
    WriteFailure,
    DiagnoseRead,
    PostRefresh,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RepairDisposition {
    Automatic,
    RetrySchedule,
    UserVerb,
    Isolate,
    NotRepair,
    FailClosed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RepairAction {
    ResumeInterruptedSalvage,
    SalvageDurableImage,
    RestoreLastGoodSnapshot,
    RefreshLastGoodSnapshot,
    CheckpointWal,
    DiscardUnreadableDerivedIndex,
    FinalizeInterruptedAttempts,
    ClearRefreshingFlags,
    InvalidateDiagnosticSnapshot,
    MarkUsageReindexPending,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RepairReport {
    pub site: RepairSite,
    pub executed: Vec<RepairAction>,
    pub changed: bool,
    pub fail_closed: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PersistenceClass {
    Durable,
    IoOrFull,
    UsageIsolated,
    Other,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(deny_unknown_fields)]
pub(super) struct PersistedRepair {
    #[serde(default)]
    seq: u64,
    #[serde(default)]
    session: Option<RepairSession>,
}

pub(super) struct RepairRuntime {
    seq: AtomicU64,
    last_seq: AtomicU64,
    last_seq_at: Mutex<Option<Instant>>,
    last_revision: AtomicU64,
    live: Mutex<RepairSession>,
    last_error: Mutex<Option<PersistenceClass>>,
    stuck_at: Mutex<Option<Instant>>,
    completed_at: Mutex<Option<Instant>>,
    remapped_on_load: bool,
}

impl RepairRuntime {
    pub(super) fn from_persisted(persisted: PersistedRepair) -> Self {
        let loaded = persisted
            .session
            .filter(|session| session.is_valid())
            .unwrap_or_else(RepairSession::idle);
        let remapped_on_load = matches!(
            loaded.status,
            RepairStatus::Completed | RepairStatus::Repairing | RepairStatus::Checking
        );
        let session = reconcile_loaded_session(loaded);
        Self {
            seq: AtomicU64::new(persisted.seq),
            last_seq: AtomicU64::new(persisted.seq),
            last_seq_at: Mutex::new(Some(Instant::now())),
            last_revision: AtomicU64::new(0),
            live: Mutex::new(session),
            last_error: Mutex::new(None),
            stuck_at: Mutex::new(None),
            completed_at: Mutex::new(None),
            remapped_on_load,
        }
    }
}

fn reconcile_loaded_session(session: RepairSession) -> RepairSession {
    match session.status {
        RepairStatus::Completed => RepairSession::idle(),
        RepairStatus::Repairing | RepairStatus::Checking => stuck_session(&session),
        _ => session,
    }
}

pub fn sqlite_durable_corruption(error: &rusqlite::Error) -> bool {
    salvage::sqlite_durable_corruption(error)
}

pub fn sqlite_io_or_full(error: &rusqlite::Error) -> bool {
    salvage::sqlite_io_or_full(error)
}

pub fn sqlite_durable_corruption_error(error: &StateError) -> bool {
    salvage::sqlite_durable_corruption_error(error)
}

pub fn sqlite_io_or_full_error(error: &StateError) -> bool {
    salvage::sqlite_io_or_full_error(error)
}

pub(super) fn read_persisted_repair(conn: &Connection) -> Result<PersistedRepair, StateError> {
    let Some(raw) = metadata_value(conn, REPAIR_SESSION_KEY)? else {
        return Ok(PersistedRepair::default());
    };
    if raw.len() > MAX_SESSION_BYTES {
        return Ok(PersistedRepair::default());
    }
    Ok(serde_json::from_str(&raw).unwrap_or_default())
}

impl StateStore {
    pub fn run_repair(&self, site: RepairSite) -> Result<RepairReport, StateError> {
        match site {
            RepairSite::Open => self.repair_open(),
            RepairSite::RefreshStart => self.repair_refresh_start(),
            RepairSite::RefreshWorker => self.repair_refresh_worker(),
            RepairSite::WriteFailure => self.repair_write_failure(),
            RepairSite::DiagnoseRead => self.repair_diagnose_read(),
            RepairSite::PostRefresh => self.repair_post_refresh(),
        }
    }

    pub fn repair_session(&self) -> RepairSession {
        self.repair
            .live
            .lock()
            .map(|session| session.clone())
            .unwrap_or_else(|_| RepairSession::idle())
    }

    pub(crate) fn persist_reconciled_repair(&self) -> Result<(), StateError> {
        if !self.repair.remapped_on_load {
            return Ok(());
        }
        self.persist_live_session()
    }

    pub(super) fn store_remembered_revision(&self, revision: u64) {
        self.repair.last_revision.store(revision, Ordering::Release);
    }

    pub fn increment_repair_heartbeat_seq(&self) -> u64 {
        let seq = self.repair.seq.fetch_add(1, Ordering::AcqRel) + 1;
        if let Ok(mut session) = self.repair.live.lock()
            && session.status == RepairStatus::Repairing
        {
            session.heartbeat_at = Some(now_rfc3339());
        }
        if let Ok(mut last_at) = self.repair.last_seq_at.lock() {
            *last_at = Some(Instant::now());
        }
        self.repair.last_seq.store(seq, Ordering::Release);
        seq
    }

    pub fn persist_repair_heartbeat_best_effort(&self) {
        self.persist_live_session_best_effort();
    }

    pub fn remembered_revision(&self) -> u64 {
        if let Ok(conn) = self.db.try_lock()
            && let Ok(revision) = super::metadata_u64(&conn, "revision")
        {
            self.repair.last_revision.store(revision, Ordering::Release);
            return revision;
        }
        self.repair.last_revision.load(Ordering::Acquire)
    }

    pub fn mark_repair_stuck_if_silent(&self, now: Instant, timeout: Duration) -> bool {
        let session = self.repair_session();
        if session.status != RepairStatus::Repairing {
            return false;
        }
        let last = self
            .repair
            .last_seq_at
            .lock()
            .ok()
            .and_then(|guard| *guard)
            .unwrap_or(now);
        if now.duration_since(last) < timeout {
            return false;
        }
        self.apply_live_session(stuck_session(&session));
        if let Ok(mut stuck_at) = self.repair.stuck_at.lock() {
            *stuck_at = Some(now);
        }
        self.persist_live_session_best_effort();
        true
    }

    pub fn mark_repair_failed_if_stuck_expired(&self, now: Instant, timeout: Duration) -> bool {
        let session = self.repair_session();
        if session.status != RepairStatus::Stuck {
            return false;
        }
        let Some(stuck_at) = self.repair.stuck_at.lock().ok().and_then(|guard| *guard) else {
            return false;
        };
        if now.duration_since(stuck_at) < timeout {
            return false;
        }
        self.apply_live_session(failed_session(&session, RepairRecoveryAction::Reinstall));
        self.persist_live_session_best_effort();
        true
    }

    pub fn mark_repair_idle_if_completed_expired(&self, now: Instant, timeout: Duration) -> bool {
        let session = self.repair_session();
        if session.status != RepairStatus::Completed {
            return false;
        }
        let Some(completed_at) = self
            .repair
            .completed_at
            .lock()
            .ok()
            .and_then(|guard| *guard)
        else {
            return false;
        };
        if now.duration_since(completed_at) < timeout {
            return false;
        }
        self.apply_live_session(RepairSession::idle());
        self.persist_live_session_best_effort();
        true
    }

    pub fn note_persistence_failure(&self, error: &StateError) {
        let class = classify_persistence_error(error);
        if let Ok(mut last) = self.repair.last_error.lock() {
            *last = Some(class);
        }
        if matches!(
            class,
            PersistenceClass::Durable | PersistenceClass::IoOrFull
        ) && let Ok(conn) = self.db.try_lock()
        {
            let _ = write_metadata_flag(&conn, "snapshot_untrusted", true);
        }
        if class == PersistenceClass::UsageIsolated
            && let Ok(conn) = self.db.try_lock()
        {
            let _ = write_metadata_flag(&conn, USAGE_ISOLATED_KEY, true);
        }
    }

    pub(crate) fn record_open_salvage_session(&self) -> Result<(), StateError> {
        self.record_automatic_salvage_day()?;
        let now = now_rfc3339();
        self.apply_live_session(completed_durable_session(&now));
        // Flash is process-local; persist idle so the next process does not resume Repairing.
        self.persist_session_snapshot(&RepairSession::idle())
    }

    fn repair_open(&self) -> Result<RepairReport, StateError> {
        let mut executed = Vec::new();
        match self.persist_probe() {
            Ok(()) => {}
            Err(error) if sqlite_io_or_full_error(&error) => return Err(StateError::Unavailable),
            Err(error) if sqlite_durable_corruption_error(&error) => {
                match self.salvage_durable_if_allowed(true)? {
                    SalvageOutcome::Ran => executed.push(RepairAction::SalvageDurableImage),
                    SalvageOutcome::Capped => {
                        return Ok(self.stuck_report(RepairSite::Open, executed));
                    }
                    SalvageOutcome::FailedClosed => {
                        return Ok(RepairReport {
                            site: RepairSite::Open,
                            executed,
                            changed: true,
                            fail_closed: true,
                        });
                    }
                }
            }
            Err(error) => return Err(error),
        }
        self.recover_process_residue()?;
        executed.push(RepairAction::FinalizeInterruptedAttempts);
        executed.push(RepairAction::ClearRefreshingFlags);
        if executed.contains(&RepairAction::SalvageDurableImage) {
            executed.push(RepairAction::InvalidateDiagnosticSnapshot);
            executed.push(RepairAction::MarkUsageReindexPending);
        }
        Ok(RepairReport {
            site: RepairSite::Open,
            executed,
            changed: true,
            fail_closed: false,
        })
    }

    fn repair_refresh_start(&self) -> Result<RepairReport, StateError> {
        let mut executed = Vec::new();
        let user_retry = matches!(
            self.repair_session().status,
            RepairStatus::Stuck | RepairStatus::Failed
        ) && self.repair_session().recovery_action
            == Some(RepairRecoveryAction::Retry);
        match self.persist_probe() {
            Ok(()) => {
                let session = self.repair_session();
                let should_idle = matches!(
                    session.status,
                    RepairStatus::Repairing
                        | RepairStatus::Checking
                        | RepairStatus::Completed
                        | RepairStatus::Stuck
                ) || (session.status == RepairStatus::Failed
                    && session.recovery_action == Some(RepairRecoveryAction::Retry));
                if should_idle {
                    self.apply_live_session(RepairSession::idle());
                    let _ = self.persist_live_session();
                }
            }
            Err(error) if sqlite_io_or_full_error(&error) => return Err(StateError::Unavailable),
            Err(error) if sqlite_durable_corruption_error(&error) => {
                match self.salvage_durable_if_allowed(!user_retry)? {
                    SalvageOutcome::Ran => executed.push(RepairAction::SalvageDurableImage),
                    SalvageOutcome::Capped => {
                        return Ok(self.stuck_report(RepairSite::RefreshStart, executed));
                    }
                    SalvageOutcome::FailedClosed => {
                        return Ok(RepairReport {
                            site: RepairSite::RefreshStart,
                            executed,
                            changed: true,
                            fail_closed: true,
                        });
                    }
                }
            }
            Err(error) => return Err(error),
        }
        let isolated = self.usage_isolated_flag()?;
        if isolated {
            self.set_metadata_flag(DERIVED_DROP_PENDING_KEY, true)?;
        }
        Ok(RepairReport {
            site: RepairSite::RefreshStart,
            changed: !executed.is_empty() || isolated,
            executed,
            fail_closed: false,
        })
    }

    fn repair_refresh_worker(&self) -> Result<RepairReport, StateError> {
        let pending = self.derived_drop_pending().unwrap_or(false);
        let isolated = self.usage_isolated_flag().unwrap_or(false);
        if !pending && !isolated {
            return Ok(RepairReport {
                site: RepairSite::RefreshWorker,
                executed: Vec::new(),
                changed: false,
                fail_closed: false,
            });
        }
        self.discard_unreadable_derived_index()?;
        Ok(RepairReport {
            site: RepairSite::RefreshWorker,
            executed: vec![
                RepairAction::DiscardUnreadableDerivedIndex,
                RepairAction::MarkUsageReindexPending,
            ],
            changed: true,
            fail_closed: false,
        })
    }

    fn repair_write_failure(&self) -> Result<RepairReport, StateError> {
        let class = self
            .repair
            .last_error
            .lock()
            .ok()
            .and_then(|guard| *guard)
            .unwrap_or(PersistenceClass::Other);
        match class {
            PersistenceClass::Durable => {
                let now = now_rfc3339();
                if self.automatic_salvage_used_today().unwrap_or(false) {
                    return Ok(self.stuck_report(RepairSite::WriteFailure, Vec::new()));
                }
                self.apply_live_session(durable_repairing_session(
                    &now,
                    RepairPhase::PreservingAccount,
                    "Copying account",
                    Some(0),
                    Some(REQUIRED_COPY_PROGRESS_TOTAL),
                ));
                let _ = self.persist_live_session();
                Ok(RepairReport {
                    site: RepairSite::WriteFailure,
                    executed: Vec::new(),
                    changed: true,
                    fail_closed: false,
                })
            }
            PersistenceClass::UsageIsolated => match self.persist_probe() {
                Ok(()) => {
                    self.discard_unreadable_derived_index()?;
                    Ok(RepairReport {
                        site: RepairSite::WriteFailure,
                        executed: vec![
                            RepairAction::DiscardUnreadableDerivedIndex,
                            RepairAction::MarkUsageReindexPending,
                        ],
                        changed: true,
                        fail_closed: false,
                    })
                }
                Err(error) if sqlite_io_or_full_error(&error) => Err(StateError::Unavailable),
                Err(error) if sqlite_durable_corruption_error(&error) => {
                    let now = now_rfc3339();
                    if self.automatic_salvage_used_today().unwrap_or(false) {
                        return Ok(self.stuck_report(RepairSite::WriteFailure, Vec::new()));
                    }
                    self.apply_live_session(durable_repairing_session(
                        &now,
                        RepairPhase::PreservingAccount,
                        "Copying account",
                        Some(0),
                        Some(REQUIRED_COPY_PROGRESS_TOTAL),
                    ));
                    let _ = self.persist_live_session();
                    Ok(RepairReport {
                        site: RepairSite::WriteFailure,
                        executed: Vec::new(),
                        changed: true,
                        fail_closed: false,
                    })
                }
                Err(error) => Err(error),
            },
            PersistenceClass::IoOrFull => Err(StateError::Unavailable),
            PersistenceClass::Other => Ok(RepairReport {
                site: RepairSite::WriteFailure,
                executed: Vec::new(),
                changed: false,
                fail_closed: false,
            }),
        }
    }

    fn repair_diagnose_read(&self) -> Result<RepairReport, StateError> {
        let fail_closed = matches!(
            self.health_evidence_trust(),
            super::HealthEvidenceTrust::FailClosed
        );
        Ok(RepairReport {
            site: RepairSite::DiagnoseRead,
            executed: Vec::new(),
            changed: false,
            fail_closed,
        })
    }

    fn repair_post_refresh(&self) -> Result<RepairReport, StateError> {
        if let Some(class) = self.repair.last_error.lock().ok().and_then(|guard| *guard) {
            let error = match class {
                PersistenceClass::Durable => StateError::InvalidState,
                PersistenceClass::IoOrFull => StateError::Unavailable,
                _ => StateError::Unavailable,
            };
            self.note_persistence_failure(&error);
        }
        let mut executed = Vec::new();
        {
            let conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
            if salvage::checkpoint_wal(&conn).is_ok() {
                executed.push(RepairAction::CheckpointWal);
            }
        }
        if salvage::write_last_good_if_space(&self.root).unwrap_or(false) {
            executed.push(RepairAction::RefreshLastGoodSnapshot);
        }
        let session = self.repair_session();
        if session.severity == RepairSeverity::Derived
            && session.status == RepairStatus::Repairing
            && !self.usage_reindex_pending().unwrap_or(true)
        {
            let started = session.started_at.unwrap_or_else(now_rfc3339);
            self.apply_live_session(completed_derived_session(&started));
            let _ = self.persist_live_session();
        }
        Ok(RepairReport {
            site: RepairSite::PostRefresh,
            executed,
            changed: true,
            fail_closed: false,
        })
    }

    fn salvage_durable_if_allowed(&self, automatic: bool) -> Result<SalvageOutcome, StateError> {
        let current = self.repair_session();
        if automatic
            && current.status == RepairStatus::Failed
            && current.recovery_action == Some(RepairRecoveryAction::Reinstall)
        {
            return Ok(SalvageOutcome::FailedClosed);
        }
        if automatic && self.automatic_salvage_used_today()? {
            return Ok(SalvageOutcome::Capped);
        }
        if automatic {
            let _ = self.record_automatic_salvage_day();
        }
        let now = now_rfc3339();
        self.apply_live_session(durable_repairing_session(
            &now,
            RepairPhase::PreservingAccount,
            "Copying account",
            Some(0),
            Some(REQUIRED_COPY_PROGRESS_TOTAL),
        ));
        self.increment_repair_heartbeat_seq();
        let _ = self.persist_live_session();
        match self.replace_connection_with_salvage() {
            Ok(()) => {
                self.record_automatic_salvage_day()?;
                let completed_at = now_rfc3339();
                self.apply_live_session(durable_repairing_session(
                    self.repair_session()
                        .started_at
                        .as_deref()
                        .unwrap_or(&completed_at),
                    RepairPhase::RebuildingStorage,
                    "Rebuilding storage",
                    Some(REQUIRED_COPY_PROGRESS_TOTAL),
                    Some(REQUIRED_COPY_PROGRESS_TOTAL),
                ));
                self.increment_repair_heartbeat_seq();
                self.apply_live_session(completed_durable_session(
                    self.repair_session()
                        .started_at
                        .as_deref()
                        .unwrap_or(&completed_at),
                ));
                self.persist_live_session()?;
                self.recover_process_residue()?;
                Ok(SalvageOutcome::Ran)
            }
            Err(error) if sqlite_io_or_full_error(&error) => Err(StateError::Unavailable),
            Err(_) => {
                if automatic {
                    let _ = self.record_automatic_salvage_day();
                }
                let started = self.repair_session().started_at.unwrap_or_else(now_rfc3339);
                self.apply_live_session(failed_session(
                    &durable_repairing_session(
                        &started,
                        RepairPhase::RebuildingStorage,
                        "Rebuilding storage",
                        None,
                        None,
                    ),
                    RepairRecoveryAction::Reinstall,
                ));
                let _ = self.persist_live_session();
                Ok(SalvageOutcome::FailedClosed)
            }
        }
    }

    fn replace_connection_with_salvage(&self) -> Result<(), StateError> {
        let mut guard = self.db.lock().map_err(|_| StateError::Unavailable)?;
        drop(std::mem::replace(
            &mut *guard,
            Connection::open_in_memory()?,
        ));
        match salvage::salvage_existing(&self.root) {
            Ok(connection) => {
                *guard = connection;
                Ok(())
            }
            Err(error) => {
                if let Ok(connection) = salvage::reopen_live(&self.root) {
                    *guard = connection;
                }
                Err(error)
            }
        }
    }

    fn recover_process_residue(&self) -> Result<(), StateError> {
        let mut conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        recover_interrupted_attempts(&mut conn)
    }

    fn discard_unreadable_derived_index(&self) -> Result<(), StateError> {
        self.begin_derived_reindex_session();
        self.increment_repair_heartbeat_seq();
        let _ = self.persist_live_session();
        {
            let mut conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
            let tx = conn.transaction()?;
            crate::migration::recreate_usage_index_tables(&tx)?;
            write_metadata_flag(&tx, "usage_reindex_pending", true)?;
            write_metadata_flag(&tx, "snapshot_untrusted", true)?;
            write_metadata_flag(&tx, DERIVED_DROP_PENDING_KEY, false)?;
            write_metadata_flag(&tx, USAGE_ISOLATED_KEY, false)?;
            tx.commit()?;
        }
        self.apply_live_session(derived_repairing_session(
            self.repair_session()
                .started_at
                .as_deref()
                .unwrap_or(&now_rfc3339()),
            "Scanning local logs",
        ));
        self.increment_repair_heartbeat_seq();
        let _ = self.persist_live_session();
        Ok(())
    }

    fn begin_derived_reindex_session(&self) {
        let current = self.repair_session();
        if current.severity == RepairSeverity::Durable
            && matches!(
                current.status,
                RepairStatus::Repairing | RepairStatus::Stuck | RepairStatus::Failed
            )
        {
            return;
        }
        let started = current.started_at.unwrap_or_else(now_rfc3339);
        self.apply_live_session(derived_repairing_session(&started, "Rebuilding storage"));
    }

    fn apply_live_session(&self, session: RepairSession) {
        if let Ok(mut live) = self.repair.live.lock() {
            *live = session.clone();
        }
        match session.status {
            RepairStatus::Repairing => {
                if let Ok(mut last_at) = self.repair.last_seq_at.lock() {
                    *last_at = Some(Instant::now());
                }
                if let Ok(mut stuck_at) = self.repair.stuck_at.lock() {
                    *stuck_at = None;
                }
                if let Ok(mut completed_at) = self.repair.completed_at.lock() {
                    *completed_at = None;
                }
            }
            RepairStatus::Completed => {
                if let Ok(mut completed_at) = self.repair.completed_at.lock() {
                    *completed_at = Some(Instant::now());
                }
            }
            RepairStatus::Stuck => {
                if let Ok(mut stuck_at) = self.repair.stuck_at.lock()
                    && stuck_at.is_none()
                {
                    *stuck_at = Some(Instant::now());
                }
            }
            RepairStatus::Idle => {
                if let Ok(mut stuck_at) = self.repair.stuck_at.lock() {
                    *stuck_at = None;
                }
                if let Ok(mut completed_at) = self.repair.completed_at.lock() {
                    *completed_at = None;
                }
            }
            _ => {}
        }
    }

    fn persist_live_session(&self) -> Result<(), StateError> {
        self.persist_session_snapshot(&self.repair_session())
    }

    fn persist_session_snapshot(&self, session: &RepairSession) -> Result<(), StateError> {
        let conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        persist_session_on(&conn, self.repair.seq.load(Ordering::Acquire), session)?;
        let revision = bump_revision(&conn)?;
        self.store_remembered_revision(revision);
        Ok(())
    }

    fn persist_live_session_best_effort(&self) {
        let Ok(conn) = self.db.try_lock() else {
            return;
        };
        let session = self.repair_session();
        let seq = self.repair.seq.load(Ordering::Acquire);
        if persist_session_on(&conn, seq, &session).is_ok()
            && let Ok(revision) = bump_revision(&conn)
        {
            self.store_remembered_revision(revision);
        }
    }

    fn stuck_report(&self, site: RepairSite, executed: Vec<RepairAction>) -> RepairReport {
        let now = now_rfc3339();
        let current = self.repair_session();
        let started = current.started_at.unwrap_or_else(|| now.clone());
        self.apply_live_session(stuck_session(&durable_repairing_session(
            &started,
            current.phase.unwrap_or(RepairPhase::PreservingAccount),
            current.activity.as_deref().unwrap_or("Copying account"),
            current.progress_current,
            current.progress_total,
        )));
        let _ = self.persist_live_session();
        RepairReport {
            site,
            executed,
            changed: true,
            fail_closed: false,
        }
    }

    fn automatic_salvage_used_today(&self) -> Result<bool, StateError> {
        let conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        Ok(metadata_value(&conn, AUTOMATIC_SALVAGE_DAY_KEY)?
            .is_some_and(|value| value == utc_day_from_rfc3339(&now_rfc3339())))
    }

    fn record_automatic_salvage_day(&self) -> Result<(), StateError> {
        let conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        conn.execute(
            "INSERT INTO metadata(key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            rusqlite::params![
                AUTOMATIC_SALVAGE_DAY_KEY,
                utc_day_from_rfc3339(&now_rfc3339())
            ],
        )?;
        Ok(())
    }

    fn usage_isolated_flag(&self) -> Result<bool, StateError> {
        let conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        metadata_flag(&conn, USAGE_ISOLATED_KEY)
    }

    fn set_metadata_flag(&self, key: &str, value: bool) -> Result<(), StateError> {
        let conn = self.db.lock().map_err(|_| StateError::Unavailable)?;
        write_metadata_flag(&conn, key, value)
    }

    #[cfg(test)]
    pub(crate) fn set_usage_isolated_for_test(&self, isolated: bool) -> Result<(), StateError> {
        self.set_metadata_flag(USAGE_ISOLATED_KEY, isolated)
    }

    #[cfg(test)]
    pub(crate) fn repair_seq_for_test(&self) -> u64 {
        self.repair.seq.load(Ordering::Acquire)
    }

    #[cfg(test)]
    pub(crate) fn start_durable_repairing_for_test(&self) -> Result<(), StateError> {
        let now = now_rfc3339();
        self.apply_live_session(durable_repairing_session(
            &now,
            RepairPhase::PreservingAccount,
            "Copying account",
            Some(0),
            Some(REQUIRED_COPY_PROGRESS_TOTAL),
        ));
        self.persist_live_session()
    }

    #[cfg(test)]
    pub(crate) fn persist_session_for_test(
        &self,
        session: RepairSession,
    ) -> Result<(), StateError> {
        self.apply_live_session(session);
        self.persist_live_session()
    }
}

enum SalvageOutcome {
    Ran,
    Capped,
    FailedClosed,
}

fn persist_session_on(
    conn: &Connection,
    seq: u64,
    session: &RepairSession,
) -> Result<(), StateError> {
    let persisted = PersistedRepair {
        seq,
        session: Some(session.clone()),
    };
    let raw = serde_json::to_string(&persisted)?;
    if raw.len() > MAX_SESSION_BYTES {
        return Err(StateError::InvalidState);
    }
    conn.execute(
        "INSERT INTO metadata(key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        rusqlite::params![REPAIR_SESSION_KEY, raw],
    )?;
    Ok(())
}

fn classify_persistence_error(error: &StateError) -> PersistenceClass {
    if sqlite_durable_corruption_error(error) {
        PersistenceClass::Durable
    } else if sqlite_io_or_full_error(error) {
        PersistenceClass::IoOrFull
    } else if usage_isolated_error(error) {
        PersistenceClass::UsageIsolated
    } else {
        PersistenceClass::Other
    }
}

fn usage_isolated_error(error: &StateError) -> bool {
    let message = error.to_string().to_ascii_lowercase();
    message.contains("usage_file_index")
        || message.contains("usage_file_records")
        || message.contains("usage_dirty_ranges")
        || message.contains("usage_partial_sources")
}

fn durable_repairing_session(
    started_at: &str,
    phase: RepairPhase,
    activity: &str,
    progress_current: Option<i64>,
    progress_total: Option<i64>,
) -> RepairSession {
    RepairSession {
        status: RepairStatus::Repairing,
        severity: RepairSeverity::Durable,
        phase: Some(phase),
        title: Some(DURABLE_TITLE.to_owned()),
        guidance: Some(DURABLE_GUIDANCE.to_owned()),
        activity: Some(activity.to_owned()),
        started_at: Some(started_at.to_owned()),
        heartbeat_at: Some(now_rfc3339()),
        progress_current,
        progress_total,
        stuck: false,
        blocks_quit: true,
        recovery_action: None,
    }
}

fn derived_repairing_session(started_at: &str, activity: &str) -> RepairSession {
    RepairSession {
        status: RepairStatus::Repairing,
        severity: RepairSeverity::Derived,
        phase: Some(RepairPhase::ReindexingUsage),
        title: Some(DERIVED_TITLE.to_owned()),
        guidance: Some(DERIVED_GUIDANCE.to_owned()),
        activity: Some(activity.to_owned()),
        started_at: Some(started_at.to_owned()),
        heartbeat_at: Some(now_rfc3339()),
        progress_current: None,
        progress_total: None,
        stuck: false,
        blocks_quit: false,
        recovery_action: None,
    }
}

fn completed_derived_session(started_at: &str) -> RepairSession {
    RepairSession {
        status: RepairStatus::Completed,
        severity: RepairSeverity::Derived,
        phase: Some(RepairPhase::ReindexingUsage),
        title: Some(DERIVED_TITLE.to_owned()),
        guidance: Some(DERIVED_GUIDANCE.to_owned()),
        activity: Some("Scanning local logs".to_owned()),
        started_at: Some(started_at.to_owned()),
        heartbeat_at: Some(now_rfc3339()),
        progress_current: None,
        progress_total: None,
        stuck: false,
        blocks_quit: false,
        recovery_action: None,
    }
}

fn completed_durable_session(started_at: &str) -> RepairSession {
    RepairSession {
        status: RepairStatus::Completed,
        severity: RepairSeverity::Durable,
        phase: Some(RepairPhase::Verifying),
        title: Some(DURABLE_TITLE.to_owned()),
        guidance: Some(DURABLE_GUIDANCE.to_owned()),
        activity: Some("Rebuilding storage".to_owned()),
        started_at: Some(started_at.to_owned()),
        heartbeat_at: Some(now_rfc3339()),
        progress_current: Some(REQUIRED_COPY_PROGRESS_TOTAL),
        progress_total: Some(REQUIRED_COPY_PROGRESS_TOTAL),
        stuck: false,
        blocks_quit: false,
        recovery_action: None,
    }
}

fn stuck_session(current: &RepairSession) -> RepairSession {
    let mut session = current.clone();
    session.status = RepairStatus::Stuck;
    session.stuck = true;
    session.blocks_quit = false;
    session.recovery_action = Some(RepairRecoveryAction::Retry);
    session.guidance = Some(STUCK_GUIDANCE.to_owned());
    session.heartbeat_at = Some(now_rfc3339());
    session
}

fn failed_session(current: &RepairSession, recovery: RepairRecoveryAction) -> RepairSession {
    let mut session = current.clone();
    session.status = RepairStatus::Failed;
    session.stuck = true;
    session.blocks_quit = false;
    session.recovery_action = Some(recovery);
    session.guidance = Some(FAILED_GUIDANCE.to_owned());
    session.heartbeat_at = Some(now_rfc3339());
    session
}

fn utc_day_from_rfc3339(value: &str) -> String {
    value.get(..10).unwrap_or(value).to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::StateStore;
    use std::fs;
    use std::thread;
    use uuid::Uuid;

    fn temp_store() -> (std::path::PathBuf, StateStore) {
        let root = std::env::temp_dir().join(format!("quota-repair-{}", Uuid::new_v4()));
        fs::create_dir_all(&root).expect("root");
        let store = StateStore::open(&root).expect("state");
        (root, store)
    }

    #[test]
    fn diagnose_read_does_not_salvage() {
        let (root, store) = temp_store();
        store
            .fail_persist_probe_with_corruption_for_test()
            .expect("poison");
        let report = store
            .run_repair(RepairSite::DiagnoseRead)
            .expect("diagnose");
        assert!(!report.changed);
        assert!(report.fail_closed);
        assert!(store.state_salvaged_at().expect("marker").is_none());
        assert!(!root.join("state.sqlite.broken").exists());
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn refresh_start_does_not_drop_usage_tables() {
        let (root, store) = temp_store();
        store.insert_usage_file_record_for_test().expect("usage");
        store.set_usage_isolated_for_test(true).expect("flag");
        let report = store
            .run_repair(RepairSite::RefreshStart)
            .expect("refresh start");
        assert!(
            !report
                .executed
                .contains(&RepairAction::DiscardUnreadableDerivedIndex)
        );
        assert_eq!(store.usage_event_count().expect("count"), 1);
        assert!(store.derived_drop_pending().expect("pending"));
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn refresh_worker_drops_usage_index_in_one_transaction() {
        let (root, store) = temp_store();
        store.insert_usage_file_record_for_test().expect("usage");
        store
            .write_usage_scan_diagnostics(crate::usage::UsageAgent::Codex, &serde_json::json!({}))
            .expect("scan diagnostics");
        store
            .write_sync_diagnostic(&serde_json::json!({}))
            .expect("sync diagnostics");
        store
            .write_session_json(&serde_json::json!({"status":"active"}))
            .expect("session");
        store.set_usage_isolated_for_test(true).expect("isolated");
        store
            .run_repair(RepairSite::RefreshStart)
            .expect("flag pending");
        assert_eq!(store.usage_event_count().expect("before"), 1);

        let report = store
            .run_repair(RepairSite::RefreshWorker)
            .expect("refresh worker");
        assert!(
            report
                .executed
                .contains(&RepairAction::DiscardUnreadableDerivedIndex)
        );
        assert!(
            report
                .executed
                .contains(&RepairAction::MarkUsageReindexPending)
        );
        assert_eq!(store.usage_event_count().expect("after"), 0);
        assert!(store.usage_reindex_pending().expect("reindex"));
        assert!(store.snapshot_untrusted().expect("untrusted"));
        assert!(!store.derived_drop_pending().expect("pending cleared"));
        assert!(store.session_json().expect("session").is_some());
        assert!(
            store
                .usage_scan_diagnostics()
                .expect("scan diagnostics")
                .is_empty()
        );
        assert!(store.sync_diagnostic().expect("sync diagnostics").is_none());
        let session = store.repair_session();
        assert_eq!(session.severity, RepairSeverity::Derived);
        assert_eq!(session.phase, Some(RepairPhase::ReindexingUsage));
        assert!(!session.blocks_quit);
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn write_failure_drops_usage_index_when_persist_probe_passes() {
        let (root, store) = temp_store();
        store.insert_usage_file_record_for_test().expect("usage");
        store
            .write_usage_scan_diagnostics(crate::usage::UsageAgent::Codex, &serde_json::json!({}))
            .expect("scan diagnostics");
        let isolated = StateError::Sql(rusqlite::Error::SqliteFailure(
            rusqlite::ffi::Error {
                code: rusqlite::ErrorCode::ConstraintViolation,
                extended_code: 19,
            },
            Some("usage_file_records unique constraint".into()),
        ));
        store.note_persistence_failure(&isolated);
        let report = store
            .run_repair(RepairSite::WriteFailure)
            .expect("write failure");
        assert!(
            report
                .executed
                .contains(&RepairAction::DiscardUnreadableDerivedIndex)
        );
        assert_eq!(store.usage_event_count().expect("after"), 0);
        assert!(
            store
                .usage_scan_diagnostics()
                .expect("scan diagnostics")
                .is_empty()
        );
        assert_eq!(store.repair_session().severity, RepairSeverity::Derived);
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn post_refresh_keeps_derived_session_while_reindex_pending() {
        let (root, store) = temp_store();
        store.set_usage_isolated_for_test(true).expect("isolated");
        store
            .run_repair(RepairSite::RefreshStart)
            .expect("refresh start");
        store
            .run_repair(RepairSite::RefreshWorker)
            .expect("refresh worker");
        assert!(store.usage_reindex_pending().expect("pending"));
        assert_eq!(store.repair_session().status, RepairStatus::Repairing);
        assert_eq!(store.repair_session().severity, RepairSeverity::Derived);

        store
            .run_repair(RepairSite::PostRefresh)
            .expect("post refresh while pending");
        let session = store.repair_session();
        assert_eq!(session.status, RepairStatus::Repairing);
        assert_eq!(session.phase, Some(RepairPhase::ReindexingUsage));

        store
            .set_usage_reindex_pending(false)
            .expect("clear pending");
        store
            .run_repair(RepairSite::PostRefresh)
            .expect("post refresh after scan");
        assert_eq!(store.repair_session().status, RepairStatus::Completed);
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn heartbeat_increments_seq_without_sqlite_lock() {
        let (root, store) = temp_store();
        store.start_durable_repairing_for_test().expect("session");
        let blocked = store.db.lock().expect("lock");
        let started = Instant::now();
        let seq = store.increment_repair_heartbeat_seq();
        let elapsed = started.elapsed();
        drop(blocked);
        assert_eq!(seq, 1);
        assert_eq!(store.repair_seq_for_test(), 1);
        assert!(elapsed < Duration::from_millis(50));
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn watchdog_marks_stuck_when_seq_stops() {
        let (root, store) = temp_store();
        store.start_durable_repairing_for_test().expect("session");
        let started = Instant::now();
        assert!(!store.mark_repair_stuck_if_silent(
            started + Duration::from_secs(10),
            Duration::from_secs(45)
        ));
        assert!(store.mark_repair_stuck_if_silent(
            started + Duration::from_secs(46),
            Duration::from_secs(45)
        ));
        let session = store.repair_session();
        assert_eq!(session.status, RepairStatus::Stuck);
        assert!(!session.blocks_quit);
        assert_eq!(session.recovery_action, Some(RepairRecoveryAction::Retry));
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn automatic_salvage_creates_durable_session() {
        let (root, store) = temp_store();
        store
            .fail_persist_probe_with_corruption_for_test()
            .expect("poison");
        let report = store.run_repair(RepairSite::RefreshStart).expect("salvage");
        assert!(report.executed.contains(&RepairAction::SalvageDurableImage));
        let session = store.repair_session();
        assert_eq!(session.severity, RepairSeverity::Durable);
        assert!(matches!(
            session.status,
            RepairStatus::Repairing | RepairStatus::Completed
        ));
        assert!(store.state_salvaged_at().expect("marker").is_some());
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn second_automatic_salvage_same_day_is_stuck() {
        let (root, store) = temp_store();
        store
            .fail_persist_probe_with_corruption_for_test()
            .expect("poison");
        store
            .run_repair(RepairSite::RefreshStart)
            .expect("first salvage");
        store
            .fail_persist_probe_with_corruption_for_test()
            .expect("poison again");
        let report = store
            .run_repair(RepairSite::RefreshStart)
            .expect("second detect");
        assert!(!report.executed.contains(&RepairAction::SalvageDurableImage));
        assert_eq!(store.repair_session().status, RepairStatus::Stuck);
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn persisted_completed_loads_as_idle() {
        let (root, store) = temp_store();
        store
            .persist_session_for_test(completed_durable_session("2026-08-17T01:00:00Z"))
            .expect("persist completed");
        drop(store);
        let store = StateStore::open(&root).expect("reopen");
        assert_eq!(store.repair_session(), RepairSession::idle());
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn persisted_repairing_loads_as_stuck() {
        let (root, store) = temp_store();
        store
            .start_durable_repairing_for_test()
            .expect("persist repairing");
        drop(store);
        let store = StateStore::open(&root).expect("reopen");
        let session = store.repair_session();
        assert_eq!(session.status, RepairStatus::Stuck);
        assert!(!session.blocks_quit);
        assert_eq!(session.recovery_action, Some(RepairRecoveryAction::Retry));
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn restored_stuck_does_not_start_reinstall_timer() {
        let (root, store) = temp_store();
        store
            .start_durable_repairing_for_test()
            .expect("persist repairing");
        drop(store);
        let store = StateStore::open(&root).expect("reopen remapped");
        let later = Instant::now() + Duration::from_secs(31);
        assert!(!store.mark_repair_failed_if_stuck_expired(later, Duration::from_secs(30)));
        let remapped = store.repair_session();
        assert_eq!(remapped.status, RepairStatus::Stuck);
        assert_eq!(remapped.recovery_action, Some(RepairRecoveryAction::Retry));
        store
            .persist_session_for_test(remapped.clone())
            .expect("persist stuck");
        drop(store);
        let store = StateStore::open(&root).expect("reopen persisted stuck");
        assert!(!store.mark_repair_failed_if_stuck_expired(later, Duration::from_secs(30)));
        let restored = store.repair_session();
        assert_eq!(restored.status, RepairStatus::Stuck);
        assert_eq!(restored.recovery_action, Some(RepairRecoveryAction::Retry));
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn failed_reinstall_does_not_retry_automatic_salvage() {
        let (root, store) = temp_store();
        let now = now_rfc3339();
        store
            .persist_session_for_test(failed_session(
                &durable_repairing_session(
                    &now,
                    RepairPhase::RebuildingStorage,
                    "Rebuilding storage",
                    None,
                    None,
                ),
                RepairRecoveryAction::Reinstall,
            ))
            .expect("persist failed");
        store
            .fail_persist_probe_with_corruption_for_test()
            .expect("poison");
        let report = store
            .run_repair(RepairSite::RefreshStart)
            .expect("refresh start");
        assert!(!report.executed.contains(&RepairAction::SalvageDurableImage));
        assert!(report.fail_closed);
        assert!(store.state_salvaged_at().expect("marker").is_none());
        assert!(!root.join("state.sqlite.broken").exists());
        assert_eq!(store.repair_session().status, RepairStatus::Failed);
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn heartbeat_thread_can_tick_while_another_thread_holds_sqlite() {
        let (root, store) = temp_store();
        store.start_durable_repairing_for_test().expect("session");
        thread::scope(|scope| {
            let lock = store.db.lock().expect("lock");
            let seq = scope
                .spawn(|| store.increment_repair_heartbeat_seq())
                .join()
                .expect("join");
            drop(lock);
            assert_eq!(seq, 1);
        });
        drop(store);
        fs::remove_dir_all(root).expect("cleanup");
    }
}
