//! Persistent stdin/stdout NDJSON transport.

use std::io::{self, BufRead, BufReader, BufWriter, Write};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;

use serde_json::from_slice;

use crate::protocol::{
    ErrorCode, IpcError, IpcEvent, IpcReadyEvent, IpcRequest, IpcResponse, MAXIMUM_LINE_BYTES,
    MAXIMUM_REQUEST_ID_BYTES, Operation, RecoveryAction,
};
use crate::service::LocalService;

pub struct JsonLineWriter {
    output: Mutex<Box<dyn Write + Send>>,
}

impl JsonLineWriter {
    pub fn stdout() -> Arc<Self> {
        Self::to(BufWriter::new(io::stdout()))
    }

    fn to(output: impl Write + Send + 'static) -> Arc<Self> {
        Arc::new(Self {
            output: Mutex::new(Box::new(output)),
        })
    }

    /// Says that the local state is open and requests will be read.  QuotaBar holds every
    /// request until it arrives, so it must precede the first response on this stream.
    pub fn ready(&self) {
        self.write_json(&IpcReadyEvent::ready());
    }

    pub fn response(&self, response: &IpcResponse) {
        if !self.write_json(response) {
            let fallback = IpcResponse::error(
                &response.request_id,
                IpcError::new(ErrorCode::Internal, RecoveryAction::Retry),
            );
            let _ = self.write_json(&fallback);
        }
    }

    fn write_json<T: serde::Serialize>(&self, value: &T) -> bool {
        let Ok(encoded) = serde_json::to_vec(value) else {
            return false;
        };
        if encoded.len() > MAXIMUM_LINE_BYTES {
            return false;
        }
        if let Ok(mut output) = self.output.lock() {
            if output.write_all(&encoded).is_err()
                || output.write_all(b"\n").is_err()
                || output.flush().is_err()
            {
                return false;
            }
            return true;
        }
        false
    }
}

impl crate::service::EventSink for JsonLineWriter {
    fn event(&self, event: IpcEvent) {
        self.write_json(&event);
    }
}

/// Announces the open service, starts its schedule, and serves requests until stdin EOF or a
/// `shutdown` operation.  EOF is the parent-lifetime signal: no new work is accepted after it, and
/// the service cancels background tasks before returning.
pub fn run_stdio(service: LocalService, writer: Arc<JsonLineWriter>) -> io::Result<()> {
    run_requests(&mut BufReader::new(io::stdin()), service, writer)
}

/// Reads frames on this thread and runs every operation but `ping` on one worker thread.
///
/// Operations are still serialized, so nothing about the service becomes concurrent.  The split
/// exists so that a request that blocks the worker — a provider round trip, a state lock held by
/// a refresh — cannot also stop the helper from saying that it is alive.
fn run_requests<R: BufRead>(
    input: &mut R,
    service: LocalService,
    writer: Arc<JsonLineWriter>,
) -> io::Result<()> {
    // Open finished before this transport existed.  Say so before anything else — a background
    // event or a response — can reach the stream, and only then let scheduled work begin.
    writer.ready();
    service.start_scheduler();
    let (sender, receiver) = mpsc::channel::<IpcRequest>();
    let worker = thread::Builder::new()
        .name("quota-ipc-worker".to_owned())
        .spawn({
            let service = service.clone();
            let writer = writer.clone();
            move || {
                for request in receiver {
                    let response = service.handle(request);
                    writer.response(&response);
                }
            }
        })?;
    let mut closed_by_request = false;
    while let Some(frame) = read_frame(input)? {
        let line = match frame {
            Ok(line) => line,
            Err(FrameError::TooLong) => {
                writer.response(&IpcResponse::error(
                    "invalid",
                    IpcError::new(ErrorCode::InvalidRequest, RecoveryAction::None),
                ));
                continue;
            }
        };
        let parsed = from_slice::<IpcRequest>(&line)
            .map_err(|_| IpcError::new(ErrorCode::InvalidRequest, RecoveryAction::None));
        let request = match parsed {
            Ok(request) => request,
            Err(error) => {
                writer.response(&IpcResponse::error("invalid", error));
                continue;
            }
        };
        if matches!(request.operation, Operation::Ping) {
            writer.response(&service.handle(request));
            continue;
        }
        closed_by_request = matches!(request.operation, Operation::Shutdown);
        if sender.send(request).is_err() {
            break;
        }
        if closed_by_request {
            break;
        }
    }
    if !closed_by_request {
        service.shutdown();
    }
    drop(sender);
    let _ = worker.join();
    service.shutdown();
    Ok(())
}

/// Keeps the IPC contract usable when the private entry point cannot initialize its local state.
/// It announces itself like a healthy open, because it does answer requests; every one of them
/// gets the same fixed, redacted recovery pair.  The request id is the only caller-provided value
/// copied into a response.
pub fn run_stdio_startup_error(writer: Arc<JsonLineWriter>, error: IpcError) -> io::Result<()> {
    respond_startup_error(&mut BufReader::new(io::stdin()), &writer, &error)
}

fn respond_startup_error<R: BufRead>(
    input: &mut R,
    writer: &JsonLineWriter,
    error: &IpcError,
) -> io::Result<()> {
    writer.ready();
    while let Some(frame) = read_frame(input)? {
        let request_id = match frame {
            Ok(line) => startup_request_id(&line),
            Err(FrameError::TooLong) => "invalid".to_owned(),
        };
        writer.response(&IpcResponse::error(&request_id, error.clone()));
    }
    Ok(())
}

fn startup_request_id(line: &[u8]) -> String {
    let Some(request_id) = serde_json::from_slice::<serde_json::Value>(line)
        .ok()
        .and_then(|value| {
            value
                .get("request_id")
                .and_then(serde_json::Value::as_str)
                .map(str::to_owned)
        })
        .filter(|value| {
            !value.is_empty()
                && value.len() <= MAXIMUM_REQUEST_ID_BYTES
                && value
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"._:-".contains(&byte))
        })
    else {
        return "invalid".to_owned();
    };
    request_id.to_owned()
}

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
enum FrameError {
    TooLong,
}

fn read_frame<R: BufRead>(input: &mut R) -> io::Result<Option<Result<Vec<u8>, FrameError>>> {
    let mut line = Vec::new();
    let mut oversized = false;
    loop {
        let buffer = input.fill_buf()?;
        if buffer.is_empty() {
            if line.is_empty() && !oversized {
                return Ok(None);
            }
            return Ok(Some(if oversized {
                Err(FrameError::TooLong)
            } else {
                Ok(line)
            }));
        }
        let newline = buffer.iter().position(|byte| *byte == b'\n');
        let consumed = newline.map_or(buffer.len(), |index| index + 1);
        if !oversized {
            let payload_len = newline.unwrap_or(buffer.len());
            if line.len().saturating_add(payload_len) > MAXIMUM_LINE_BYTES {
                oversized = true;
            } else {
                line.extend_from_slice(&buffer[..payload_len]);
            }
        }
        input.consume(consumed);
        if newline.is_some() {
            return Ok(Some(if oversized {
                Err(FrameError::TooLong)
            } else {
                Ok(line)
            }));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::DiagnosticReport;
    use crate::service::{BackendError, LocalBackend, LoginOutcome, RefreshOutcome, RefreshSink};
    use crate::state::StateStore;
    use std::io::Cursor;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::{Duration, Instant};
    use uuid::Uuid;

    /// Collects the helper's stdout where the test — and a backend standing in for a long
    /// operation — can read it while the transport is still running.
    #[derive(Clone, Default)]
    struct SharedOutput(Arc<Mutex<Vec<u8>>>);

    impl SharedOutput {
        fn lines(&self) -> Vec<String> {
            String::from_utf8(self.0.lock().expect("output").clone())
                .expect("utf8")
                .lines()
                .map(str::to_owned)
                .collect()
        }
    }

    impl Write for SharedOutput {
        fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
            self.0.lock().expect("output").extend_from_slice(buffer);
            Ok(buffer.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    /// Holds the worker inside one operation until the ping it is blocking has been answered.
    struct BlockingDiagnoseBackend {
        output: SharedOutput,
        answered_ping: Arc<AtomicBool>,
    }

    impl LocalBackend for BlockingDiagnoseBackend {
        fn refresh(&self, _: Arc<AtomicBool>, _: &dyn RefreshSink, _: bool) -> RefreshOutcome {
            RefreshOutcome {
                quota: Err(BackendError::unavailable()),
                usage: Err(BackendError::unavailable()),
                account: Err(BackendError::unavailable()),
                pricing: Err(BackendError::unavailable()),
                overview: None,
            }
        }

        fn diagnose(&self) -> Result<DiagnosticReport, BackendError> {
            let deadline = Instant::now() + Duration::from_secs(10);
            while Instant::now() < deadline {
                if self
                    .output
                    .lines()
                    .iter()
                    .any(|line| line.contains("\"ok\":true"))
                {
                    self.answered_ping.store(true, Ordering::Release);
                    break;
                }
                thread::sleep(Duration::from_millis(5));
            }
            Err(BackendError::unavailable())
        }

        fn login(&self, _: &str, _: Arc<AtomicBool>) -> Result<LoginOutcome, BackendError> {
            Err(BackendError::unavailable())
        }

        fn logout(&self, _: &serde_json::Value) -> Result<(), BackendError> {
            Err(BackendError::unavailable())
        }

        fn validate_provider_browser_session(
            &self,
            _: crate::catalog::ProviderId,
            _: &str,
        ) -> Result<crate::providers::ValidatedBrowserSession, BackendError> {
            Err(BackendError::unavailable())
        }
    }

    fn request_line(request_id: &str, operation: &str) -> String {
        format!(
            "{{\"type\":\"request\",\"request_id\":\"{request_id}\",\"operation\":\"{operation}\",\"payload\":{{}}}}\n"
        )
    }

    #[test]
    fn ready_precedes_every_response_and_ping_answers_during_a_long_operation() {
        let root = std::env::temp_dir().join(format!("quota-ipc-{}", Uuid::new_v4()));
        let state = Arc::new(StateStore::open(root.clone()).expect("state"));
        let output = SharedOutput::default();
        let writer = JsonLineWriter::to(output.clone());
        let answered_ping = Arc::new(AtomicBool::new(false));
        let service = LocalService::new(
            state,
            writer.clone(),
            Arc::new(BlockingDiagnoseBackend {
                output: output.clone(),
                answered_ping: answered_ping.clone(),
            }),
        );

        // `shutdown` closes the stream instead of EOF: EOF is the parent-lifetime signal and
        // would cancel the queued operation before the worker could start it.
        let input = format!(
            "{}{}{}",
            request_line("slow", "diagnose"),
            request_line("alive", "ping"),
            request_line("bye", "shutdown")
        );
        run_requests(&mut Cursor::new(input.into_bytes()), service, writer).expect("transport");
        let _ = std::fs::remove_dir_all(&root);

        let lines = output.lines();
        assert_eq!(
            lines[0], r#"{"type":"event","event":"ready","ipc_version":1}"#,
            "ready must be the first line on the stream"
        );
        assert!(
            answered_ping.load(Ordering::Acquire),
            "ping was not answered while diagnose held the worker"
        );
        let responses = lines
            .iter()
            .filter(|line| line.contains(r#""type":"response""#))
            .collect::<Vec<_>>();
        assert!(responses[0].contains(r#""request_id":"alive""#));
        assert!(responses[0].contains(r#""ok":true"#));
        assert!(responses[1].contains(r#""request_id":"slow""#));
    }

    #[test]
    fn startup_failure_announces_itself_and_answers_every_request() {
        let output = SharedOutput::default();
        let writer = JsonLineWriter::to(output.clone());
        let input = format!(
            "{}{}",
            request_line("r1", "get_state"),
            request_line("r2", "ping")
        );

        respond_startup_error(
            &mut Cursor::new(input.into_bytes()),
            &writer,
            &IpcError::new(ErrorCode::ClientUpgradeRequired, RecoveryAction::Upgrade),
        )
        .expect("transport");

        let lines = output.lines();
        assert_eq!(
            lines[0],
            r#"{"type":"event","event":"ready","ipc_version":1}"#
        );
        assert!(lines[1].contains(r#""request_id":"r1""#));
        assert!(lines[1].contains(r#""code":"client_upgrade_required""#));
        assert!(lines[2].contains(r#""request_id":"r2""#));
    }

    #[test]
    fn writer_does_not_change_wire_types() {
        let response = IpcResponse::error(
            "r1",
            IpcError::new(ErrorCode::InvalidRequest, RecoveryAction::None),
        );
        let encoded = serde_json::to_string(&response).expect("response");
        assert!(encoded.contains("\"type\":\"response\""));
        assert!(encoded.contains("\"recovery_action\":\"none\""));
    }

    #[test]
    fn oversized_frame_is_discarded_without_poisoning_the_next_request() {
        let mut bytes = vec![b'x'; MAXIMUM_LINE_BYTES + 1];
        bytes.push(b'\n');
        bytes.extend_from_slice(b"{}\n");
        let mut input = io::BufReader::new(Cursor::new(bytes));
        assert!(matches!(
            read_frame(&mut input).expect("frame"),
            Some(Err(FrameError::TooLong))
        ));
        assert_eq!(
            read_frame(&mut input).expect("frame"),
            Some(Ok(b"{}".to_vec()))
        );
    }

    #[test]
    fn maximum_sized_frame_excludes_delimiter_and_invalid_utf8_stays_invalid() {
        let mut maximum = vec![b'x'; MAXIMUM_LINE_BYTES];
        maximum.push(b'\n');
        let mut input = io::BufReader::new(Cursor::new(maximum));
        assert_eq!(
            read_frame(&mut input).expect("maximum frame"),
            Some(Ok(vec![b'x'; MAXIMUM_LINE_BYTES]))
        );

        assert!(serde_json::from_slice::<IpcRequest>(b"{\"type\":\"requ\xFFst\"}").is_err());
    }

    #[test]
    fn startup_error_only_echoes_a_bounded_request_id() {
        assert_eq!(startup_request_id(br#"{"request_id":"r1"}"#), "r1");
        assert_eq!(
            startup_request_id(br#"{"request_id":"/private/path"}"#),
            "invalid"
        );
        assert_eq!(startup_request_id(br#"{"request_id":123}"#), "invalid");
    }
}
