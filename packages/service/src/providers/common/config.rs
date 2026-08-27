use crate::catalog::ProviderId;
use serde::Deserialize;
use std::collections::HashMap;
use std::fs;

use super::identity::mask_secret;
use super::io::{LOCAL_FILE_LIMIT, read_bounded_file_inner};
use super::json::provider_source;
use super::types::{CollectionContext, ErrorCategory, ProviderError};

#[derive(Clone, Debug)]
pub struct ApiKeyCredentials {
    pub api_key: String,
    pub label: String,
    pub source: String,
    pub base_url: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ConfigFile {
    schema_version: u64,
    providers: HashMap<String, ConfigEntry>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ConfigEntry {
    api_key: String,
    #[serde(default)]
    base_url: ConfigBaseUrl,
}

#[derive(Clone, Debug, Default)]
enum ConfigBaseUrl {
    #[default]
    Missing,
    Value(String),
}

impl<'de> Deserialize<'de> for ConfigBaseUrl {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        String::deserialize(deserializer).map(Self::Value)
    }
}

pub fn resolve_api_key(
    context: &CollectionContext,
    provider: ProviderId,
) -> Result<ApiKeyCredentials, ProviderError> {
    let metadata = provider.metadata();
    let provider = provider.as_str();
    let config = metadata
        .credential_config
        .ok_or_else(|| ProviderError::new(ErrorCategory::Error, provider_source(provider)))?;
    let env_keys = metadata.environment_keys;
    let default_base_url = metadata.default_base_url;
    let base_url_env_key = metadata.base_url_environment_key;
    let stored = read_config(context).ok().and_then(|file| {
        if file.schema_version != 1 {
            return None;
        }
        file.providers.get(provider).and_then(|entry| {
            let key = entry.api_key.trim();
            (!key.is_empty()).then(|| {
                let base = match &entry.base_url {
                    ConfigBaseUrl::Missing => None,
                    ConfigBaseUrl::Value(value) => Some(value.clone()),
                };
                (key.to_owned(), base)
            })
        })
    });

    let (api_key, source, stored_base) = if let Some((key, base)) = stored {
        (key, format!("config:{provider}"), base)
    } else {
        let found = env_keys.iter().find_map(|key| {
            if base_url_env_key.is_some_and(|base_key| base_key == *key) {
                return None;
            }
            context
                .env(key)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(|value| (value.to_owned(), (*key).to_owned()))
        });
        match found {
            Some((key, env_key)) => (key, format!("env:{env_key}"), None),
            None => {
                return Err(ProviderError::new(
                    ErrorCategory::AuthRequired,
                    provider_source(provider),
                ));
            }
        }
    };

    // Fixed official endpoints ignore persisted custom URLs; configurable providers validate the
    // stored URL before considering the environment.
    let raw_base = if !config.supports_base_url {
        default_base_url.map(str::to_owned)
    } else {
        stored_base
            .or_else(|| base_url_env_key.and_then(|key| context.env(key).map(str::to_owned)))
            .or_else(|| default_base_url.map(str::to_owned))
    };
    let base_url = match raw_base {
        Some(value) => validate_base_url(&value, config.allow_private_http)
            .map_err(|_| ProviderError::new(ErrorCategory::Error, provider_source(provider)))?,
        None if config.requires_base_url => {
            return Err(ProviderError::new(
                ErrorCategory::AuthRequired,
                provider_source(provider),
            ));
        }
        None => {
            return Err(ProviderError::new(
                ErrorCategory::Error,
                provider_source(provider),
            ));
        }
    };

    if !config.supports_base_url {
        let expected = default_base_url
            .ok_or_else(|| ProviderError::new(ErrorCategory::Error, provider_source(provider)))?;
        if base_url.trim_end_matches('/') != expected.trim_end_matches('/') {
            return Err(ProviderError::new(
                ErrorCategory::Error,
                provider_source(provider),
            ));
        }
    }

    Ok(ApiKeyCredentials {
        label: mask_secret(config.mask_label, &api_key),
        api_key,
        source,
        base_url,
    })
}

fn read_config(context: &CollectionContext) -> Result<ConfigFile, ()> {
    let path = context.config_path();
    if let Some(parent) = path.parent() {
        let parent_metadata = fs::symlink_metadata(parent).map_err(|_| ())?;
        if parent_metadata.file_type().is_symlink() || !parent_metadata.is_dir() {
            return Err(());
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            if parent_metadata.permissions().mode() & 0o077 != 0 {
                return Err(());
            }
        }
    }
    let bytes = read_bounded_file_inner(&path, LOCAL_FILE_LIMIT, true).ok_or(())?;
    let config: ConfigFile = serde_json::from_slice(&bytes).map_err(|_| ())?;
    if config.schema_version != 1
        || config.providers.iter().any(|(provider, entry)| {
            ProviderId::parse(provider)
                .and_then(|id| id.metadata().credential_config)
                .is_none()
                || entry.api_key.trim().is_empty()
                || matches!(&entry.base_url, ConfigBaseUrl::Value(value) if value.trim().is_empty())
        })
    {
        return Err(());
    }
    Ok(config)
}

fn validate_base_url(value: &str, allow_private_http: bool) -> Result<String, ()> {
    let trimmed = value.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        return Err(());
    }
    let candidate = if trimmed.contains("://") {
        trimmed.to_owned()
    } else {
        format!("https://{trimmed}")
    };
    let mut parsed = reqwest::Url::parse(&candidate).map_err(|_| ())?;
    if parsed.username() != "" || parsed.password().is_some() || parsed.fragment().is_some() {
        return Err(());
    }
    parsed.set_query(None);
    let normalized = parsed.as_str().trim_end_matches('/').to_owned();
    match parsed.scheme() {
        "https" => Ok(normalized),
        "http" if allow_private_http && is_private_http_host(parsed.host_str().unwrap_or("")) => {
            Ok(normalized)
        }
        _ => Err(()),
    }
}

fn is_private_http_host(host: &str) -> bool {
    let host = host.trim_end_matches('.').to_ascii_lowercase();
    if host == "localhost" || host.ends_with(".local") {
        return true;
    }
    host.parse::<std::net::IpAddr>()
        .map(|ip| match ip {
            std::net::IpAddr::V4(ip) => ip.is_loopback() || ip.is_private() || ip.is_link_local(),
            std::net::IpAddr::V6(ip) => {
                ip.is_loopback() || ip.is_unique_local() || ip.is_unicast_link_local()
            }
        })
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;
    use std::path::{Path, PathBuf};

    fn temp_path(name: &str) -> PathBuf {
        std::env::temp_dir().join(format!("quota-provider-{name}-{}", uuid::Uuid::new_v4()))
    }

    fn context_with_config(path: PathBuf, environment: &[(&str, &str)]) -> CollectionContext {
        CollectionContext {
            home_directory: temp_path("home"),
            environment: environment
                .iter()
                .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
                .collect(),
            config_path: Some(path),
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

    fn write_config(path: &Path, contents: &str) {
        if let Some(parent) = path.parent()
            && !parent.exists()
        {
            fs::create_dir_all(parent).unwrap();
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(parent, fs::Permissions::from_mode(0o700)).unwrap();
            }
        }
        fs::write(path, contents).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
        }
    }

    #[test]
    fn config_precedes_environment_and_fixed_urls_ignore_stale_values() {
        let path = temp_path("config/providers.json");
        write_config(
            &path,
            r#"{"schema_version":1,"providers":{"openrouter":{"api_key":"sk-config","base_url":"https://old.invalid/v1"}}}"#,
        );
        let context = context_with_config(path.clone(), &[("OPENROUTER_API_KEY", "sk-env")]);
        let credentials = resolve_api_key(&context, ProviderId::OpenRouter).unwrap();
        assert_eq!(credentials.api_key, "sk-config");
        assert_eq!(credentials.source, "config:openrouter");
        assert_eq!(credentials.base_url, "https://openrouter.ai/api/v1");
        assert!(!credentials.label.contains("sk-config"));
        let _ = fs::remove_file(path);
    }

    #[test]
    fn base_url_environment_is_not_used_as_an_api_key() {
        let path = temp_path("config/providers.json");
        let context =
            context_with_config(path, &[("LITELLM_BASE_URL", "https://proxy.example.test")]);
        let error = resolve_api_key(&context, ProviderId::LiteLlm).unwrap_err();
        assert_eq!(error.category, ErrorCategory::AuthRequired);
    }

    #[test]
    fn rejects_invalid_config_entries_and_falls_back_to_environment() {
        let path = temp_path("config/providers.json");
        write_config(
            &path,
            r#"{"schema_version":1,"providers":{"not-a-provider":{"api_key":"secret"}}}"#,
        );
        let context = context_with_config(path.clone(), &[("OPENROUTER_API_KEY", "sk-env")]);
        let credentials = resolve_api_key(&context, ProviderId::OpenRouter).unwrap();
        assert_eq!(credentials.api_key, "sk-env");
        assert_eq!(credentials.source, "env:OPENROUTER_API_KEY");
        let _ = fs::remove_file(path);
    }

    #[test]
    fn rejects_empty_or_null_saved_base_urls_instead_of_using_them() {
        for base_url in ["\"\"", "null"] {
            let path = temp_path("config/providers.json");
            write_config(
                &path,
                &format!(
                    "{{\"schema_version\":1,\"providers\":{{\"litellm\":{{\"api_key\":\"sk-config\",\"base_url\":{base_url}}}}}}}"
                ),
            );
            let context = context_with_config(
                path.clone(),
                &[
                    ("LITELLM_API_KEY", "sk-env"),
                    ("LITELLM_BASE_URL", "https://proxy.example.test"),
                ],
            );
            let credentials = resolve_api_key(&context, ProviderId::LiteLlm).unwrap();
            assert_eq!(credentials.api_key, "sk-env");
            let _ = fs::remove_file(path);
        }
    }

    #[test]
    fn normalizes_urls_without_query_credentials_or_public_http() {
        assert_eq!(
            validate_base_url("proxy.example.test/v1/?ignored=1", false).unwrap(),
            "https://proxy.example.test/v1"
        );
        assert!(validate_base_url("https://user:secret@example.test", false).is_err());
        assert!(validate_base_url("http://example.test", true).is_err());
        assert_eq!(
            validate_base_url("http://127.0.0.1:4000/v1", true).unwrap(),
            "http://127.0.0.1:4000/v1"
        );
    }

    #[test]
    fn config_reader_rejects_symlink_oversized_and_permissive_files() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::{PermissionsExt, symlink};
            let environment = [("OPENROUTER_API_KEY", "sk-env")];

            let config_root = temp_path("config-root");
            fs::create_dir_all(&config_root).unwrap();
            fs::set_permissions(&config_root, fs::Permissions::from_mode(0o700)).unwrap();
            let target = config_root.join("target");
            write_config(
                &target,
                r#"{"schema_version":1,"providers":{"openrouter":{"api_key":"sk-config"}}}"#,
            );
            let link = config_root.join("link");
            symlink(&target, &link).unwrap();
            let context = context_with_config(link.clone(), &environment);
            let credentials = resolve_api_key(&context, ProviderId::OpenRouter).unwrap();
            assert_eq!(credentials.source, "env:OPENROUTER_API_KEY");

            let oversized = temp_path("config-oversized");
            write_config(&oversized, &"x".repeat(LOCAL_FILE_LIMIT + 1));
            let credentials = resolve_api_key(
                &context_with_config(oversized.clone(), &environment),
                ProviderId::OpenRouter,
            )
            .unwrap();
            assert_eq!(credentials.source, "env:OPENROUTER_API_KEY");

            let permissive = temp_path("config-permissive");
            write_config(
                &permissive,
                r#"{"schema_version":1,"providers":{"openrouter":{"api_key":"sk-config"}}}"#,
            );
            fs::set_permissions(&permissive, fs::Permissions::from_mode(0o644)).unwrap();
            let credentials = resolve_api_key(
                &context_with_config(permissive.clone(), &environment),
                ProviderId::OpenRouter,
            )
            .unwrap();
            assert_eq!(credentials.source, "env:OPENROUTER_API_KEY");

            let _ = fs::remove_file(target);
            let _ = fs::remove_file(link);
            let _ = fs::remove_file(oversized);
            let _ = fs::remove_file(permissive);
            let _ = fs::remove_dir_all(config_root);
        }
    }
}
