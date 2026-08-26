use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{Arc, atomic::AtomicBool, mpsc};
use std::thread;
use std::time::{Duration, Instant};

pub const LOCAL_FILE_LIMIT: usize = 1_048_576;

/// Run a helper that answers once — the macOS Keychain lookup, a `--version` read — without
/// allowing it to retain an unbounded stdout buffer or to outlive the collection
/// request. Stderr is discarded; it is never an implicit data channel.
pub fn run_bounded_command(
    mut command: Command,
    timeout: Duration,
    cancel: Option<&Arc<AtomicBool>>,
    output_limit: usize,
) -> Option<Vec<u8>> {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let Some(stdout) = child.stdout.take() else {
        let _ = child.kill();
        let _ = child.wait();
        return None;
    };
    let (sender, receiver) = mpsc::sync_channel(1);
    thread::spawn(move || {
        let mut output = Vec::new();
        let result = stdout
            .take(output_limit.saturating_add(1) as u64)
            .read_to_end(&mut output)
            .map(|_| output);
        let _ = sender.send(result.ok());
    });

    let started = std::time::Instant::now();
    let mut output = None;
    loop {
        if cancel
            .map(|value| value.load(std::sync::atomic::Ordering::Acquire))
            .unwrap_or(false)
        {
            let _ = child.kill();
            let _ = child.wait();
            return None;
        }
        if output.is_none() {
            match receiver.try_recv() {
                Ok(Some(bytes)) => {
                    if bytes.len() > output_limit {
                        let _ = child.kill();
                        let _ = child.wait();
                        return None;
                    }
                    output = Some(bytes);
                }
                Ok(None) | Err(mpsc::TryRecvError::Disconnected) => return None,
                Err(mpsc::TryRecvError::Empty) => {}
            }
        }
        match child.try_wait() {
            Ok(Some(status)) => {
                let output = output
                    .or_else(|| receiver.recv_timeout(Duration::from_secs(1)).ok().flatten())?;
                if !status.success() {
                    return None;
                }
                return Some(output);
            }
            Ok(None) if started.elapsed() < timeout => {
                thread::sleep(Duration::from_millis(25));
            }
            Ok(None) | Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
}

/// A child driven turn by turn over newline-delimited stdio, under the bounds
/// [`run_bounded_command`] puts on a helper that answers once: a single deadline for the whole
/// exchange, a cap on everything the child may print, discarded stderr, and a kill when either
/// is reached or the refresh is cancelled.
///
/// A handshake cannot be a one-shot run, because its second request names something the first
/// reply carried. The deadline is absolute rather than per-turn, so no number of turns can
/// extend it, and dropping the exchange closes stdin, gives the child what is left of the
/// deadline to leave, and kills it if it does not.
pub struct BoundedExchange {
    child: Child,
    stdin: Option<ChildStdin>,
    lines: mpsc::Receiver<Vec<u8>>,
    deadline: Instant,
    cancel: Option<Arc<AtomicBool>>,
}

impl BoundedExchange {
    pub fn start(
        mut command: Command,
        timeout: Duration,
        cancel: Option<&Arc<AtomicBool>>,
        output_limit: usize,
    ) -> Option<Self> {
        let deadline = Instant::now() + timeout;
        let mut child = command
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .ok()?;
        let (Some(stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else {
            let _ = child.kill();
            let _ = child.wait();
            return None;
        };
        let (sender, lines) = mpsc::channel();
        thread::spawn(move || {
            // The cap is on the reader itself, so a child that prints one endless line cannot
            // grow a buffer past it while a length check waits for a newline that never comes.
            let mut reader = BufReader::new(stdout.take(output_limit as u64));
            loop {
                let mut line = Vec::new();
                match reader.read_until(b'\n', &mut line) {
                    Ok(0) | Err(_) => return,
                    Ok(_) => {
                        if sender.send(line).is_err() {
                            return;
                        }
                    }
                }
            }
        });
        Some(Self {
            child,
            stdin: Some(stdin),
            lines,
            deadline,
            cancel: cancel.cloned(),
        })
    }

    /// Writes one request line. `false` once the child has stopped reading.
    pub fn send(&mut self, line: &str) -> bool {
        let Some(stdin) = self.stdin.as_mut() else {
            return false;
        };
        stdin.write_all(line.as_bytes()).is_ok()
            && stdin.write_all(b"\n").is_ok()
            && stdin.flush().is_ok()
    }

    /// The next line the child printed, or `None` once the deadline, a cancelled refresh, the
    /// output cap, or the child's own exit ends the exchange.
    pub fn receive(&mut self) -> Option<Vec<u8>> {
        loop {
            if self.expired() {
                return None;
            }
            match self.lines.recv_timeout(Duration::from_millis(25)) {
                Ok(line) => return Some(line),
                Err(mpsc::RecvTimeoutError::Timeout) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => return None,
            }
        }
    }

    fn expired(&self) -> bool {
        Instant::now() >= self.deadline
            || self
                .cancel
                .as_ref()
                .is_some_and(|cancel| cancel.load(std::sync::atomic::Ordering::Acquire))
    }
}

impl Drop for BoundedExchange {
    fn drop(&mut self) {
        // Closing stdin is how a stdio server is told the conversation is over. It gets
        // whatever is left of the one deadline to act on that.
        self.stdin = None;
        loop {
            match self.child.try_wait() {
                Ok(Some(_)) => return,
                Ok(None) if !self.expired() => thread::sleep(Duration::from_millis(25)),
                _ => break,
            }
        }
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

pub fn read_bounded_file(path: &Path, limit: usize) -> Option<Vec<u8>> {
    read_bounded_file_inner(path, limit, false)
}

pub(super) fn read_bounded_file_inner(
    path: &Path,
    limit: usize,
    owner_only: bool,
) -> Option<Vec<u8>> {
    #[cfg(unix)]
    let file = {
        use std::os::unix::fs::OpenOptionsExt;
        fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)
            .ok()?
    };
    #[cfg(not(unix))]
    let file = fs::File::open(path).ok()?;

    // Validate the descriptor that will actually be read. The path may have been replaced
    // between discovery and open; O_NOFOLLOW plus fstat-style metadata avoids consuming a
    // swapped-in symlink or a file that exceeds the bound/permissions.
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() || metadata.len() > limit as u64 {
        return None;
    }
    #[cfg(unix)]
    if owner_only {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o077 != 0 {
            return None;
        }
    }
    let mut bytes = Vec::new();
    file.take(limit.saturating_add(1) as u64)
        .read_to_end(&mut bytes)
        .ok()?;
    (bytes.len() <= limit).then_some(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::Ordering;

    fn temp_path(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!("quota-provider-{name}-{}", uuid::Uuid::new_v4()))
    }

    #[test]
    fn bounded_command_stops_on_timeout_and_cancellation() {
        #[cfg(unix)]
        {
            let command = {
                let mut command = Command::new("/bin/sh");
                command.args(["-c", "while :; do :; done"]);
                command
            };
            assert!(run_bounded_command(command, Duration::from_millis(100), None, 1024).is_none());

            let cancelled = Arc::new(AtomicBool::new(true));
            let command = {
                let mut command = Command::new("/bin/sh");
                command.args(["-c", "while :; do :; done"]);
                command
            };
            assert!(
                run_bounded_command(command, Duration::from_secs(1), Some(&cancelled), 1024)
                    .is_none()
            );
            assert!(cancelled.load(Ordering::Acquire));
        }
    }

    /// The deadline covers the whole conversation, not each turn, and outliving it is not a
    /// way to keep a provider CLI running past the refresh that started it.
    #[test]
    fn a_bounded_exchange_answers_in_turn_and_dies_on_its_deadline() {
        #[cfg(unix)]
        {
            let mut command = Command::new("/bin/sh");
            command.args(["-c", "while read -r line; do echo \"got $line\"; done"]);
            let mut exchange =
                BoundedExchange::start(command, Duration::from_secs(5), None, 1024).expect("start");
            assert!(exchange.send("first"));
            assert_eq!(exchange.receive().as_deref(), Some(&b"got first\n"[..]));
            assert!(exchange.send("second"));
            assert_eq!(exchange.receive().as_deref(), Some(&b"got second\n"[..]));
            drop(exchange);

            // A child that never answers holds the exchange for the deadline and no longer,
            // and a cancelled refresh does not even wait that long.
            let mut command = Command::new("/bin/sh");
            command.args(["-c", "sleep 30"]);
            let mut exchange =
                BoundedExchange::start(command, Duration::from_millis(150), None, 1024)
                    .expect("start");
            let started = std::time::Instant::now();
            assert!(exchange.receive().is_none());
            drop(exchange);
            assert!(started.elapsed() < Duration::from_secs(5));

            let cancelled = Arc::new(AtomicBool::new(true));
            let mut command = Command::new("/bin/sh");
            command.args(["-c", "sleep 30"]);
            let mut exchange =
                BoundedExchange::start(command, Duration::from_secs(30), Some(&cancelled), 1024)
                    .expect("start");
            let started = std::time::Instant::now();
            assert!(exchange.receive().is_none());
            drop(exchange);
            assert!(started.elapsed() < Duration::from_secs(5));

            // Everything the child may print is capped, however it is split into lines.
            let mut command = Command::new("/bin/sh");
            command.args(["-c", "yes wordy"]);
            let mut exchange =
                BoundedExchange::start(command, Duration::from_secs(5), None, 64).expect("start");
            let mut read = 0;
            while let Some(line) = exchange.receive() {
                read += line.len();
            }
            assert_eq!(read, 64);
        }
    }

    #[test]
    fn bounded_credentials_reject_symlinks_and_oversized_files() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;
            let target = temp_path("credential-target");
            let link = temp_path("credential-link");
            fs::write(&target, b"small").unwrap();
            symlink(&target, &link).unwrap();
            assert!(read_bounded_file(&link, 1024).is_none());

            let oversized = temp_path("credential-oversized");
            fs::write(&oversized, vec![b'x'; 1025]).unwrap();
            assert!(read_bounded_file(&oversized, 1024).is_none());
            let _ = fs::remove_file(target);
            let _ = fs::remove_file(link);
            let _ = fs::remove_file(oversized);
        }
    }
}
