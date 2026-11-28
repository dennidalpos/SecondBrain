//! Inspect alternate SecondBrain builds without executing commands found on PATH.

use regex::bytes::Regex;
use std::cmp::Ordering;
use std::collections::HashSet;
use std::env;
use std::fs::{self, File};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

const MARKER: &str = env!("SB_BUILD_MARKER");
const LIMIT: u64 = 64 * 1024 * 1024;
static SIGNATURE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"SB_BUILD_V1\|([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)(?:\+[0-9A-Za-z.-]+)?\|([0-9]{1,39})\|([a-f0-9]{16})\|END_SB_BUILD")
        .expect("valid build marker pattern")
});

#[derive(Clone, Debug, Eq, PartialEq)]
struct Build {
    version: String,
    stamp: u128,
    source: String,
}

impl Build {
    fn in_bytes(bytes: &[u8]) -> Option<Self> {
        let mut found = SIGNATURE.captures_iter(bytes);
        let parts = found.next()?;
        if found.any(|other| other[0] != parts[0]) {
            return None;
        }
        let text = |index| std::str::from_utf8(parts.get(index)?.as_bytes()).ok();
        Some(Self {
            version: text(1)?.into(),
            stamp: text(2)?.parse().ok()?,
            source: text(3)?.into(),
        })
    }

    fn compare(&self, other: &Self) -> Ordering {
        compare_versions(&self.version, &other.version).then_with(|| self.stamp.cmp(&other.stamp))
    }

    fn newer_than(&self, other: &Self) -> bool {
        (self.version != other.version || self.source != other.source)
            && self.compare(other).is_gt()
    }

    fn label(&self) -> String {
        format!("{} (source {})", self.version, self.source)
    }
}

fn compare_versions(left: &str, right: &str) -> Ordering {
    fn parts(version: &str) -> (impl Iterator<Item = usize> + '_, Option<&str>) {
        // The first stable release reset the version sequence after this prerelease.
        let version = match version {
            "5.0.0-alpha.1" => "1.0.0-alpha.1",
            _ => version,
        };
        let (core, pre) = version
            .split_once('-')
            .map_or((version, None), |(c, p)| (c, Some(p)));
        (core.split('.').map(|part| part.parse().unwrap_or(0)), pre)
    }
    let (left_core, left_pre) = parts(left);
    let (right_core, right_pre) = parts(right);
    left_core
        .cmp(right_core)
        .then_with(|| match (left_pre, right_pre) {
            (None, None) => Ordering::Equal,
            (None, Some(_)) => Ordering::Greater,
            (Some(_), None) => Ordering::Less,
            (Some(left), Some(right)) => {
                for (a, b) in left.split('.').zip(right.split('.')) {
                    let order = match (a.parse::<u64>(), b.parse::<u64>()) {
                        (Ok(a), Ok(b)) => a.cmp(&b),
                        (Ok(_), Err(_)) => Ordering::Less,
                        (Err(_), Ok(_)) => Ordering::Greater,
                        (Err(_), Err(_)) => a.cmp(b),
                    };
                    if order != Ordering::Equal {
                        return order;
                    }
                }
                left.split('.').count().cmp(&right.split('.').count())
            }
        })
}

fn file_build(path: &Path) -> Option<Build> {
    let file = File::open(path).ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() || metadata.len() > LIMIT {
        return None;
    }
    let mut bytes = Vec::new();
    file.take(LIMIT + 1).read_to_end(&mut bytes).ok()?;
    if bytes.len() as u64 > LIMIT {
        return None;
    }
    Build::in_bytes(&bytes)
}

fn is_executable(path: &Path) -> bool {
    let Ok(meta) = path.metadata() else {
        return false;
    };
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if meta.permissions().mode() & 0o111 == 0 {
            return false;
        }
    }
    meta.is_file()
}

pub(crate) struct Status {
    running: PathBuf,
    build: Build,
    first_on_path: Option<(PathBuf, Option<Build>)>,
    newer: Option<(PathBuf, Build)>,
}

impl Status {
    pub fn inspect(running: &str, source_checkouts: &[PathBuf]) -> Self {
        let running = PathBuf::from(running);
        let build = Build::in_bytes(MARKER.as_bytes()).expect("valid embedded build marker");
        let name = format!("sb{}", env::consts::EXE_SUFFIX);
        let path = env::var_os("PATH").unwrap_or_default();
        let on_path = env::split_paths(&path).map(|dir| dir.join(&name));
        let cargo_home = env::var_os("CARGO_HOME").map(PathBuf::from).or_else(|| {
            env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
                .map(|home| PathBuf::from(home).join(".cargo"))
        });
        let cargo = cargo_home.map(|home| home.join("bin").join(&name));
        let local = source_checkouts.iter().flat_map(|root| {
            ["release", "debug"].map(|profile| root.join("cli/target").join(profile).join(&name))
        });
        let resolved_running = fs::canonicalize(&running).ok();
        let mut seen = HashSet::new();
        let mut winner = build.clone();
        let mut newer = None;
        let mut first_on_path = None;
        for (path, from_path) in on_path
            .map(|p| (p, true))
            .chain(cargo.into_iter().chain(local).map(|p| (p, false)))
        {
            if !is_executable(&path) {
                continue;
            }
            let Ok(resolved) = fs::canonicalize(&path) else {
                continue;
            };
            if !seen.insert(resolved.clone()) {
                continue;
            }
            let installed = if Some(&resolved) == resolved_running.as_ref() {
                file_build(&resolved)
                    .filter(|installed| installed != &build)
                    .or_else(|| Some(build.clone()))
            } else {
                file_build(&resolved)
            };
            if from_path && first_on_path.is_none() {
                first_on_path = Some((path.clone(), installed.clone()));
            }
            if let Some(candidate) = installed
                && candidate.newer_than(&build)
                && candidate.compare(&winner).is_gt()
            {
                winner = candidate.clone();
                newer = Some((path, candidate));
            }
        }
        Self {
            running,
            build,
            first_on_path,
            newer,
        }
    }

    pub fn may_repair(&self) -> bool {
        self.newer.is_none()
    }

    pub fn older_registration(&self, path: &Path) -> bool {
        path.is_absolute()
            && is_executable(path)
            && file_build(path).is_some_and(|build| {
                self.newer
                    .as_ref()
                    .map_or(&self.build, |(_, build)| build)
                    .newer_than(&build)
            })
    }

    pub fn text(&self) -> String {
        let mut text = format!(
            "- Executable  {} [{}]\n",
            self.running.display(),
            self.build.label()
        );
        if let Some((path, build)) = &self.first_on_path {
            let label = build
                .as_ref()
                .map_or_else(|| "no SecondBrain build marker".to_string(), Build::label);
            text.push_str(&format!("- PATH        {} [{label}]\n", path.display()));
            if build
                .as_ref()
                .is_none_or(|build| self.build.newer_than(build))
            {
                text.push_str("  To run this build by name, update the earlier sb on PATH or invoke this executable by its full path.\n");
            }
        }
        if let Some((path, build)) = &self.newer {
            text.push_str(&format!("- Newer build  {} [{}]\n  Run the newer executable by full path with the `start` argument. Managed file repairs are paused.\n", path.display(), build.label()));
        }
        text
    }
}

#[cfg(test)]
mod tests {
    use super::compare_versions;

    #[test]
    fn first_stable_release_supersedes_the_original_prerelease() {
        assert!(compare_versions("1.0.0", "5.0.0-alpha.1").is_gt());
        assert!(compare_versions("5.0.0-alpha.1", "1.0.0").is_lt());
        assert!(compare_versions("5.0.0", "1.0.0").is_gt());
    }
}
