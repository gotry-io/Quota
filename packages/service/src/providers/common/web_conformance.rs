//! The shared statement of what a stored browser session answers.
//!
//! `packages/protocol/fixtures/provider-web-conformance.json` states each case once; this crate
//! and `QuotaProviderWeb` in `packages/apple-client` both answer it, so a rule one runtime starts
//! reading differently fails a test rather than resolving one account into two subscriptions.

use serde_json::Value;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use super::{CollectionContext, ProviderError, QuotaSnapshot, ValidatedBrowserSession};

const FIXTURE: &str = include_str!("../../../../protocol/fixtures/provider-web-conformance.json");

pub struct Exchange {
    pub method: String,
    pub path: String,
    pub status: u16,
    pub body: Vec<u8>,
}

pub struct WebCase {
    pub name: String,
    pub now: String,
    pub cookie_header: String,
    pub source: String,
    pub exchanges: Vec<Exchange>,
    pub validated: Option<Value>,
    pub validated_error: Option<String>,
    pub snapshot: Option<Value>,
    pub snapshot_error: Option<String>,
}

pub fn cases(provider: &str) -> Vec<WebCase> {
    let root: Value = serde_json::from_str(FIXTURE).expect("provider web conformance fixture");
    let source = root["sources"][provider]
        .as_str()
        .expect("provider source")
        .to_owned();
    root["cases"]
        .as_array()
        .expect("cases")
        .iter()
        .filter(|case| case["provider"].as_str() == Some(provider))
        .map(|case| WebCase {
            name: case["name"].as_str().expect("name").to_owned(),
            now: case["now"].as_str().expect("now").to_owned(),
            cookie_header: case["cookie_header"]
                .as_str()
                .expect("cookie header")
                .to_owned(),
            source: source.clone(),
            exchanges: case["exchanges"]
                .as_array()
                .expect("exchanges")
                .iter()
                .map(exchange)
                .collect(),
            validated: case["expect"]["validated"]
                .as_object()
                .map(|value| Value::Object(value.clone())),
            validated_error: case["expect"]["validated"].as_str().map(str::to_owned),
            snapshot: case["expect"]["snapshot"]
                .as_object()
                .map(|value| Value::Object(value.clone())),
            snapshot_error: case["expect"]["snapshot_error"].as_str().map(str::to_owned),
        })
        .collect()
}

fn exchange(value: &Value) -> Exchange {
    let body = match (&value["body"], value["body_base64"].as_str()) {
        (_, Some(encoded)) => {
            use base64::Engine as _;
            base64::engine::general_purpose::STANDARD
                .decode(encoded)
                .expect("exchange body")
        }
        (body, None) if !body.is_null() || value.get("body").is_some() => {
            body.to_string().into_bytes()
        }
        _ => panic!("exchange names no body"),
    };
    Exchange {
        method: value["method"].as_str().expect("method").to_owned(),
        path: value["path"].as_str().expect("path").to_owned(),
        status: value["status"].as_u64().expect("status") as u16,
        body,
    }
}

/// Runs one case twice — once as a validation, once as a reading — against a server that answers
/// the case's queue. An operation that stops early leaves the rest of the queue unused, which is
/// why the server is asked to stop rather than joined on a fixed count.
pub fn assert_case<V, C>(case: &WebCase, validate: V, collect: C)
where
    V: Fn(&str, &CollectionContext, &str) -> Result<ValidatedBrowserSession, ProviderError>,
    C: Fn(&str, &CollectionContext, &str) -> Result<QuotaSnapshot, ProviderError>,
{
    let context = context(&case.now);
    let server = Server::start(&case.exchanges);
    let validated = validate(&case.cookie_header, &context, &server.base);
    let heads = server.finish();
    assert_requests(case, &heads);
    match (validated, &case.validated, &case.validated_error) {
        (Ok(session), Some(expected), _) => {
            assert_eq!(
                Some(session.account_fingerprint.as_str()),
                expected["account_fingerprint"].as_str(),
                "{}",
                case.name
            );
            assert_eq!(
                session.account_label.as_deref(),
                expected["account_label"].as_str(),
                "{}",
                case.name
            );
        }
        (Err(error), _, Some(category)) => {
            assert_eq!(error.category.as_str(), category, "{}", case.name);
            assert_eq!(error.source_id, case.source, "{}", case.name);
        }
        (result, _, _) => panic!("{}: unexpected validation {result:?}", case.name),
    }

    let server = Server::start(&case.exchanges);
    let collected = collect(&case.cookie_header, &context, &server.base);
    let heads = server.finish();
    assert_requests(case, &heads);
    match (collected, &case.snapshot, &case.snapshot_error) {
        (Ok(snapshot), Some(expected), _) => {
            let actual = serde_json::to_value(&snapshot).expect("snapshot");
            assert_eq!(&actual, expected, "{}", case.name);
        }
        (Err(error), _, Some(category)) => {
            assert_eq!(error.category.as_str(), category, "{}", case.name);
            assert_eq!(error.source_id, case.source, "{}", case.name);
        }
        (result, _, _) => panic!("{}: unexpected reading {result:?}", case.name),
    }
}

/// Every request a case made answered the exchange at its own position, and no request carried
/// the stored session anywhere but the `Cookie` header.
fn assert_requests(case: &WebCase, heads: &[String]) {
    assert!(
        heads.len() <= case.exchanges.len(),
        "{}: asked for more exchanges than the case declares",
        case.name
    );
    for (head, exchange) in heads.iter().zip(&case.exchanges) {
        let expected = format!(
            "{} {} ",
            exchange.method.to_ascii_lowercase(),
            exchange.path.to_ascii_lowercase()
        );
        assert!(
            head.starts_with(&expected),
            "{}: expected {expected}, sent {}",
            case.name,
            head.lines().next().unwrap_or_default()
        );
        assert!(
            !head.contains("authorization:"),
            "{}: a stored session was spent as a bearer token",
            case.name
        );
    }
}

fn context(now: &str) -> CollectionContext {
    CollectionContext {
        home_directory: PathBuf::from("/tmp/quota-provider-web-conformance"),
        environment: HashMap::new(),
        config_path: None,
        browser_sessions: HashMap::new(),
        client_name: "QuotaTest".to_owned(),
        client_version: "test".to_owned(),
        now: Some(now.to_owned()),
        cancel: None,
        keychain: Default::default(),
        cli_versions: Default::default(),
        proven_credentials: Default::default(),
    }
}

/// The fixture's queue over a local socket. Unlike [`super::serve_responses`] it is stopped
/// rather than joined on a fixed count, because half these cases refuse a session before they
/// spend every response the provider would have given.
struct Server {
    base: String,
    stop: Arc<AtomicBool>,
    heads: Arc<Mutex<Vec<String>>>,
    handle: Option<std::thread::JoinHandle<()>>,
}

impl Server {
    fn start(exchanges: &[Exchange]) -> Self {
        use std::io::{Read as _, Write as _};
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").expect("listener");
        let base = format!("http://{}", listener.local_addr().expect("address"));
        listener.set_nonblocking(true).expect("nonblocking");
        let responses: Vec<(u16, Vec<u8>)> = exchanges
            .iter()
            .map(|exchange| (exchange.status, exchange.body.clone()))
            .collect();
        let stop = Arc::new(AtomicBool::new(false));
        let heads = Arc::new(Mutex::new(Vec::new()));
        let handle = {
            let stop = Arc::clone(&stop);
            let heads = Arc::clone(&heads);
            std::thread::spawn(move || {
                let mut served = 0;
                while served < responses.len() && !stop.load(Ordering::Acquire) {
                    let (mut stream, _) = match listener.accept() {
                        Ok(connection) => connection,
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                            std::thread::sleep(std::time::Duration::from_millis(2));
                            continue;
                        }
                        Err(_) => break,
                    };
                    stream.set_nonblocking(false).expect("blocking");
                    let mut request = [0_u8; 8_192];
                    let read = stream.read(&mut request).unwrap_or(0);
                    heads
                        .lock()
                        .expect("heads")
                        .push(String::from_utf8_lossy(&request[..read]).to_lowercase());
                    let (status, body) = &responses[served];
                    served += 1;
                    let reason = if (200..300).contains(status) {
                        "OK"
                    } else {
                        "Error"
                    };
                    let _ = write!(
                        stream,
                        "HTTP/1.1 {status} {reason}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        body.len()
                    );
                    let _ = stream.write_all(body);
                }
            })
        };
        Self {
            base,
            stop,
            heads,
            handle: Some(handle),
        }
    }

    fn finish(mut self) -> Vec<String> {
        self.stop.store(true, Ordering::Release);
        if let Some(handle) = self.handle.take() {
            handle.join().expect("server");
        }
        let heads = self.heads.lock().expect("heads").clone();
        heads
    }
}
