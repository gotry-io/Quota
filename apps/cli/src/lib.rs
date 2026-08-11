//! Linux-native `quotacli` command parsing and execution.

mod commands;
pub mod parser;

pub use commands::{BufferOutput, CliOutput, run_cli, run_cli_with_cancel};
