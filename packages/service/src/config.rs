use std::ffi::OsString;
use std::path::PathBuf;

/// Resolve the shared Quota configuration directory.
///
/// An explicitly configured XDG path must be absolute so neither app can escape its expected
/// owner-only root through a relative process environment value.
pub fn config_root(home: Option<OsString>, configured: Option<OsString>) -> Option<PathBuf> {
    let home = PathBuf::from(home?);
    match configured {
        None => Some(home.join(".config")),
        Some(value) if value.is_empty() => Some(home.join(".config")),
        Some(value) => {
            let path = PathBuf::from(value);
            path.is_absolute().then_some(path)
        }
    }
}

pub fn default_config_root() -> Option<PathBuf> {
    config_root(
        std::env::var_os("HOME"),
        std::env::var_os("XDG_CONFIG_HOME"),
    )
}

pub fn default_state_root() -> Option<PathBuf> {
    default_config_root().map(|root| root.join("quotacli"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_path_obeys_xdg_absolute_rule() {
        assert_eq!(
            config_root(Some(OsString::from("/Users/test")), None),
            Some(PathBuf::from("/Users/test/.config"))
        );
        assert_eq!(
            config_root(Some(OsString::from("/Users/test")), Some(OsString::new())),
            Some(PathBuf::from("/Users/test/.config"))
        );
        assert_eq!(
            config_root(
                Some(OsString::from("/Users/test")),
                Some(OsString::from("/tmp/quota"))
            ),
            Some(PathBuf::from("/tmp/quota"))
        );
        assert_eq!(
            config_root(
                Some(OsString::from("/Users/test")),
                Some(OsString::from("relative"))
            ),
            None
        );
    }
}
