//! One-time import of the released JSON state into SQLite.

mod legacy_json;

pub use legacy_json::apply;
