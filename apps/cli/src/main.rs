use std::process::ExitCode;
#[cfg(target_os = "linux")]
use std::sync::atomic::{AtomicBool, Ordering};

#[cfg(target_os = "linux")]
use quotacli::run_cli_with_cancel;

#[cfg(target_os = "linux")]
struct StdOutput;

#[cfg(target_os = "linux")]
impl quotacli::CliOutput for StdOutput {
    fn stdout(&mut self, message: &str) {
        println!("{message}");
    }

    fn stderr(&mut self, message: &str) {
        eprintln!("{message}");
    }
}

#[cfg(target_os = "linux")]
static CANCELLED: AtomicBool = AtomicBool::new(false);

#[cfg(target_os = "linux")]
extern "C" fn cancel(_: libc::c_int) {
    CANCELLED.store(true, Ordering::Release);
}

#[cfg(target_os = "linux")]
fn main() -> ExitCode {
    // SAFETY: the handler only performs an atomic store and has static lifetime.
    unsafe {
        libc::signal(libc::SIGINT, cancel as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, cancel as *const () as libc::sighandler_t);
    }

    let mut output = StdOutput;
    let code = run_cli_with_cancel(std::env::args().skip(1), &mut output, &CANCELLED);
    ExitCode::from(code as u8)
}

#[cfg(not(target_os = "linux"))]
fn main() -> ExitCode {
    eprintln!("QuotaCLI is supported on Linux only.");
    ExitCode::from(1)
}
