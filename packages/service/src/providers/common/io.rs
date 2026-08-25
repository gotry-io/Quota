use std::fs;
use std::io::Read;
use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::{Arc, atomic::AtomicBool, mpsc};
use std::thread;
use std::time::Duration;

pub const LOCAL_FILE_LIMIT: usize = 1_048_576;

/// Run the one helper collection still starts — the macOS Keychain lookup — without
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
