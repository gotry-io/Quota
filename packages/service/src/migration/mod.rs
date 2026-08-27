//! Local SQLite schemas.
//!
//! Two files, two schemas, both starting at v1: `identity.sqlite` holds what this device cannot
//! regenerate, `cache.sqlite` holds what it can.

pub mod cache;
pub mod identity;
