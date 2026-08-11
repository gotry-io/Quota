//! Durable SQLite schema migrations and one-time import of released JSON state.

mod legacy_json;
mod schema;

/// Open the durable schema first, then run the isolated one-time import. Keeping those concerns
/// separate means removing the released JSON compatibility code cannot remove live tables or
/// silently rewrite an applied migration.
pub fn apply(
    conn: &mut rusqlite::Connection,
    root: &std::path::Path,
) -> Result<(), crate::state::StateError> {
    schema::apply(conn)?;
    legacy_json::import(conn, root)
}
