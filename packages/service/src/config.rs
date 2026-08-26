use std::ffi::OsString;
use std::path::{Path, PathBuf};

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
    default_config_root().map(|root| root.join("quota"))
}

/// The root this service was released under, beside the one it keeps state in now.
///
/// Only the shared configuration root's `quota` directory has a released sibling to adopt. A root
/// given to the service directly — tests, the packaged-helper harness — has none, so an isolated
/// run never reads or removes anything outside the root it was handed.
pub fn legacy_state_root(state_root: &Path) -> Option<PathBuf> {
    (state_root.file_name()?.to_str()? == "quota").then(|| state_root.with_file_name("quotacli"))
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

    #[test]
    fn only_the_shared_config_root_has_a_released_sibling_to_adopt() {
        assert_eq!(
            legacy_state_root(Path::new("/Users/test/.config/quota")),
            Some(PathBuf::from("/Users/test/.config/quotacli"))
        );
        // An isolated root is the whole world that run may touch.
        assert_eq!(legacy_state_root(Path::new("/tmp/quota-test-1234")), None);
        assert_eq!(legacy_state_root(Path::new("/")), None);
    }
}
