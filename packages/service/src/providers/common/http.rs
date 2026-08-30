use reqwest::blocking::Client;
use reqwest::redirect::Policy;
use serde_json::Value;
use std::io::Read;
use std::time::Duration;

use super::types::{ErrorCategory, ProviderError};

pub const HTTP_TIMEOUT: Duration = Duration::from_secs(20);
pub const VALIDATION_TIMEOUT: Duration = Duration::from_secs(10);
pub const HTTP_BODY_LIMIT: usize = 1_048_576;

pub struct HttpClient {
    client: Client,
}

impl HttpClient {
    pub fn new() -> Result<Self, ProviderError> {
        Self::with_timeout(HTTP_TIMEOUT)
    }

    /// On macOS the client speaks TLS through Secure Transport rather than rustls. Some
    /// providers sit behind edge firewalls that fingerprint the TLS handshake — cursor.com
    /// (Vercel) answers a rustls handshake with a 403 HTML page whatever the cookie or
    /// User-Agent says, and answers the platform stack with the JSON it gives a browser. Linux
    /// builds keep rustls, which needs no system library.
    pub fn with_timeout(timeout: Duration) -> Result<Self, ProviderError> {
        let builder = Client::builder().timeout(timeout).redirect(Policy::none());
        #[cfg(target_os = "macos")]
        let builder = builder.use_native_tls();
        builder
            .build()
            .map(|client| Self { client })
            .map_err(|_| ProviderError::new(ErrorCategory::Unavailable, "http"))
    }

    pub fn get_json(
        &self,
        url: &str,
        headers: &[(&str, &str)],
        source: &'static str,
    ) -> Result<(u16, Value), ProviderError> {
        self.send_json(
            self.client.get(url),
            headers,
            source,
            ErrorCategory::Unavailable,
        )
    }

    pub fn get_json_session(
        &self,
        url: &str,
        headers: &[(&str, &str)],
        source: &'static str,
    ) -> Result<(u16, Value), ProviderError> {
        self.send_json(
            self.client.get(url),
            headers,
            source,
            ErrorCategory::AuthRequired,
        )
    }

    pub fn post_json(
        &self,
        url: &str,
        headers: &[(&str, &str)],
        body: &Value,
        source: &'static str,
    ) -> Result<(u16, Value), ProviderError> {
        self.send_json(
            self.client
                .post(url)
                .header("Content-Type", "application/json")
                .body(body.to_string()),
            headers,
            source,
            ErrorCategory::Unavailable,
        )
    }

    pub fn post_json_session(
        &self,
        url: &str,
        headers: &[(&str, &str)],
        body: &Value,
        source: &'static str,
    ) -> Result<(u16, Value), ProviderError> {
        self.send_json(
            self.client
                .post(url)
                .header("Content-Type", "application/json")
                .body(body.to_string()),
            headers,
            source,
            ErrorCategory::AuthRequired,
        )
    }

    pub fn post_bytes(
        &self,
        url: &str,
        headers: &[(&str, &str)],
        body: &[u8],
        source: &'static str,
    ) -> Result<(u16, Vec<u8>), ProviderError> {
        self.send_raw(
            self.client.post(url).body(body.to_vec()),
            headers,
            source,
            ErrorCategory::AuthRequired,
        )
    }

    fn send_json(
        &self,
        request: reqwest::blocking::RequestBuilder,
        headers: &[(&str, &str)],
        source: &'static str,
        redirect_category: ErrorCategory,
    ) -> Result<(u16, Value), ProviderError> {
        let (status, body) = self.send_raw(request, headers, source, redirect_category)?;
        Ok((status, serde_json::from_slice(&body).unwrap_or(Value::Null)))
    }

    fn send_raw(
        &self,
        mut request: reqwest::blocking::RequestBuilder,
        headers: &[(&str, &str)],
        source: &'static str,
        redirect_category: ErrorCategory,
    ) -> Result<(u16, Vec<u8>), ProviderError> {
        for (name, value) in headers {
            request = request.header(*name, *value);
        }
        let response = request
            .send()
            .map_err(|_| ProviderError::new(ErrorCategory::Unavailable, source))?;
        let status = response.status().as_u16();
        if (300..400).contains(&status) {
            return Err(ProviderError::new(redirect_category, source));
        }
        if response
            .content_length()
            .is_some_and(|length| length > HTTP_BODY_LIMIT as u64)
        {
            return Err(ProviderError::new(ErrorCategory::Error, source));
        }
        let mut body = Vec::with_capacity(
            response
                .content_length()
                .unwrap_or(0)
                .min(HTTP_BODY_LIMIT as u64) as usize,
        );
        response
            .take(HTTP_BODY_LIMIT.saturating_add(1) as u64)
            .read_to_end(&mut body)
            .map_err(|_| ProviderError::new(ErrorCategory::Unavailable, source))?;
        if body.len() > HTTP_BODY_LIMIT {
            return Err(ProviderError::new(ErrorCategory::Error, source));
        }
        if !(200..300).contains(&status) {
            return Err(ProviderError::new(http_category(status), source));
        }
        Ok((status, body))
    }
}

fn http_category(status: u16) -> ErrorCategory {
    match status {
        401 | 403 => ErrorCategory::AuthRequired,
        404 | 501 => ErrorCategory::Unsupported,
        408 | 429 | 500..=599 => ErrorCategory::Unavailable,
        _ => ErrorCategory::Error,
    }
}

/// A local HTTP server that answers a fixed queue of responses and hands back the request
/// heads it saw, lowercased.
///
/// One of these rather than one per provider: what a validation or a reading does over the
/// wire is the same question everywhere — which headers went out, and what the collector makes
/// of what came back — and five copies of a `TcpListener` loop was five places to get the
/// framing subtly different.
#[cfg(test)]
pub fn serve_responses(
    responses: Vec<(u16, Vec<u8>)>,
) -> (String, std::thread::JoinHandle<Vec<String>>) {
    use std::io::{Read as _, Write as _};
    use std::net::TcpListener;

    let listener = TcpListener::bind("127.0.0.1:0").expect("listener");
    let address = listener.local_addr().expect("address").to_string();
    let handle = std::thread::spawn(move || {
        let mut heads = Vec::new();
        for (status, body) in responses {
            let Ok((mut stream, _)) = listener.accept() else {
                break;
            };
            let mut request = [0_u8; 8_192];
            let read = stream.read(&mut request).unwrap_or(0);
            heads.push(String::from_utf8_lossy(&request[..read]).to_lowercase());
            let reason = if (200..300).contains(&status) {
                "OK"
            } else {
                "Error"
            };
            let _ = write!(
                stream,
                "HTTP/1.1 {status} {reason}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            let _ = stream.write_all(&body);
        }
        heads
    });
    (address, handle)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::thread;

    #[test]
    fn classifies_provider_http_statuses_without_response_details() {
        assert_eq!(http_category(401), ErrorCategory::AuthRequired);
        assert_eq!(http_category(403), ErrorCategory::AuthRequired);
        assert_eq!(http_category(404), ErrorCategory::Unsupported);
        assert_eq!(http_category(429), ErrorCategory::Unavailable);
        assert_eq!(http_category(500), ErrorCategory::Unavailable);
        assert_eq!(http_category(400), ErrorCategory::Error);
        let error = ProviderError::new(ErrorCategory::AuthRequired, "fixture");
        assert!(!error.to_string().contains("opaque-secret"));
    }

    #[test]
    fn bounded_http_body_rejects_streams_without_content_length() {
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 1024];
            let _ = stream.read(&mut request);
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n")
                .unwrap();
            let chunk = [b'x'; 8192];
            for _ in 0..((HTTP_BODY_LIMIT / chunk.len()) + 2) {
                if stream.write_all(&chunk).is_err() {
                    break;
                }
            }
        });
        let client = HttpClient::new().unwrap();
        let error = client
            .get_json(&format!("http://{address}"), &[], "fixture")
            .unwrap_err();
        assert_eq!(error.category, ErrorCategory::Error);
        server.join().unwrap();
    }

    #[test]
    fn non_json_auth_errors_keep_status_classification_and_redact_body() {
        use std::net::TcpListener;

        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = [0_u8; 512];
            let _ = stream.read(&mut request);
            let body = b"<html>provider secret diagnostics</html>";
            let header = format!(
                "HTTP/1.1 401 Unauthorized\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            stream.write_all(header.as_bytes()).unwrap();
            let _ = stream.write_all(body);
        });
        let client = HttpClient::new().unwrap();
        let error = client
            .get_json(&format!("http://{address}"), &[], "fixture")
            .unwrap_err();
        assert_eq!(error.category, ErrorCategory::AuthRequired);
        assert!(!error.to_string().contains("provider secret diagnostics"));
        server.join().unwrap();
    }
}
