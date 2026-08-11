//! Persistent stdin/stdout NDJSON transport.

use std::io::{self, BufRead, BufReader, BufWriter, Write};
use std::sync::{Arc, Mutex};

use serde_json::from_slice;

use crate::protocol::{
    ErrorCode, IpcError, IpcEvent, IpcRequest, IpcResponse, MAXIMUM_LINE_BYTES,
    MAXIMUM_REQUEST_ID_BYTES, RecoveryAction,
};
use crate::service::LocalService;

pub struct JsonLineWriter {
    output: Mutex<BufWriter<io::Stdout>>,
}

impl JsonLineWriter {
    pub fn stdout() -> Arc<Self> {
        Arc::new(Self {
            output: Mutex::new(BufWriter::new(io::stdout())),
        })
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

/// Runs until stdin EOF or a `shutdown` operation.  EOF is the parent-lifetime signal: no new
/// work is accepted after it, and the service cancels background tasks before returning.
pub fn run_stdio(service: LocalService, writer: Arc<JsonLineWriter>) -> io::Result<()> {
    let stdin = io::stdin();
    let mut input = BufReader::new(stdin);
    loop {
        let frame = read_frame(&mut input)?;
        let Some(frame) = frame else {
            service.shutdown();
            break;
        };
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
        let response = service.handle(request);
        let should_shutdown = service.is_shutdown();
        writer.response(&response);
        if should_shutdown {
            break;
        }
    }
    service.shutdown();
    Ok(())
}

/// Keeps the IPC contract usable when the private entry point cannot initialize its local state.
/// The request id is the only caller-provided value copied into the response; all failure details
/// are a fixed, redacted recovery pair.
pub fn run_stdio_startup_error(writer: Arc<JsonLineWriter>, error: IpcError) -> io::Result<()> {
    let stdin = io::stdin();
    let mut input = BufReader::new(stdin);
    let frame = read_frame(&mut input)?;
    let Some(frame) = frame else { return Ok(()) };
    let request_id = match frame {
        Ok(line) => startup_request_id(&line),
        Err(FrameError::TooLong) => "invalid".to_owned(),
    };
    writer.response(&IpcResponse::error(&request_id, error));
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
    use std::io::Cursor;

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
