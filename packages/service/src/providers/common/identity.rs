use sha2::{Digest, Sha256};

pub fn account_identity(
    provider: &str,
    namespace: &str,
    owner: Option<&str>,
) -> (String, &'static str) {
    match owner.map(str::trim).filter(|value| !value.is_empty()) {
        Some(value) => (
            sha256_hex(&format!("{provider}:global:{namespace}:{value}")),
            "global",
        ),
        None => (sha256_hex(&format!("{provider}:source")), "source"),
    }
}

pub fn api_key_identity(provider: &str, api_key: &str) -> (String, &'static str) {
    let key_hash = sha256_hex(api_key);
    account_identity(provider, "api_key", Some(&key_hash))
}

pub fn sha256_hex(value: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(value.as_bytes());
    hex_lower(&hasher.finalize())
}

fn hex_lower(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(HEX[(byte >> 4) as usize] as char);
        output.push(HEX[(byte & 0x0f) as usize] as char);
    }
    output
}

pub fn mask_secret(label: &str, secret: &str) -> String {
    let secret = secret.trim();
    if secret.chars().count() <= 8 {
        return format!("{label} key");
    }
    let visible = secret
        .chars()
        .rev()
        .take(4)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect::<String>();
    format!("{label} ···{visible}")
}

pub fn mask_email(value: Option<&str>) -> Option<String> {
    let value = value?.trim();
    let (local, domain) = value.split_once('@')?;
    if local.is_empty() || domain.is_empty() {
        return None;
    }
    Some(format!(
        "{}***@{}",
        local.chars().take(2).collect::<String>(),
        domain
    ))
}

pub fn mask_display_name(value: Option<&str>) -> Option<String> {
    let value = value?.trim();
    if value.is_empty() {
        return None;
    }
    if value.contains('@') {
        return mask_email(Some(value));
    }
    let chars: Vec<char> = value.chars().collect();
    Some(if chars.len() <= 2 {
        format!("{}*", chars.first().copied().unwrap_or('*'))
    } else {
        format!("{}***", chars.iter().take(2).collect::<String>())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identity_and_redaction_are_stable_and_non_secret() {
        let first = account_identity("grok", "user_id", Some("owner"));
        let second = account_identity("grok", "user_id", Some("owner"));
        assert_eq!(first, second);
        assert_eq!(first.0.len(), 64);
        assert_eq!(first.1, "global");
        assert_ne!(
            first.0,
            account_identity("grok", "team_id", Some("owner")).0
        );
        assert_eq!(
            mask_email(Some("ada@example.com")).as_deref(),
            Some("ad***@example.com")
        );
        assert_eq!(
            mask_display_name(Some("Ada Lovelace")).as_deref(),
            Some("Ad***")
        );
        assert_eq!(mask_secret("API", "opaque-secret"), "API ···cret");
        assert_eq!(mask_secret("API", "short"), "API key");
    }
}
