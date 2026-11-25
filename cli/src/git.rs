//! Repository identity: the `origin` remote without protocol, user and `.git`
//! (for example `github.com/owner/name`), so the same dossier serves every clone.

use std::path::{Path, PathBuf};
use std::process::Command;

pub fn available() -> bool {
    Command::new("git")
        .arg("--version")
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// The top folder of the Git work tree that contains `path`.
pub fn repo_root(path: &Path) -> Option<PathBuf> {
    let out = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let root = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (!root.is_empty()).then(|| PathBuf::from(root))
}

/// `host/owner/name` from the `origin` remote, else `local/<folder name>`.
pub fn identity(root: &Path) -> String {
    let remote = Command::new("git")
        .arg("-C")
        .arg(root)
        .args(["remote", "get-url", "origin"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string());
    if let Some(id) = remote.as_deref().and_then(normalize_remote) {
        return id;
    }
    let name = root
        .file_name()
        .map(|n| n.to_string_lossy().to_lowercase())
        .unwrap_or_else(|| "repository".into());
    format!("local/{name}")
}

/// Normalizes a remote URL; returns None for local paths and unparseable values.
pub fn normalize_remote(url: &str) -> Option<String> {
    let url = url.trim();
    let bytes = url.as_bytes();
    let looks_local = url.is_empty()
        || url.starts_with('/')
        || url.starts_with('.')
        || url.starts_with('\\')
        || url.starts_with("file:")
        || (bytes.len() >= 2 && bytes[1] == b':' && bytes[0].is_ascii_alphabetic());
    if looks_local {
        return None;
    }
    let mut s = url.to_string();
    if let Some(i) = s.find("://") {
        s = s[i + 3..].to_string();
        if let Some(at) = s.find('@')
            && !s[..at].contains('/')
        {
            s = s[at + 1..].to_string();
        }
        if let Some(slash) = s.find('/')
            && let Some(colon) = s[..slash].find(':')
        {
            s = format!("{}{}", &s[..colon], &s[slash..]);
        }
    } else {
        if let Some(at) = s.find('@') {
            s = s[at + 1..].to_string();
        }
        let colon = s.find(':')?;
        s.replace_range(colon..colon + 1, "/");
    }
    let s = s.trim_end_matches('/');
    let s = s.strip_suffix(".git").unwrap_or(s).trim_end_matches('/');
    let s = s.to_lowercase();
    (s.contains('/') && !s.starts_with('/')).then_some(s)
}

#[cfg(test)]
mod tests {
    use super::normalize_remote;

    #[test]
    fn remote_forms() {
        let want = Some("github.com/owner/name".to_string());
        assert_eq!(normalize_remote("https://github.com/Owner/Name.git"), want);
        assert_eq!(
            normalize_remote("https://user:tok@github.com/owner/name"),
            want
        );
        assert_eq!(normalize_remote("git@github.com:owner/name.git"), want);
        assert_eq!(
            normalize_remote("ssh://git@github.com:22/owner/name/"),
            want
        );
        assert_eq!(normalize_remote("C:\\repos\\name"), None);
        assert_eq!(normalize_remote("/srv/git/name.git"), None);
        assert_eq!(normalize_remote("../name"), None);
    }
}
