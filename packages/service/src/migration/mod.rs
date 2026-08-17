//! Durable SQLite schema migrations.

mod schema;

pub fn apply(conn: &mut rusqlite::Connection) -> Result<(), crate::state::StateError> {
    schema::apply(conn)
}

pub(crate) fn recreate_usage_index_tables(
    tx: &rusqlite::Transaction<'_>,
) -> Result<(), crate::state::StateError> {
    schema::recreate_usage_index_tables(tx)
}
