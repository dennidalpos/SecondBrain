use std::env;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

fn sources(dir: &Path, files: &mut Vec<PathBuf>) -> io::Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let kind = entry.file_type()?;
        if kind.is_dir() {
            sources(&entry.path(), files)?;
        } else if kind.is_file() {
            files.push(entry.path());
        }
    }
    Ok(())
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rerun-if-env-changed=SOURCE_DATE_EPOCH");
    let mut files: Vec<PathBuf> = vec!["build.rs".into(), "Cargo.toml".into(), "Cargo.lock".into()];
    println!("cargo:rerun-if-changed=src");
    for path in &files {
        println!("cargo:rerun-if-changed={}", path.display());
    }
    sources(Path::new("src"), &mut files)?;
    files.sort();
    // FNV-1a is a source identity hint, independent of the compiler and build profile.
    let mut hash = 0xcbf29ce484222325_u64;
    for path in files {
        let content = fs::read(&path)?;
        for byte in (content.len() as u64)
            .to_le_bytes()
            .into_iter()
            .chain(content)
        {
            hash = (hash ^ u64::from(byte)).wrapping_mul(0x100000001b3);
        }
    }
    let stamp = match env::var("SOURCE_DATE_EPOCH") {
        Ok(value) => value
            .parse::<u128>()?
            .checked_mul(1_000_000_000)
            .ok_or("SOURCE_DATE_EPOCH is too large")?,
        Err(env::VarError::NotPresent) => SystemTime::now().duration_since(UNIX_EPOCH)?.as_nanos(),
        Err(error) => return Err(error.into()),
    };
    println!(
        "cargo:rustc-env=SB_BUILD_MARKER=SB_BUILD_V1|{}|{stamp}|{hash:016x}|END_SB_BUILD",
        env::var("CARGO_PKG_VERSION")?
    );
    Ok(())
}
