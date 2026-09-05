//! grok.com's own gRPC-web billing RPC.
//!
//! Two rungs share it. With the local OAuth access token it is the rung after the CLI proxy:
//! it needs no credential the proxy did not already have, and it answers when
//! `cli-chat-proxy.grok.com` cannot be reached at all. With a stored grok.com cookie it is
//! the last rung of the ladder, reached only when this Mac holds no Grok grant or the one it
//! holds was refused.

use std::time::Duration;

use crate::catalog::ProviderId;

use super::super::common::{
    Cadence, CollectionContext, ErrorCategory, HTTP_TIMEOUT, HttpClient, ProviderError,
    QuotaAccount, QuotaSnapshot, QuotaWindow, VALIDATION_TIMEOUT, ValidatedBrowserSession,
    account_identity, clamp_percent, cookie_named_value, jwt_subject,
};

pub const RPC_SOURCE: &str = "grok_billing_rpc";
/// The same RPC, reached with the browser's cookie rather than the CLI's token.
pub const WEB_SOURCE: &str = "grok_web_billing_api";
const BILLING_RPC_URL: &str = "https://grok.com/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig";
const GRPC_EMPTY_FRAME: &[u8] = &[0x00, 0x00, 0x00, 0x00, 0x00];
/// What a stored Grok session is called, since the RPC names nobody.
const WEB_ACCOUNT_LABEL: &str = "Grok";

/// How this request says who it is, and which rung a failure belongs to.
enum Auth<'a> {
    Bearer(&'a str),
    Cookie(&'a str),
}

impl Auth<'_> {
    fn header(&self) -> (&'static str, &str) {
        match self {
            Self::Bearer(value) => ("Authorization", value),
            Self::Cookie(value) => ("Cookie", value),
        }
    }

    fn source(&self) -> &'static str {
        match self {
            Self::Bearer(_) => RPC_SOURCE,
            Self::Cookie(_) => WEB_SOURCE,
        }
    }
}

/// The billing-cycle window from grok.com's gRPC-web billing RPC using the local
/// OAuth access token. CodexBar's last Automatic step.
pub(super) fn bearer_billing_window(
    access_token: &str,
    context: &CollectionContext,
) -> Result<QuotaWindow, ProviderError> {
    let bearer = format!("Bearer {access_token}");
    let billing = fetch_billing(
        &Auth::Bearer(&bearer),
        context,
        BILLING_RPC_URL,
        HTTP_TIMEOUT,
    )?;
    Ok(billing_window(&billing, context.observed_unix()))
}

/// Proves the cookie belongs to a signed-in grok.com account before anything is stored.
///
/// The RPC names nobody, so a clean answer is the whole proof: grok.com refuses a session it
/// does not recognise with a gRPC status this build reads as `auth_required`, and it refuses
/// one whose team has no billing with `unsupported`. Either way nothing is kept.
pub(super) fn validate_browser_session(
    cookie_header: &str,
    context: &CollectionContext,
) -> Result<ValidatedBrowserSession, ProviderError> {
    validate_at(cookie_header, context, BILLING_RPC_URL)
}

fn validate_at(
    cookie_header: &str,
    context: &CollectionContext,
    url: &str,
) -> Result<ValidatedBrowserSession, ProviderError> {
    sso_token(cookie_header).ok_or_else(|| ProviderError::new(ErrorCategory::Error, WEB_SOURCE))?;
    let _ = fetch_billing(
        &Auth::Cookie(cookie_header),
        context,
        url,
        VALIDATION_TIMEOUT,
    )?;
    let (account_fingerprint, _) = web_account_identity(cookie_header);
    Ok(ValidatedBrowserSession {
        cookie_header: cookie_header.to_owned(),
        account_fingerprint,
        account_label: Some(WEB_ACCOUNT_LABEL.to_owned()),
    })
}

pub(super) fn collect(
    context: &CollectionContext,
    cookie_header: &str,
) -> Result<QuotaSnapshot, ProviderError> {
    collect_at(cookie_header, context, BILLING_RPC_URL)
}

fn collect_at(
    cookie_header: &str,
    context: &CollectionContext,
    url: &str,
) -> Result<QuotaSnapshot, ProviderError> {
    sso_token(cookie_header).ok_or_else(|| ProviderError::new(ErrorCategory::Error, WEB_SOURCE))?;
    let billing = fetch_billing(&Auth::Cookie(cookie_header), context, url, HTTP_TIMEOUT)?;
    let (fingerprint, scope) = web_account_identity(cookie_header);
    Ok(QuotaSnapshot {
        provider: ProviderId::Grok,
        account: QuotaAccount {
            fingerprint,
            fingerprint_scope: scope,
            label: Some(WEB_ACCOUNT_LABEL.to_owned()),
            plan: None,
        },
        windows: vec![billing_window(&billing, context.observed_unix())],
        status: "available",
        observed_at: context.observed_at(),
    })
}

/// Whose grok.com account a stored session speaks for.
///
/// The RPC names nobody, so the sign-in cookie has to: it is a JWT, and the subject it carries
/// is what tells two signed-in accounts apart. A cookie that names no one keeps the
/// source-wide fingerprint, which says exactly that.
fn web_account_identity(cookie_header: &str) -> (String, &'static str) {
    let owner = sso_token(cookie_header).and_then(jwt_subject);
    account_identity("grok", "user_id", owner.as_deref())
}

/// The one cookie that is a whole grok.com sign-in. `sso-rw` is the same session's
/// read-write half, so either alone names it.
fn sso_token(header: &str) -> Option<&str> {
    cookie_named_value(header, "sso")
        .or_else(|| cookie_named_value(header, "sso-rw"))
        .map(str::trim)
        .filter(|value| {
            !value.is_empty() && value.len() <= 8_192 && !value.chars().any(char::is_control)
        })
}

fn fetch_billing(
    auth: &Auth<'_>,
    context: &CollectionContext,
    url: &str,
    timeout: Duration,
) -> Result<Billing, ProviderError> {
    let source = auth.source();
    if context.cancelled() {
        return Err(ProviderError::new(ErrorCategory::Unavailable, source));
    }
    let client = HttpClient::with_timeout(timeout)?;
    let user_agent = context.user_agent();
    let headers = [
        auth.header(),
        ("Origin", "https://grok.com"),
        ("Referer", "https://grok.com/?_s=usage"),
        ("Accept", "*/*"),
        ("Content-Type", "application/grpc-web+proto"),
        ("x-grpc-web", "1"),
        ("x-user-agent", "connect-es/2.1.1"),
        ("User-Agent", user_agent.as_str()),
    ];
    let (_, body) = client.post_bytes(url, &headers, GRPC_EMPTY_FRAME, source)?;
    parse_grpc_web_billing(&body, context.observed_unix(), source)
}

#[derive(Debug)]
struct Billing {
    used_percent: f64,
    resets_at: Option<i64>,
}

/// The RPC exposes only the reset instant, not the cadence. A reset 20–45 days out
/// reads as monthly; anything nearer is the weekly credit pool, even late in the
/// week (CodexBar's untyped-window rule), and no reset at all stays generic.
///
/// That heuristic names the window for a person to read. It does not name the headline meter:
/// `primary_cadence` is the field a client trusts *instead of* reading a title, so only a reset
/// that actually lands inside a cadence earns one. A reset the bands do not cover keeps its
/// guessed title and stays unnamed, the way an untyped period does in `map_billing`.
fn billing_window(billing: &Billing, now: i64) -> QuotaWindow {
    let delta = billing.resets_at.and_then(|end| end.checked_sub(now));
    let (title, primary_cadence) = match delta {
        Some(seconds) if (20 * 86_400..=45 * 86_400).contains(&seconds) => {
            (Cadence::Monthly.title(), Some(Cadence::Monthly))
        }
        Some(seconds) if seconds <= 10 * 86_400 => (Cadence::Weekly.title(), Some(Cadence::Weekly)),
        // Still titled by the guess, deliberately unnamed: a title is a word, a cadence is a claim.
        Some(_) => (Cadence::Weekly.title(), None),
        None => ("Billing Cycle", None),
    };
    QuotaWindow {
        id: "billing_cycle".to_owned(),
        title: title.to_owned(),
        used_percent: clamp_percent(billing.used_percent),
        resets_at: billing
            .resets_at
            .map(super::super::common::unix_seconds_to_iso),
        duration_seconds: None,
        primary_cadence,
        remaining_value: None,
        limit_value: None,
        value_unit: None,
    }
}

fn parse_grpc_web_billing(
    data: &[u8],
    now: i64,
    source: &'static str,
) -> Result<Billing, ProviderError> {
    let trailers = grpc_web_trailer_fields(data);
    if let Some(status) = trailers
        .get("grpc-status")
        .and_then(|value| value.parse::<i32>().ok())
        && status != 0
    {
        let message = trailers
            .get("grpc-message")
            .map(String::as_str)
            .unwrap_or("");
        return Err(grpc_status_error(status, message, source));
    }
    let mut payloads = grpc_web_data_frames(data);
    if payloads.is_empty() && looks_like_protobuf(data) {
        payloads.push(data.to_vec());
    }
    if payloads.is_empty() {
        return Err(ProviderError::new(ErrorCategory::Error, source));
    }
    let mut scan = ProtobufScan::default();
    for payload in &payloads {
        scan.merge(&scan_protobuf(payload, 0, &[]));
    }
    let parsed_percent = scan
        .fixed32
        .iter()
        .filter(|field| {
            field.path.last() == Some(&1)
                && field.value.is_finite()
                && (0.0..=100.0).contains(&field.value)
        })
        .min_by(|lhs, rhs| {
            lhs.path
                .len()
                .cmp(&rhs.path.len())
                .then(lhs.order.cmp(&rhs.order))
        })
        .map(|field| field.value as f64);
    let reset_fields = scan
        .varints
        .iter()
        .filter_map(|field| {
            let raw = field.value;
            (1_700_000_000..=2_100_000_000)
                .contains(&raw)
                .then_some((field.path.as_slice(), raw as i64))
        })
        .collect::<Vec<_>>();
    let future = reset_fields
        .iter()
        .copied()
        .filter(|(_, date)| *date > now)
        .collect::<Vec<_>>();
    let reset = future
        .iter()
        .find(|(path, _)| *path == [1, 5, 1])
        .or(future.first())
        .map(|(_, date)| *date);
    let has_usage_period = scan.varints.iter().any(|field| {
        field.path.starts_with(&[1, 6]) || (field.path == [1, 8, 1] && matches!(field.value, 1 | 2))
    });
    let percent = match parsed_percent {
        Some(value) => value,
        None if reset.is_some() && has_usage_period && scan.fixed32.is_empty() => 0.0,
        None => return Err(ProviderError::new(ErrorCategory::Error, source)),
    };
    Ok(Billing {
        used_percent: percent,
        resets_at: reset,
    })
}

fn grpc_status_error(status: i32, message: &str, source: &'static str) -> ProviderError {
    let lower = message.to_ascii_lowercase();
    if status == 16
        || (status == 7
            && (lower.contains("unauthenticated")
                || lower.contains("bad-credentials")
                || lower.contains("no-credentials")
                || lower.contains("no credentials")))
    {
        return ProviderError::new(ErrorCategory::AuthRequired, source);
    }
    if status == 9 && lower.contains("no personal team") {
        return ProviderError::new(ErrorCategory::Unsupported, source);
    }
    if status == 4 || status == 14 {
        return ProviderError::new(ErrorCategory::Unavailable, source);
    }
    ProviderError::new(ErrorCategory::Error, source)
}

fn grpc_web_data_frames(data: &[u8]) -> Vec<Vec<u8>> {
    let mut frames = Vec::new();
    let mut index = 0;
    while index + 5 <= data.len() {
        let flags = data[index];
        let length = u32::from_be_bytes([
            data[index + 1],
            data[index + 2],
            data[index + 3],
            data[index + 4],
        ]) as usize;
        let start = index + 5;
        let end = start.saturating_add(length);
        if end > data.len() {
            return Vec::new();
        }
        if flags & 0x80 == 0 {
            frames.push(data[start..end].to_vec());
        }
        index = end;
    }
    frames
}

fn grpc_web_trailer_fields(data: &[u8]) -> std::collections::BTreeMap<String, String> {
    let mut fields = std::collections::BTreeMap::new();
    let mut index = 0;
    while index + 5 <= data.len() {
        let flags = data[index];
        let length = u32::from_be_bytes([
            data[index + 1],
            data[index + 2],
            data[index + 3],
            data[index + 4],
        ]) as usize;
        let start = index + 5;
        let end = start.saturating_add(length);
        if end > data.len() {
            break;
        }
        if flags & 0x80 != 0
            && let Ok(text) = std::str::from_utf8(&data[start..end])
        {
            for line in text.split(['\n', '\r']) {
                let Some((key, value)) = line.split_once(':') else {
                    continue;
                };
                fields.insert(key.trim().to_ascii_lowercase(), value.trim().to_owned());
            }
        }
        index = end;
    }
    fields
}

fn looks_like_protobuf(data: &[u8]) -> bool {
    let Some(first) = data.first() else {
        return false;
    };
    let field_number = first >> 3;
    let wire_type = first & 0x07;
    field_number > 0 && matches!(wire_type, 0 | 1 | 2 | 5)
}

#[derive(Clone, Debug, Default)]
struct ProtobufScan {
    fixed32: Vec<Fixed32Field>,
    varints: Vec<VarintField>,
}

#[derive(Clone, Debug)]
struct Fixed32Field {
    path: Vec<u64>,
    value: f32,
    order: usize,
}

#[derive(Clone, Debug)]
struct VarintField {
    path: Vec<u64>,
    value: u64,
}

impl ProtobufScan {
    fn merge(&mut self, other: &Self) {
        self.fixed32.extend(other.fixed32.iter().cloned());
        self.varints.extend(other.varints.iter().cloned());
    }
}

fn scan_protobuf(data: &[u8], depth: usize, path: &[u64]) -> ProtobufScan {
    let mut scan = ProtobufScan::default();
    let mut index = 0;
    let mut order = 0;
    while index < data.len() {
        let field_start = index;
        let Some(key) = read_varint(data, &mut index) else {
            break;
        };
        if key == 0 {
            index = field_start + 1;
            continue;
        }
        let field_number = key >> 3;
        let wire_type = key & 0x07;
        let mut field_path = path.to_vec();
        field_path.push(field_number);
        match wire_type {
            0 => {
                if let Some(value) = read_varint(data, &mut index) {
                    scan.varints.push(VarintField {
                        path: field_path,
                        value,
                    });
                } else {
                    index = field_start + 1;
                }
            }
            1 => {
                if index + 8 > data.len() {
                    break;
                }
                index += 8;
            }
            2 => {
                let Some(length) = read_varint(data, &mut index) else {
                    index = field_start + 1;
                    continue;
                };
                let start = index;
                let end = index.saturating_add(length as usize);
                if end > data.len() {
                    index = field_start + 1;
                    continue;
                }
                if depth < 4 {
                    scan.merge(&scan_protobuf(&data[start..end], depth + 1, &field_path));
                }
                index = end;
            }
            5 => {
                if index + 4 > data.len() {
                    break;
                }
                let bits = u32::from_le_bytes([
                    data[index],
                    data[index + 1],
                    data[index + 2],
                    data[index + 3],
                ]);
                scan.fixed32.push(Fixed32Field {
                    path: field_path,
                    value: f32::from_bits(bits),
                    order,
                });
                order += 1;
                index += 4;
            }
            _ => index = field_start + 1,
        }
    }
    scan
}

fn read_varint(data: &[u8], index: &mut usize) -> Option<u64> {
    let mut value = 0_u64;
    let mut shift = 0;
    while *index < data.len() && shift < 64 {
        let byte = data[*index];
        *index += 1;
        value |= u64::from(byte & 0x7f) << shift;
        if byte & 0x80 == 0 {
            return Some(value);
        }
        shift += 7;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::path::PathBuf;

    fn context() -> CollectionContext {
        CollectionContext {
            home_directory: PathBuf::from("/tmp/quota-grok-web-missing-home"),
            environment: HashMap::new(),
            config_path: None,
            browser_sessions: HashMap::new(),
            client_name: "QuotaTest".to_owned(),
            client_version: "test".to_owned(),
            now: Some("2026-08-10T00:00:00Z".to_owned()),
            cancel: None,
            keychain: Default::default(),
            cli_versions: Default::default(),
            proven_credentials: Default::default(),
        }
    }

    /// A data frame carrying one `fixed32` percent, framed the way grpc-web frames it.
    fn percent_frame(percent: f32) -> Vec<u8> {
        let mut bytes = vec![0x0d];
        bytes.extend_from_slice(&percent.to_le_bytes());
        let mut frame = vec![0x00];
        frame.extend_from_slice(&(bytes.len() as u32).to_be_bytes());
        frame.append(&mut bytes);
        frame
    }

    fn trailer_frame(text: &str) -> Vec<u8> {
        let mut frame = vec![0x80];
        frame.extend_from_slice(&(text.len() as u32).to_be_bytes());
        frame.extend_from_slice(text.as_bytes());
        frame
    }

    /// One gRPC-web frame, over the shared stub.
    fn serve(body: Vec<u8>) -> (String, std::thread::JoinHandle<String>) {
        let (address, handle) = crate::providers::common::serve_responses(vec![(200, body)]);
        (
            address,
            std::thread::spawn(move || handle.join().expect("server").remove(0)),
        )
    }

    #[test]
    fn the_catalog_names_the_grok_session_cookies() {
        let spec = ProviderId::Grok
            .metadata()
            .browser_session
            .expect("grok browser session");
        assert_eq!(spec.cookie_names, &["sso", "sso-rw"]);
        assert_eq!(sso_token("sso=session-value"), Some("session-value"));
        assert_eq!(sso_token("sso-rw=alt"), Some("alt"));
        assert!(sso_token("sessionKey=sk-ant-ok").is_none());
    }

    /// Both runtimes answer the same cases, so a rule this collector starts reading differently
    /// fails here rather than resolving one account into two subscriptions.
    #[test]
    fn the_shared_conformance_fixture_is_answered() {
        use crate::providers::common::web_conformance;

        const RPC_PATH: &str = "/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig";
        let cases = web_conformance::cases("grok");
        assert!(cases.len() >= 3);
        for case in &cases {
            web_conformance::assert_case(
                case,
                |cookie, context, base| validate_at(cookie, context, &format!("{base}{RPC_PATH}")),
                |cookie, context, base| collect_at(cookie, context, &format!("{base}{RPC_PATH}")),
            );
        }
    }

    /// The RPC this collector calls is that path on grok.com, so a reading driven against a stub
    /// asks for the same RPC a reading against grok.com does.
    #[test]
    fn the_rpc_path_is_the_rpc_url() {
        assert_eq!(
            format!(
                "https://grok.com{}",
                "/grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig"
            ),
            BILLING_RPC_URL
        );
    }

    #[test]
    fn parses_grpc_web_percent_and_auth_trailer() {
        let billing =
            parse_grpc_web_billing(&percent_frame(25.0), 1_786_320_000, RPC_SOURCE).unwrap();
        assert_eq!(billing.used_percent, 25.0);

        let error = parse_grpc_web_billing(
            &trailer_frame("grpc-status: 16\r\ngrpc-message: no-credentials\r\n"),
            1_786_320_000,
            RPC_SOURCE,
        )
        .unwrap_err();
        assert_eq!(error.category, ErrorCategory::AuthRequired);
    }

    /// The cookie is kept only once grok.com has answered the billing RPC cleanly, and a
    /// refusal names the browser rung rather than the token one.
    #[test]
    fn validate_keeps_only_a_session_grok_answers() {
        let (address, server) = serve(percent_frame(25.0));
        let validated = validate_at(
            "sso=session-value",
            &context(),
            &format!("http://{address}"),
        )
        .expect("validated");
        assert_eq!(validated.account_label.as_deref(), Some("Grok"));
        // A cookie that names no one keeps the source-wide fingerprint, which says exactly
        // that.
        assert_eq!(
            validated.account_fingerprint,
            account_identity("grok", "user_id", None).0
        );
        let head = server.join().expect("server");
        assert!(head.contains("cookie: sso=session-value"));
        assert!(!head.contains("authorization:"));

        // Two signed-in accounts are two accounts. The RPC names nobody, so the sign-in cookie
        // is what tells them apart; without it every cookie on a Mac hashed to one fingerprint
        // and the second account overwrote the first.
        let owned = |subject: &str, encoded: &str| {
            let (address, server) = serve(percent_frame(25.0));
            let validated = validate_at(
                &format!("sso=header.{encoded}.signature"),
                &context(),
                &format!("http://{address}"),
            )
            .expect("validated");
            let _ = server.join();
            assert_eq!(
                validated.account_fingerprint,
                account_identity("grok", "user_id", Some(subject)).0
            );
            validated.account_fingerprint
        };
        assert_ne!(
            owned("user-1", "eyJzdWIiOiJ1c2VyLTEifQ"),
            owned("user-2", "eyJzdWIiOiJ1c2VyLTIifQ")
        );

        let (address, server) = serve(trailer_frame(
            "grpc-status: 16\r\ngrpc-message: no-credentials\r\n",
        ));
        let error = validate_at(
            "sso=session-value",
            &context(),
            &format!("http://{address}"),
        )
        .expect_err("refused");
        assert_eq!(error.category, ErrorCategory::AuthRequired);
        assert_eq!(error.source_id, WEB_SOURCE);
        server.join().expect("server");
    }

    /// A header with no grok.com session cookie is refused before a request is made.
    #[test]
    fn validate_rejects_a_header_that_names_no_session() {
        let error = validate_at("sessionKey=sk-ant-ok", &context(), "http://127.0.0.1:1")
            .expect_err("no sso");
        assert_eq!(error.category, ErrorCategory::Error);
        assert_eq!(error.source_id, WEB_SOURCE);
    }

    /// The title heuristic is display copy and may guess; `primary_cadence` is the field a
    /// client reads instead of a title, so it is only set where the reset actually lands in a
    /// cadence.
    #[test]
    fn only_a_reset_inside_a_cadence_names_the_headline_meter() {
        let now = 1_756_000_000;
        let at = |days: i64| {
            billing_window(
                &Billing {
                    used_percent: 10.0,
                    resets_at: Some(now + days * 86_400),
                },
                now,
            )
        };
        assert_eq!(at(3).primary_cadence, Some(Cadence::Weekly));
        assert_eq!(at(30).primary_cadence, Some(Cadence::Monthly));
        // Between the bands, and far past them: still titled, deliberately unnamed.
        assert_eq!(at(15).title, "Weekly");
        assert_eq!(at(15).primary_cadence, None);
        assert_eq!(at(200).primary_cadence, None);
        let undated = billing_window(
            &Billing {
                used_percent: 10.0,
                resets_at: None,
            },
            now,
        );
        assert_eq!(undated.title, "Billing Cycle");
        assert_eq!(undated.primary_cadence, None);
    }

    /// A reading over the cookie is one window from the same RPC the token rung reads.
    #[test]
    fn a_reading_is_the_billing_cycle_window() {
        let (address, server) = serve(percent_frame(25.0));
        let snapshot = collect_at(
            "sso=session-value",
            &context(),
            &format!("http://{address}"),
        )
        .expect("snapshot");
        assert_eq!(snapshot.windows.len(), 1);
        assert_eq!(snapshot.windows[0].id, "billing_cycle");
        assert_eq!(snapshot.windows[0].used_percent, 25.0);
        assert_eq!(snapshot.account.fingerprint_scope, "source");
        server.join().expect("server");
    }
}
