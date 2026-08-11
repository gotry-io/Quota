//! Durable SQLite schema migrations.

mod schema;

pub fn apply(conn: &mut rusqlite::Connection) -> Result<(), crate::state::StateError> {
    schema::apply(conn)
}
