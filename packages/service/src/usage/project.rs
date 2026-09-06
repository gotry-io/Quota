//! Local-only project attribution from a working directory.
//!
//! The key is the basename of the git work tree when `.git` is reachable from `cwd`, otherwise
//! the last path component. Full paths never leave this function.

use std::path::{Component, Path};

/// Bound on a stored project key. Basenames longer than this are dropped rather than truncated,
/// so two long names cannot collapse into one key.
const MAX_PROJECT_KEY_CHARS: usize = 128;

/// Derive the local project key from a working directory.
///
/// Walks toward the filesystem root looking for `.git` (a directory or a gitfile). The first
/// match is the work tree; its basename is the key. A cwd that is not inside a work tree uses
/// its last component. Empty, `/`, or a name with control characters yields `None`.
pub fn project_key_from_cwd(cwd: &str) -> Option<String> {
    let cwd = cwd.trim();
    if cwd.is_empty() {
        return None;
    }
    let path = Path::new(cwd);
    let root = git_work_tree(path).unwrap_or(path);
    basename_key(root)
}

/// Last path component of an already-encoded Claude Code / Cursor project directory name.
///
/// `~/.claude/projects/<encoded>/` stores the absolute path with `/` replaced by `-`. That
/// encoding is lossy when a directory name itself contains `-`, so callers prefer a `cwd` field
/// on the record when one exists. The fallback is the last `-`-separated segment, which is the
/// basename when no directory name contained a hyphen.
pub fn project_key_from_encoded_dir(name: &str) -> Option<String> {
    let name = name.trim();
    if name.is_empty() {
        return None;
    }
    let decoded = if name.starts_with('-') {
        name.replacen('-', "/", 1).replace('-', "/")
    } else if name.contains('/') || name.contains('\\') {
        name.to_owned()
    } else {
        format!("/{}", name.replace('-', "/"))
    };
    project_key_from_cwd(&decoded)
}

/// Claude Code and Cursor store transcripts under `projects/<encoded-path>/`.
pub fn project_key_from_source_path(path: &Path) -> Option<String> {
    let mut components = path.components().peekable();
    while let Some(component) = components.next() {
        let Component::Normal(name) = component else {
            continue;
        };
        if name != "projects" {
            continue;
        }
        let Component::Normal(encoded) = components.next()? else {
            continue;
        };
        return project_key_from_encoded_dir(encoded.to_str()?);
    }
    None
}

fn git_work_tree(start: &Path) -> Option<&Path> {
    let mut current = start;
    loop {
        let git = current.join(".git");
        if git.is_dir() || git.is_file() {
            return Some(current);
        }
        current = current.parent()?;
    }
}

fn basename_key(path: &Path) -> Option<String> {
    let name = path.file_name()?.to_str()?.trim();
    bounded_project_key(name)
}

pub(crate) fn bounded_project_key(value: &str) -> Option<String> {
    if value.is_empty()
        || value == "."
        || value == ".."
        || value.chars().count() > MAX_PROJECT_KEY_CHARS
        || value.chars().any(char::is_control)
    {
        return None;
    }
    Some(value.to_owned())
}

pub fn cwd_from_value(value: &serde_json::Map<String, serde_json::Value>) -> Option<&str> {
    const KEYS: [&str; 5] = ["cwd", "directory", "path", "workspace", "workingDirectory"];
    for key in KEYS {
        if let Some(cwd) = value.get(key).and_then(serde_json::Value::as_str) {
            let cwd = cwd.trim();
            if !cwd.is_empty() {
                return Some(cwd);
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::{bounded_project_key, project_key_from_cwd, project_key_from_encoded_dir};
    use std::fs;
    use std::path::PathBuf;

    fn temp_tree(name: &str) -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("quota-project-key-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).expect("temp tree");
        path
    }

    #[test]
    fn a_git_work_tree_uses_the_repository_basename() {
        let root = temp_tree("repo");
        fs::create_dir_all(root.join(".git")).expect("git dir");
        let nested = root.join("packages").join("service");
        fs::create_dir_all(&nested).expect("nested");
        let expected = root.file_name().unwrap().to_str().unwrap();
        assert_eq!(
            project_key_from_cwd(nested.to_str().unwrap()).as_deref(),
            Some(expected)
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_gitfile_counts_as_a_work_tree() {
        let root = temp_tree("worktree");
        fs::write(root.join(".git"), "gitdir: /tmp/elsewhere.git\n").expect("gitfile");
        let expected = root.file_name().unwrap().to_str().unwrap();
        assert_eq!(
            project_key_from_cwd(root.to_str().unwrap()).as_deref(),
            Some(expected)
        );
        let _ = fs::remove_dir_all(root);
    }

    #[test]
    fn a_cwd_outside_a_repository_uses_the_last_component() {
        let path = temp_tree("loose");
        let nested = path.join("workspace");
        fs::create_dir_all(&nested).expect("workspace");
        assert_eq!(
            project_key_from_cwd(nested.to_str().unwrap()).as_deref(),
            Some("workspace")
        );
        let _ = fs::remove_dir_all(path);
    }

    #[test]
    fn a_missing_cwd_still_yields_the_last_component() {
        assert_eq!(
            project_key_from_cwd("/Users/someone/Code/Quota").as_deref(),
            Some("Quota")
        );
    }

    #[test]
    fn empty_and_root_cwds_are_unattributed() {
        assert_eq!(project_key_from_cwd(""), None);
        assert_eq!(project_key_from_cwd("   "), None);
        assert_eq!(project_key_from_cwd("/"), None);
    }

    #[test]
    fn an_encoded_claude_directory_decodes_to_the_basename() {
        assert_eq!(
            project_key_from_encoded_dir("-Users-someone-Code-Quota").as_deref(),
            Some("Quota")
        );
    }

    #[test]
    fn control_characters_and_overlong_names_are_dropped() {
        assert_eq!(bounded_project_key("ok"), Some("ok".into()));
        assert_eq!(bounded_project_key("has\nnewline"), None);
        assert_eq!(bounded_project_key(&"a".repeat(129)), None);
        assert_eq!(bounded_project_key("."), None);
    }
}
