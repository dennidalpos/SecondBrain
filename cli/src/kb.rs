//! Sources: documents, notes and extracts kept per repository in `<dossier>/kb.db`.
//!
//! The caller (an agent in a desktop app, or a person) supplies the extracted text; sb never
//! parses a document. The text is cut into chunks and indexed with SQLite FTS5 and BM25. An
//! original file may be copied once into a separate folder that is for the user only: after
//! the copy sb never opens it again, and it is never searched, exported or synchronized.
//! Sources are organized with PARA (project, area, resource, archive).

use crate::check::{self, Kind, Scope};
use crate::store::{Dossier, Home};
use crate::task::one_line;
use anyhow::{Context as _, Result, anyhow, bail};
use rusqlite::{Connection, OptionalExtension, Row, params};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Largest extracted text accepted for one source.
pub const MAX_TEXT_BYTES: usize = 2 * 1024 * 1024;
/// About 800 tokens (four characters each).
const CHUNK_CHARS: usize = 3200;
pub const PARAS: &[&str] = &["project", "area", "resource", "archive"];
pub const KINDS: &[&str] = &["file", "web", "note", "chat", "connector", "media"];
const SCHEMA_VERSION: i64 = 1;

pub fn db_path(d: &Dossier) -> PathBuf {
    d.dir.join("kb.db")
}

/// Where the originals of a repository are kept: `SB_ORIGINALS` when set, else `<home>/originals`.
pub fn originals_dir(home: &Home, d: &Dossier) -> Result<PathBuf> {
    let name = d
        .dir
        .file_name()
        .ok_or_else(|| anyhow!("the dossier folder has no name"))?;
    match std::env::var_os("SB_ORIGINALS").filter(|v| !v.is_empty()) {
        Some(base) => {
            let base = PathBuf::from(base);
            let absolute = std::path::absolute(&base).unwrap_or(base);
            if absolute.ancestors().any(|p| p.join(".git").exists()) {
                bail!(
                    "SB_ORIGINALS points inside a Git repository ({}); choose a folder outside any repository",
                    absolute.display()
                );
            }
            Ok(absolute.join(name))
        }
        None => Ok(home.root.join("originals").join(name)),
    }
}

fn connect(d: &Dossier, create: bool) -> Result<Option<Connection>> {
    let file = db_path(d);
    if !create && !file.exists() {
        return Ok(None);
    }
    let conn = Connection::open(&file).with_context(|| format!("opening {}", file.display()))?;
    conn.busy_timeout(Duration::from_secs(10))?;
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA foreign_keys = ON;
         CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
         CREATE TABLE IF NOT EXISTS sources (
             id INTEGER PRIMARY KEY,
             kind TEXT NOT NULL,
             title TEXT NOT NULL,
             origin TEXT,
             original_name TEXT,
             original_rel TEXT,
             mime TEXT,
             bytes INTEGER NOT NULL DEFAULT 0,
             text_hash TEXT NOT NULL,
             para TEXT NOT NULL,
             tags TEXT NOT NULL DEFAULT '',
             summary TEXT NOT NULL DEFAULT '',
             task_id INTEGER,
             rev INTEGER NOT NULL DEFAULT 1,
             supersedes INTEGER,
             added_at TEXT NOT NULL,
             added_by TEXT
         );
         CREATE TABLE IF NOT EXISTS chunks (
             id INTEGER PRIMARY KEY,
             source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
             ord INTEGER NOT NULL,
             text TEXT NOT NULL,
             tokens INTEGER NOT NULL
         );
         CREATE INDEX IF NOT EXISTS chunks_by_source ON chunks(source_id, ord);
         CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
             text, title, tags,
             tokenize = 'unicode61 remove_diacritics 2'
         );",
    )?;
    conn.execute(
        "INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version', ?1)",
        params![SCHEMA_VERSION.to_string()],
    )?;
    let version: i64 = conn
        .query_row(
            "SELECT value FROM meta WHERE key = 'schema_version'",
            [],
            |r| r.get::<_, String>(0),
        )?
        .parse()
        .unwrap_or(0);
    if version > SCHEMA_VERSION {
        bail!("{} was written by a newer SecondBrain", file.display());
    }
    Ok(Some(conn))
}

#[derive(Debug, Clone)]
pub struct Source {
    pub id: i64,
    pub kind: String,
    pub title: String,
    pub origin: Option<String>,
    pub original_name: Option<String>,
    pub original_rel: Option<String>,
    pub bytes: i64,
    pub para: String,
    pub tags: Vec<String>,
    pub summary: String,
    pub task_id: Option<i64>,
    pub rev: i64,
    pub supersedes: Option<i64>,
    pub added_at: String,
    pub added_by: Option<String>,
    pub chunks: i64,
    pub tokens: i64,
}

const SELECT: &str = "SELECT s.id, s.kind, s.title, s.origin, s.original_name, s.original_rel,
    s.bytes, s.para, s.tags, s.summary, s.task_id, s.rev, s.supersedes, s.added_at, s.added_by,
    (SELECT count(*) FROM chunks c WHERE c.source_id = s.id),
    (SELECT coalesce(sum(tokens), 0) FROM chunks c WHERE c.source_id = s.id)
    FROM sources s";
/// Sources that no later revision has replaced.
const CURRENT: &str = "s.id NOT IN (SELECT supersedes FROM sources WHERE supersedes IS NOT NULL)";

fn source_row(r: &Row) -> rusqlite::Result<Source> {
    Ok(Source {
        id: r.get(0)?,
        kind: r.get(1)?,
        title: r.get(2)?,
        origin: r.get(3)?,
        original_name: r.get(4)?,
        original_rel: r.get(5)?,
        bytes: r.get(6)?,
        para: r.get(7)?,
        tags: tags_from(&r.get::<_, String>(8)?),
        summary: r.get(9)?,
        task_id: r.get(10)?,
        rev: r.get(11)?,
        supersedes: r.get(12)?,
        added_at: r.get(13)?,
        added_by: r.get(14)?,
        chunks: r.get(15)?,
        tokens: r.get(16)?,
    })
}

fn tags_from(column: &str) -> Vec<String> {
    column
        .split(',')
        .filter(|t| !t.is_empty())
        .map(str::to_string)
        .collect()
}

fn tags_column(tags: &[String]) -> String {
    if tags.is_empty() {
        String::new()
    } else {
        format!(",{},", tags.join(","))
    }
}

/// Lowercase tags made of letters, digits, `-` and `_`; a comma also separates tags.
pub fn parse_tags(list: &[String]) -> Result<Vec<String>> {
    let mut out: Vec<String> = Vec::new();
    for raw in list {
        for tag in raw.split(',') {
            let tag = tag.trim().to_lowercase();
            if tag.is_empty() {
                continue;
            }
            if tag.chars().count() > 32
                || !tag
                    .chars()
                    .all(|c| c.is_alphanumeric() || c == '-' || c == '_')
            {
                bail!("invalid tag '{tag}': use letters, digits, - and _ (at most 32 characters)");
            }
            if !out.contains(&tag) {
                out.push(tag);
            }
        }
    }
    Ok(out)
}

pub fn check_para(value: &str) -> Result<String> {
    let para = value.trim().to_lowercase();
    if PARAS.contains(&para.as_str()) {
        Ok(para)
    } else {
        bail!("para must be one of project, area, resource or archive")
    }
}

fn check_kind(value: &str) -> Result<String> {
    let kind = value.trim().to_lowercase();
    if KINDS.contains(&kind.as_str()) {
        Ok(kind)
    } else {
        bail!("kind must be one of file, web, note, chat, connector or media")
    }
}

fn fnv64(text: &str) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in text.bytes() {
        h ^= u64::from(b);
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

fn fnv(text: &str) -> String {
    format!("{:016x}", fnv64(text))
}

fn clip(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_string();
    }
    let mut s: String = text.chars().take(max.saturating_sub(1)).collect();
    s.push('…');
    s
}

fn tokens(text: &str) -> usize {
    crate::ops::tokens(text)
}

/// Splits one long block at line boundaries (and inside a line only when it must).
fn hard_split(block: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut buf = String::new();
    for line in block.lines() {
        let mut rest = line;
        while rest.chars().count() > CHUNK_CHARS {
            if !buf.is_empty() {
                out.push(std::mem::take(&mut buf));
            }
            let cut = rest
                .char_indices()
                .nth(CHUNK_CHARS)
                .map_or(rest.len(), |(i, _)| i);
            out.push(rest[..cut].to_string());
            rest = &rest[cut..];
        }
        if !buf.is_empty() && buf.chars().count() + rest.chars().count() + 1 > CHUNK_CHARS {
            out.push(std::mem::take(&mut buf));
        }
        if !buf.is_empty() {
            buf.push('\n');
        }
        buf.push_str(rest);
    }
    if !buf.trim().is_empty() {
        out.push(buf);
    }
    out
}

/// Mechanical chunking: sections start at Markdown headings, paragraphs are packed up to
/// about 800 tokens, and small neighbouring sections share a chunk.
pub fn chunk_text(text: &str) -> Vec<String> {
    let mut sections: Vec<String> = Vec::new();
    let mut current = String::new();
    for line in text.lines() {
        if line.starts_with('#') && !current.trim().is_empty() {
            sections.push(std::mem::take(&mut current));
        }
        current.push_str(line);
        current.push('\n');
    }
    if !current.trim().is_empty() {
        sections.push(current);
    }
    let mut out: Vec<String> = Vec::new();
    let mut buf = String::new();
    for section in sections {
        if buf.chars().count() > CHUNK_CHARS / 4 {
            out.push(std::mem::take(&mut buf).trim().to_string());
        }
        for paragraph in section
            .split("\n\n")
            .map(str::trim)
            .filter(|p| !p.is_empty())
        {
            let pieces = if paragraph.chars().count() > CHUNK_CHARS {
                hard_split(paragraph)
            } else {
                vec![paragraph.to_string()]
            };
            for piece in pieces {
                let piece = piece.trim().to_string();
                if piece.is_empty() {
                    continue;
                }
                if !buf.is_empty() && buf.chars().count() + piece.chars().count() + 2 > CHUNK_CHARS
                {
                    out.push(std::mem::take(&mut buf).trim().to_string());
                }
                if !buf.is_empty() {
                    buf.push_str("\n\n");
                }
                buf.push_str(&piece);
            }
        }
    }
    if !buf.trim().is_empty() {
        out.push(buf.trim().to_string());
    }
    out
}

/// Secret and personal-data rules that match the text, as `rule xN`.
fn sensitive(text: &str) -> Vec<String> {
    let scope = Scope::default();
    let mut counts: BTreeMap<&'static str, usize> = BTreeMap::new();
    for (i, line) in text.lines().enumerate() {
        for f in check::scan_line("source.md", i + 1, line, "source", &scope) {
            if matches!(f.kind, Kind::Secret | Kind::Personal) {
                *counts.entry(f.rule).or_default() += 1;
            }
        }
    }
    counts
        .into_iter()
        .map(|(rule, n)| format!("{rule} x{n}"))
        .collect()
}

fn safe_name(name: &str) -> String {
    let cleaned: String = name
        .chars()
        .map(|c| {
            if c.is_alphanumeric() || matches!(c, '.' | '-' | '_') {
                c
            } else {
                '_'
            }
        })
        .collect();
    let cleaned = cleaned.trim_matches('.').to_string();
    let cleaned: String = cleaned.chars().take(80).collect();
    if cleaned.is_empty() {
        "original".into()
    } else {
        cleaned
    }
}

/// Copies the bytes of an original into the user's folder. The file is not read as text or
/// parsed; symlinks and files inside the data folder are refused.
fn keep_original(home: &Home, d: &Dossier, id: i64, from: &Path) -> Result<(String, String, u64)> {
    let meta = fs::symlink_metadata(from).with_context(|| format!("reading {}", from.display()))?;
    if meta.file_type().is_symlink() || !meta.is_file() {
        bail!("{} is not a regular file", from.display());
    }
    let absolute = fs::canonicalize(from).with_context(|| format!("reading {}", from.display()))?;
    let root = fs::canonicalize(&home.root).unwrap_or_else(|_| home.root.clone());
    if absolute.starts_with(&root) {
        bail!("the original is already inside the SecondBrain folder; pass a file from elsewhere");
    }
    let name = absolute
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    let stored = format!("{id}-{}", safe_name(&name));
    let dir = originals_dir(home, d)?;
    fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
    let target = dir.join(&stored);
    let tmp = dir.join(format!(".{stored}.{}.tmp", crate::store::unique_token()));
    let bytes = fs::copy(&absolute, &tmp).with_context(|| format!("copying {}", from.display()))?;
    if let Err(e) = fs::rename(&tmp, &target) {
        let _ = fs::remove_file(&tmp);
        return Err(e).with_context(|| format!("saving {}", target.display()));
    }
    Ok((name, stored, bytes))
}

pub struct NewSource<'a> {
    pub title: &'a str,
    pub text: &'a str,
    pub kind: Option<&'a str>,
    pub origin: Option<&'a str>,
    pub original: Option<&'a Path>,
    pub para: Option<&'a str>,
    pub tags: Vec<String>,
    pub summary: Option<&'a str>,
    pub task: Option<u32>,
    pub by: Option<&'a str>,
    pub allow_sensitive: bool,
}

pub struct Added {
    pub id: i64,
    pub rev: i64,
    pub chunks: usize,
    pub tokens: usize,
    pub original: Option<String>,
}

impl Added {
    pub fn text(&self, title: &str) -> String {
        let mut s = format!(
            "Added source #{} \"{}\" (rev {}, {} chunks, ~{} tokens).\n",
            self.id,
            clip(title, 80),
            self.rev,
            self.chunks,
            self.tokens
        );
        if let Some(path) = &self.original {
            s.push_str(&format!(
                "The original was copied to {path}. sb never opens it again; it is for you only.\n"
            ));
        }
        s
    }
}

fn reindex(conn: &Connection, id: i64) -> Result<()> {
    conn.execute(
        "DELETE FROM chunks_fts WHERE rowid IN (SELECT id FROM chunks WHERE source_id = ?1)",
        params![id],
    )?;
    conn.execute(
        "INSERT INTO chunks_fts (rowid, text, title, tags)
         SELECT c.id, c.text, s.title, s.tags FROM chunks c
         JOIN sources s ON s.id = c.source_id WHERE s.id = ?1",
        params![id],
    )?;
    Ok(())
}

/// Stores extracted text as a source; returns what was stored.
pub fn add(home: &Home, d: &Dossier, new: NewSource) -> Result<Added> {
    let title: String = one_line(new.title).chars().take(200).collect();
    if title.is_empty() {
        bail!("a source needs a title");
    }
    let text = new.text.replace("\r\n", "\n");
    let text = text.trim();
    if text.is_empty() {
        bail!("the extracted text is empty");
    }
    if text.len() > MAX_TEXT_BYTES {
        bail!(
            "the extracted text is {} bytes; the limit is {MAX_TEXT_BYTES}. Split it into several sources",
            text.len()
        );
    }
    if !new.allow_sensitive {
        let found = sensitive(text);
        if !found.is_empty() {
            bail!(
                "the text looks like it holds secrets or personal data ({}). Ask the user whether to keep it, then repeat with allow_sensitive (--allow-sensitive)",
                found.join(", ")
            );
        }
    }
    if let Some(task) = new.task {
        d.task(task)?;
    }
    let kind = match new.kind {
        Some(k) => check_kind(k)?,
        None if new.original.is_some() => "file".into(),
        None => "note".into(),
    };
    let para = match new.para {
        Some(p) => check_para(p)?,
        None if new.task.is_some() => "project".into(),
        None => "resource".into(),
    };
    let summary: String = one_line(new.summary.unwrap_or_default())
        .chars()
        .take(600)
        .collect();
    let origin = new.origin.map(one_line).filter(|o| !o.is_empty());
    let hash = fnv(text);
    let chunks = chunk_text(text);

    let mut conn = connect(d, true)?.expect("created");
    let tx = conn.transaction()?;
    if let Some(existing) = tx
        .query_row(
            "SELECT id FROM sources WHERE text_hash = ?1",
            params![hash],
            |r| r.get::<_, i64>(0),
        )
        .optional()?
    {
        bail!("the same text is already stored as source #{existing}");
    }
    let previous: Option<(i64, i64)> = match &origin {
        Some(o) => tx
            .query_row(
                "SELECT id, rev FROM sources WHERE origin = ?1 ORDER BY rev DESC LIMIT 1",
                params![o],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?,
        None => None,
    };
    let rev = previous.map_or(1, |(_, rev)| rev + 1);
    tx.execute(
        "INSERT INTO sources (kind, title, origin, text_hash, para, tags, summary, task_id, rev,
                              supersedes, added_at, added_by)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
        params![
            kind,
            title,
            origin,
            hash,
            para,
            tags_column(&new.tags),
            summary,
            new.task,
            rev,
            previous.map(|(id, _)| id),
            crate::date::today(),
            new.by.map(one_line).filter(|b| !b.is_empty()),
        ],
    )?;
    let id = tx.last_insert_rowid();
    let mut total = 0;
    for (i, chunk) in chunks.iter().enumerate() {
        let cost = tokens(chunk);
        total += cost;
        tx.execute(
            "INSERT INTO chunks (source_id, ord, text, tokens) VALUES (?1, ?2, ?3, ?4)",
            params![id, i as i64, chunk, cost as i64],
        )?;
    }
    reindex(&tx, id)?;
    let mut original = None;
    if let Some(from) = new.original {
        let (name, stored, bytes) = keep_original(home, d, id, from)?;
        tx.execute(
            "UPDATE sources SET original_name = ?2, original_rel = ?3, bytes = ?4 WHERE id = ?1",
            params![id, name, stored, bytes as i64],
        )?;
        original = Some(originals_dir(home, d)?.join(&stored).display().to_string());
    }
    tx.commit()?;
    Ok(Added {
        id,
        rev,
        chunks: chunks.len(),
        tokens: total,
        original,
    })
}

#[derive(Default)]
pub struct Filter<'a> {
    pub para: Option<&'a str>,
    pub tag: Option<&'a str>,
    pub task: Option<u32>,
}

/// Current sources (not replaced by a later revision), newest first, archive last.
pub fn list(d: &Dossier, filter: &Filter) -> Result<Vec<Source>> {
    let Some(conn) = connect(d, false)? else {
        return Ok(Vec::new());
    };
    let para = filter.para.map(check_para).transpose()?;
    let tag = filter
        .tag
        .map(|t| parse_tags(&[t.to_string()]))
        .transpose()?
        .and_then(|t| t.into_iter().next());
    let mut stmt = conn.prepare(&format!(
        "{SELECT} WHERE {CURRENT} ORDER BY (s.para = 'archive'), s.id DESC"
    ))?;
    let rows = stmt.query_map([], source_row)?;
    let mut out = Vec::new();
    for row in rows {
        let s = row?;
        if para.as_ref().is_some_and(|p| &s.para != p)
            || tag.as_ref().is_some_and(|t| !s.tags.contains(t))
            || filter.task.is_some_and(|t| s.task_id != Some(i64::from(t)))
        {
            continue;
        }
        out.push(s);
    }
    Ok(out)
}

pub fn get(d: &Dossier, id: i64) -> Result<Source> {
    let conn = connect(d, false)?.ok_or_else(|| anyhow!("no source #{id}: none stored yet"))?;
    conn.query_row(
        &format!("{SELECT} WHERE s.id = ?1"),
        params![id],
        source_row,
    )
    .optional()?
    .ok_or_else(|| anyhow!("no source #{id}; list them with `sb kb list`"))
}

pub fn line(s: &Source) -> String {
    let mut line = format!("#{} [{}] {}", s.id, s.para, clip(&s.title, 90));
    if !s.tags.is_empty() {
        line.push_str(&format!(" ({})", s.tags.join(", ")));
    }
    if let Some(t) = s.task_id {
        line.push_str(&format!(" task #{t}"));
    }
    if s.rev > 1 {
        line.push_str(&format!(" rev {}", s.rev));
    }
    line
}

pub fn list_json(sources: &[Source]) -> serde_json::Value {
    serde_json::Value::Array(
        sources
            .iter()
            .map(|s| {
                serde_json::json!({
                    "id": s.id,
                    "kind": s.kind,
                    "title": s.title,
                    "para": s.para,
                    "tags": s.tags,
                    "summary": s.summary,
                    "task": s.task_id,
                    "origin": s.origin,
                    "original": s.original_name,
                    "rev": s.rev,
                    "chunks": s.chunks,
                    "tokens": s.tokens,
                    "added": s.added_at,
                })
            })
            .collect(),
    )
}

pub fn list_text(sources: &[Source]) -> String {
    if sources.is_empty() {
        return "No sources. Add one with `sb kb add`.\n".into();
    }
    let mut s = String::new();
    for src in sources {
        s.push_str(&format!("- {}\n", line(src)));
    }
    s
}

/// One source: header, summary and its chunks (all, one, or as many as the budget allows).
pub fn show(d: &Dossier, id: i64, chunk: Option<usize>, budget: Option<usize>) -> Result<String> {
    let src = get(d, id)?;
    let conn = connect(d, false)?.expect("source exists");
    let mut s = format!("# {}\n\n", line(&src));
    s.push_str(&format!(
        "- Kind: {} · added {}{} · {} chunks, ~{} tokens\n",
        src.kind,
        src.added_at,
        src.added_by
            .as_deref()
            .map(|b| format!(" by {b}"))
            .unwrap_or_default(),
        src.chunks,
        src.tokens
    ));
    if let Some(o) = &src.origin {
        s.push_str(&format!("- Origin: {o}\n"));
    }
    if let Some(name) = &src.original_name {
        s.push_str(&format!(
            "- Original: {name} (kept outside sb for the user; sb does not open it)\n"
        ));
    }
    if let Some(prev) = src.supersedes {
        s.push_str(&format!("- Replaces source #{prev}\n"));
    }
    if !src.summary.is_empty() {
        s.push_str(&format!("\nSummary: {}\n", src.summary));
    }
    let mut stmt =
        conn.prepare("SELECT ord, text, tokens FROM chunks WHERE source_id = ?1 ORDER BY ord")?;
    let rows: Vec<(i64, String, i64)> = stmt
        .query_map(params![id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
        .collect::<rusqlite::Result<_>>()?;
    let total = rows.len();
    if let Some(n) = chunk {
        let Some((_, text, _)) = rows.iter().find(|(ord, _, _)| *ord + 1 == n as i64) else {
            bail!("source #{id} has {total} chunks; choose 1 to {total}");
        };
        s.push_str(&format!("\n[chunk {n}/{total}]\n{text}\n"));
        return Ok(s);
    }
    let mut used = tokens(&s);
    for (i, (_, text, cost)) in rows.iter().enumerate() {
        if budget.is_some_and(|b| used + *cost as usize > b) && i > 0 {
            s.push_str(&format!(
                "\n... {} more chunks: `sb kb show {id} --chunk {}`\n",
                total - i,
                i + 1
            ));
            return Ok(s);
        }
        used += *cost as usize;
        s.push_str(&format!("\n[chunk {}/{total}]\n{text}\n", i + 1));
    }
    Ok(s)
}

pub struct Hit {
    pub id: i64,
    pub title: String,
    pub para: String,
    pub chunk: usize,
    pub snippet: String,
}

/// Ranked hits (best chunk per source). Every word must match (prefixes count); when nothing
/// does, any word is enough. Archived sources rank lower.
pub fn search(d: &Dossier, query: &str, para: Option<&str>, limit: usize) -> Result<Vec<Hit>> {
    let words = crate::index::terms(query);
    if words.is_empty() {
        bail!("the search text is empty");
    }
    let para = para.map(check_para).transpose()?;
    let Some(conn) = connect(d, false)? else {
        return Ok(Vec::new());
    };
    let run = |expr: &str| -> Result<Vec<Hit>> {
        let mut stmt = conn.prepare(&format!(
            "SELECT s.id, s.title, s.para, c.ord,
                    snippet(chunks_fts, 0, '[', ']', '…', 14),
                    bm25(chunks_fts, 1.0, 3.0, 2.0)
                      + CASE s.para WHEN 'archive' THEN 3.0 ELSE 0.0 END AS score
             FROM chunks_fts
             JOIN chunks c ON c.id = chunks_fts.rowid
             JOIN sources s ON s.id = c.source_id
             WHERE chunks_fts MATCH ?1 AND {CURRENT}
             ORDER BY score LIMIT 300"
        ))?;
        let rows = stmt.query_map(params![expr], |r| {
            Ok(Hit {
                id: r.get(0)?,
                title: r.get(1)?,
                para: r.get(2)?,
                chunk: r.get::<_, i64>(3)? as usize + 1,
                snippet: one_line(&r.get::<_, String>(4)?),
            })
        })?;
        let mut seen = Vec::new();
        let mut out = Vec::new();
        for hit in rows {
            let hit = hit?;
            if para.as_ref().is_some_and(|p| &hit.para != p) || seen.contains(&hit.id) {
                continue;
            }
            seen.push(hit.id);
            out.push(hit);
            if out.len() >= limit {
                break;
            }
        }
        Ok(out)
    };
    let mut hits = run(&words.join(" AND "))?;
    if hits.is_empty() && words.len() > 1 {
        hits = run(&words.join(" OR "))?;
    }
    Ok(hits)
}

pub fn hit_line(h: &Hit) -> String {
    format!(
        "src#{} [{}] {} (chunk {}): {}",
        h.id,
        h.para,
        clip(&h.title, 80),
        h.chunk,
        clip(&h.snippet, 200)
    )
}

pub fn search_text(d: &Dossier, query: &str, para: Option<&str>, limit: usize) -> Result<String> {
    let hits = search(d, query, para, limit.max(1))?;
    if hits.is_empty() {
        return Ok("No matching sources.\n".into());
    }
    let mut s = String::new();
    for h in &hits {
        s.push_str(&format!("- {}\n", hit_line(h)));
    }
    s.push_str("Read one with `sb kb show <ID>` (add --chunk N for a single chunk).\n");
    Ok(s)
}

#[derive(Default)]
pub struct Update {
    pub title: Option<String>,
    pub para: Option<String>,
    pub summary: Option<String>,
    pub add_tags: Vec<String>,
    pub remove_tags: Vec<String>,
    /// `Some(0)` clears the task link.
    pub task: Option<u32>,
}

/// Changes the organization of a source; the text and the original stay as they are.
pub fn update(d: &Dossier, id: i64, change: &Update) -> Result<Source> {
    let current = get(d, id)?;
    let conn = connect(d, false)?.expect("source exists");
    let mut tags = current.tags.clone();
    for t in parse_tags(&change.add_tags)? {
        if !tags.contains(&t) {
            tags.push(t);
        }
    }
    let remove = parse_tags(&change.remove_tags)?;
    tags.retain(|t| !remove.contains(t));
    let title = match &change.title {
        Some(t) => {
            let t: String = one_line(t).chars().take(200).collect();
            if t.is_empty() {
                bail!("a source needs a title");
            }
            t
        }
        None => current.title.clone(),
    };
    let para = match &change.para {
        Some(p) => check_para(p)?,
        None => current.para.clone(),
    };
    let summary: String = match &change.summary {
        Some(s) => one_line(s).chars().take(600).collect(),
        None => current.summary.clone(),
    };
    let task = match change.task {
        Some(0) => None,
        Some(t) => {
            d.task(t)?;
            Some(i64::from(t))
        }
        None => current.task_id,
    };
    conn.execute(
        "UPDATE sources SET title = ?2, para = ?3, summary = ?4, tags = ?5, task_id = ?6 WHERE id = ?1",
        params![id, title, para, summary, tags_column(&tags), task],
    )?;
    reindex(&conn, id)?;
    get(d, id)
}

/// Deletes a source and its chunks. The original, if any, is left where it is.
pub fn remove(home: &Home, d: &Dossier, id: i64) -> Result<String> {
    let src = get(d, id)?;
    let mut conn = connect(d, false)?.expect("source exists");
    let tx = conn.transaction()?;
    tx.execute(
        "DELETE FROM chunks_fts WHERE rowid IN (SELECT id FROM chunks WHERE source_id = ?1)",
        params![id],
    )?;
    tx.execute(
        "UPDATE sources SET supersedes = ?2 WHERE supersedes = ?1",
        params![id, src.supersedes],
    )?;
    tx.execute("DELETE FROM sources WHERE id = ?1", params![id])?;
    tx.commit()?;
    let mut s = format!("Removed source #{id} \"{}\".\n", clip(&src.title, 80));
    if let Some(rel) = &src.original_rel {
        let path = originals_dir(home, d)?.join(rel);
        s.push_str(&format!(
            "Its original stays at {}; sb never deletes originals.\n",
            path.display()
        ));
    }
    Ok(s)
}

/// Counts, size and originals that no source refers to (names only; no file is opened).
pub fn stats(home: &Home, d: &Dossier) -> Result<String> {
    let sources = list(d, &Filter::default())?;
    let mut s = String::from("Sources\n");
    for para in PARAS {
        let n = sources.iter().filter(|x| x.para == *para).count();
        s.push_str(&format!("- {para:<9} {n}\n"));
    }
    let chunks: i64 = sources.iter().map(|x| x.chunks).sum();
    let toks: i64 = sources.iter().map(|x| x.tokens).sum();
    s.push_str(&format!(
        "- total     {} sources, {chunks} chunks, ~{toks} tokens\n",
        sources.len()
    ));
    if let Ok(meta) = fs::metadata(db_path(d)) {
        s.push_str(&format!("- database  {} KiB\n", meta.len().div_ceil(1024)));
    }
    let dir = originals_dir(home, d)?;
    s.push_str(&format!("- originals {}\n", dir.display()));
    if let Ok(entries) = fs::read_dir(&dir) {
        let known: Vec<String> = connect(d, false)?
            .map(|conn| {
                conn.prepare("SELECT original_rel FROM sources WHERE original_rel IS NOT NULL")
                    .and_then(|mut st| {
                        st.query_map([], |r| r.get::<_, String>(0))?
                            .collect::<rusqlite::Result<Vec<String>>>()
                    })
                    .unwrap_or_default()
            })
            .unwrap_or_default();
        let orphans: Vec<String> = entries
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().to_string())
            .filter(|n| !n.ends_with(".tmp") && !known.contains(n))
            .collect();
        if !orphans.is_empty() {
            s.push_str(&format!(
                "- {} originals without a source: {}\n",
                orphans.len(),
                orphans.join(", ")
            ));
        }
    }
    Ok(s)
}

/// Chunks with fewer words than this are only compared for exact duplicates.
const NEAR_MIN_WORDS: usize = 12;
/// Largest Hamming distance between two simhashes that counts as a near duplicate.
const NEAR_DISTANCE: u32 = 3;
const BLOB_MIN: usize = 120;

fn mix(mut x: u64) -> u64 {
    x ^= x >> 30;
    x = x.wrapping_mul(0xbf58_476d_1ce4_e5b9);
    x ^= x >> 27;
    x = x.wrapping_mul(0x94d0_49bb_1331_11eb);
    x ^ (x >> 31)
}

/// 64-bit simhash over three-word shingles; None for text too short to compare.
fn simhash(text: &str) -> Option<u64> {
    let words: Vec<String> = text
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(str::to_lowercase)
        .collect();
    if words.len() < NEAR_MIN_WORDS {
        return None;
    }
    let mut votes = [0_i32; 64];
    for shingle in words.windows(3) {
        let h = mix(fnv64(&shingle.join(" ")));
        for (bit, vote) in votes.iter_mut().enumerate() {
            *vote += if (h >> bit) & 1 == 1 { 1 } else { -1 };
        }
    }
    Some(
        votes
            .iter()
            .enumerate()
            .filter(|(_, v)| **v > 0)
            .fold(0, |acc, (bit, _)| acc | (1_u64 << bit)),
    )
}

fn is_blob_char(c: char) -> bool {
    c.is_ascii_alphanumeric() || matches!(c, '+' | '/' | '=' | '_' | '-')
}

/// Drops a line that is one base64 blob and cuts blobs that follow `base64,`; returns the
/// cleaned line and how many blobs went.
fn strip_blobs(line: &str) -> (String, usize) {
    let trimmed = line.trim();
    if trimmed.len() >= BLOB_MIN && trimmed.chars().all(is_blob_char) {
        return (String::new(), 1);
    }
    let mut out = String::new();
    let mut rest = line;
    let mut blobs = 0;
    while let Some(i) = rest.find("base64,") {
        let start = i + "base64,".len();
        out.push_str(&rest[..start]);
        let tail = &rest[start..];
        let run = tail.find(|c: char| !is_blob_char(c)).unwrap_or(tail.len());
        if run >= BLOB_MIN {
            blobs += 1;
            out.push_str("[blob removed]");
        } else {
            out.push_str(&tail[..run]);
        }
        rest = &tail[run..];
    }
    out.push_str(rest);
    (out, blobs)
}

fn repeatable(line: &str) -> bool {
    let n = line.chars().count();
    (8..=100).contains(&n)
        && !line.starts_with(['#', '-', '*', '|', '>'])
        && line.chars().any(char::is_alphanumeric)
}

struct ChunkRow {
    id: i64,
    source: i64,
    text: String,
    cleaned: String,
}

/// Short lines that open or close pages: present in at least three chunks of one source.
fn repeated_lines(group: &[ChunkRow]) -> HashSet<String> {
    let mut seen: HashMap<&str, usize> = HashMap::new();
    for row in group {
        let unique: HashSet<&str> = row
            .text
            .lines()
            .map(str::trim)
            .filter(|l| repeatable(l))
            .collect();
        for line in unique {
            *seen.entry(line).or_default() += 1;
        }
    }
    seen.into_iter()
        .filter(|(_, n)| *n >= 3)
        .map(|(l, _)| l.to_string())
        .collect()
}

#[derive(Debug, Default, Clone, PartialEq)]
pub struct Compaction {
    pub dry_run: bool,
    pub superseded: usize,
    pub exact: usize,
    pub near: usize,
    pub emptied: usize,
    pub header_lines: usize,
    pub blobs: usize,
    pub chunks_before: i64,
    pub chunks_after: i64,
    pub tokens_before: i64,
    pub tokens_after: i64,
    pub bytes_before: u64,
    pub bytes_after: u64,
}

impl Compaction {
    pub fn text(&self) -> String {
        let mut s = if self.dry_run {
            String::from("Dry run: nothing was changed. A real run would remove:\n")
        } else {
            String::from("Compacted the sources:\n")
        };
        s.push_str(&format!(
            "- superseded revisions: {}\n- exact duplicate chunks: {}\n- near-duplicate chunks: {}\n- chunks left empty by cleaning: {}\n- repeated header/footer lines: {}\n- base64 blobs: {}\n",
            self.superseded, self.exact, self.near, self.emptied, self.header_lines, self.blobs
        ));
        s.push_str(&format!(
            "- chunks {} -> {}, ~{} -> ~{} tokens\n",
            self.chunks_before, self.chunks_after, self.tokens_before, self.tokens_after
        ));
        if !self.dry_run {
            s.push_str(&format!(
                "- database {} KiB -> {} KiB (vacuumed, search index optimized)\n",
                self.bytes_before.div_ceil(1024),
                self.bytes_after.div_ceil(1024)
            ));
        }
        s
    }
}

fn totals(conn: &Connection) -> Result<(i64, i64)> {
    Ok(conn.query_row(
        "SELECT count(*), coalesce(sum(tokens), 0) FROM chunks",
        [],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?)
}

/// Mechanical compaction: superseded revisions, repeated headers and footers, base64 blobs,
/// exact duplicate chunks and near-duplicate chunks (simhash). The first copy is kept, and
/// a source never loses its last chunk. With `dry_run` the work is rolled back.
pub fn compact(d: &Dossier, dry_run: bool) -> Result<Compaction> {
    let mut report = Compaction {
        dry_run,
        ..Default::default()
    };
    let Some(mut conn) = connect(d, false)? else {
        return Ok(report);
    };
    let size = || fs::metadata(db_path(d)).map_or(0, |m| m.len());
    report.bytes_before = size();
    let tx = conn.transaction()?;
    (report.chunks_before, report.tokens_before) = totals(&tx)?;

    let old: Vec<i64> = {
        let mut stmt = tx.prepare(
            "SELECT id FROM sources WHERE id IN (SELECT supersedes FROM sources WHERE supersedes IS NOT NULL)",
        )?;
        stmt.query_map([], |r| r.get(0))?
            .collect::<rusqlite::Result<_>>()?
    };
    for id in &old {
        tx.execute(
            "DELETE FROM chunks_fts WHERE rowid IN (SELECT id FROM chunks WHERE source_id = ?1)",
            params![id],
        )?;
        tx.execute("DELETE FROM sources WHERE id = ?1", params![id])?;
    }
    tx.execute(
        "UPDATE sources SET supersedes = NULL
         WHERE supersedes IS NOT NULL AND supersedes NOT IN (SELECT id FROM sources)",
        [],
    )?;
    report.superseded = old.len();

    let mut rows: Vec<ChunkRow> = {
        let mut stmt =
            tx.prepare("SELECT id, source_id, text FROM chunks ORDER BY source_id, ord")?;
        stmt.query_map([], |r| {
            let text: String = r.get(2)?;
            Ok(ChunkRow {
                id: r.get(0)?,
                source: r.get(1)?,
                cleaned: text.clone(),
                text,
            })
        })?
        .collect::<rusqlite::Result<_>>()?
    };

    for group in rows.chunk_by_mut(|a, b| a.source == b.source) {
        let repeated = if group.len() >= 3 {
            repeated_lines(group)
        } else {
            HashSet::new()
        };
        for row in group.iter_mut() {
            let mut lines: Vec<String> = Vec::new();
            let mut changed = false;
            for line in row.text.lines() {
                if repeated.contains(line.trim()) {
                    report.header_lines += 1;
                    changed = true;
                    continue;
                }
                let (clean, blobs) = strip_blobs(line);
                if blobs > 0 {
                    report.blobs += blobs;
                    changed = true;
                    if clean.trim().is_empty() {
                        continue;
                    }
                }
                lines.push(clean);
            }
            if changed {
                row.cleaned = lines.join("\n").trim().to_string();
            }
        }
    }

    let mut remaining: HashMap<i64, usize> = HashMap::new();
    for row in &rows {
        *remaining.entry(row.source).or_default() += 1;
    }
    let mut seen_exact: HashSet<u64> = HashSet::new();
    let mut seen_near: Vec<u64> = Vec::new();
    let mut removed: Vec<i64> = Vec::new();
    let mut rewritten: Vec<(i64, String, i64)> = Vec::new();
    let mut touched: BTreeSet<i64> = BTreeSet::new();
    for row in &mut rows {
        let normalized = row.cleaned.split_whitespace().collect::<Vec<_>>().join(" ");
        let exact = fnv64(&normalized);
        let near = simhash(&normalized);
        let reason = if normalized.is_empty() {
            Some(0)
        } else if seen_exact.contains(&exact) {
            Some(1)
        } else if near.is_some_and(|h| {
            seen_near
                .iter()
                .any(|s| (s ^ h).count_ones() <= NEAR_DISTANCE)
        }) {
            Some(2)
        } else {
            None
        };
        let left = remaining.entry(row.source).or_default();
        if let Some(reason) = reason.filter(|_| *left > 1) {
            *left -= 1;
            removed.push(row.id);
            touched.insert(row.source);
            match reason {
                0 => report.emptied += 1,
                1 => report.exact += 1,
                _ => report.near += 1,
            }
            continue;
        }
        if normalized.is_empty() {
            // The last chunk of a source stays as it was.
            row.cleaned = row.text.clone();
        } else {
            seen_exact.insert(exact);
            seen_near.extend(near);
        }
        if row.cleaned != row.text {
            let cost = tokens(&row.cleaned) as i64;
            rewritten.push((row.id, row.cleaned.clone(), cost));
            touched.insert(row.source);
        }
    }

    for id in &removed {
        tx.execute("DELETE FROM chunks_fts WHERE rowid = ?1", params![id])?;
        tx.execute("DELETE FROM chunks WHERE id = ?1", params![id])?;
    }
    for (id, text, cost) in &rewritten {
        tx.execute(
            "UPDATE chunks SET text = ?2, tokens = ?3 WHERE id = ?1",
            params![id, text, cost],
        )?;
    }
    for source in &touched {
        let ids: Vec<i64> = {
            let mut stmt = tx.prepare("SELECT id FROM chunks WHERE source_id = ?1 ORDER BY ord")?;
            stmt.query_map(params![source], |r| r.get(0))?
                .collect::<rusqlite::Result<_>>()?
        };
        for (ord, id) in ids.iter().enumerate() {
            tx.execute(
                "UPDATE chunks SET ord = ?2 WHERE id = ?1",
                params![id, ord as i64],
            )?;
        }
        reindex(&tx, *source)?;
    }
    (report.chunks_after, report.tokens_after) = totals(&tx)?;

    if dry_run {
        tx.rollback()?;
        report.bytes_after = report.bytes_before;
        return Ok(report);
    }
    tx.commit()?;
    conn.execute_batch("INSERT INTO chunks_fts(chunks_fts) VALUES('optimize');")?;
    conn.execute_batch("VACUUM;")?;
    let _ = conn.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()));
    report.bytes_after = size();
    Ok(report)
}

/// A short "Sources" section for the repository context; None when there are none.
pub fn overview(d: &Dossier, budget_left: Option<usize>) -> Result<Option<String>> {
    let sources = list(d, &Filter::default())?;
    if sources.is_empty() {
        return Ok(None);
    }
    let counts: Vec<String> = PARAS
        .iter()
        .map(|p| format!("{p} {}", sources.iter().filter(|s| s.para == *p).count()))
        .collect();
    let mut s = format!(
        "\n## Sources ({}: {})\n\n",
        sources.len(),
        counts.join(", ")
    );
    let with_summary = budget_left.is_none_or(|l| l >= 300);
    let shown = if budget_left.is_some_and(|l| l < 120) {
        0
    } else {
        5
    };
    for src in sources.iter().filter(|x| x.para != "archive").take(shown) {
        s.push_str(&format!(
            "- src#{} [{}] {}",
            src.id,
            src.para,
            clip(&src.title, 80)
        ));
        if with_summary && !src.summary.is_empty() {
            s.push_str(&format!(": {}", clip(&src.summary, 120)));
        }
        s.push('\n');
    }
    s.push_str("- Search: `sb kb search <words>`; read: `sb kb show <ID>` (MCP `search_sources`, `get_source`)\n");
    Ok(Some(s))
}

/// Titles and summaries of the sources, for `sb check` to keep out of repositories.
pub fn needles(d: &Dossier) -> Vec<String> {
    list(d, &Filter::default())
        .unwrap_or_default()
        .into_iter()
        .flat_map(|s| [s.title, s.summary])
        .map(|t| t.trim().to_lowercase())
        .filter(|t| t.chars().count() >= 12)
        .collect()
}

/// Checks the database opens and answers; used by `sb doctor`.
pub fn check(d: &Dossier) -> Result<()> {
    let Some(conn) = connect(d, false)? else {
        return Ok(());
    };
    let state: String = conn.query_row("PRAGMA integrity_check", [], |r| r.get(0))?;
    if state != "ok" {
        bail!("integrity check: {state}");
    }
    conn.query_row("SELECT count(*) FROM chunks", [], |r| r.get::<_, i64>(0))?;
    Ok(())
}

/// Format of a repository pack (`.sbkb`): the kb tables plus `dossier_files`.
const PACK_FORMAT: &str = "1";

fn read_text(path: &Path) -> Result<Option<String>> {
    match fs::read_to_string(path) {
        Ok(text) => Ok(Some(text)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e).with_context(|| format!("reading {}", path.display())),
    }
}

/// Paths a pack may carry: the dossier files and task files, nothing else.
fn pack_path_ok(path: &str) -> bool {
    match path.strip_prefix("tasks/") {
        Some(name) => {
            name.ends_with(".md")
                && !name.starts_with('.')
                && !name
                    .chars()
                    .any(|c| c.is_control() || matches!(c, '/' | '\\' | ':'))
        }
        None => matches!(path, "context.md" | "decisions.md" | "rules.md"),
    }
}

/// context, decisions, rules and task files of a dossier, as `(pack path, text)`.
fn dossier_files(d: &Dossier) -> Result<Vec<(String, String)>> {
    let mut out = Vec::new();
    for name in ["context.md", "decisions.md", "rules.md"] {
        if let Some(text) = read_text(&d.dir.join(name))? {
            out.push((name.to_string(), text));
        }
    }
    for (path, _) in d.task_files()? {
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or_else(|| anyhow!("task file name is not text: {}", path.display()))?;
        let rel = format!("tasks/{name}");
        if !pack_path_ok(&rel) {
            bail!("task file {name} has a name a pack cannot carry");
        }
        let text = fs::read_to_string(&path)?;
        out.push((rel, text));
    }
    Ok(out)
}

/// Writes the sources of `d` and its context, decisions, rules and tasks to a new SQLite file.
/// No original files and no checkout paths are included.
pub fn export_pack(d: &Dossier, out: &Path) -> Result<String> {
    if out.exists() {
        bail!(
            "{} exists already; choose a file that does not exist",
            out.display()
        );
    }
    let build = || -> Result<(i64, usize)> {
        let conn = connect(d, true)?.expect("created");
        conn.execute("VACUUM INTO ?1", params![out.to_string_lossy()])?;
        drop(conn);
        let mut pack = Connection::open(out)?;
        pack.execute_batch(
            "PRAGMA journal_mode = DELETE;
             UPDATE sources SET original_name = NULL, original_rel = NULL;
             CREATE TABLE dossier_files (path TEXT PRIMARY KEY, content TEXT NOT NULL);",
        )?;
        let files = dossier_files(d)?;
        let tx = pack.transaction()?;
        for (key, value) in [
            ("pack_format", PACK_FORMAT),
            ("pack_identity", d.meta.identity.as_str()),
        ] {
            tx.execute(
                "INSERT OR REPLACE INTO meta (key, value) VALUES (?1, ?2)",
                params![key, value],
            )?;
        }
        for (path, content) in &files {
            tx.execute(
                "INSERT INTO dossier_files (path, content) VALUES (?1, ?2)",
                params![path, content],
            )?;
        }
        tx.commit()?;
        let sources = pack.query_row(
            &format!("SELECT count(*) FROM sources s WHERE {CURRENT}"),
            [],
            |r| r.get(0),
        )?;
        Ok((sources, files.len()))
    };
    match build() {
        Ok((sources, files)) => Ok(format!(
            "Wrote {} ({sources} source(s), {files} dossier file(s); no originals, no paths)\n",
            out.display()
        )),
        Err(e) => {
            let _ = fs::remove_file(out);
            Err(e)
        }
    }
}

/// Opens a pack read-only and checks its format and schema; returns it with its identity.
fn open_pack(pack: &Path) -> Result<(Connection, String)> {
    if !pack.is_file() {
        bail!("{} is not a file", pack.display());
    }
    let conn = Connection::open_with_flags(pack, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
        .with_context(|| format!("opening {}", pack.display()))?;
    let meta = |key: &str| -> Result<Option<String>> {
        conn.query_row("SELECT value FROM meta WHERE key = ?1", params![key], |r| {
            r.get(0)
        })
        .optional()
        .map_err(|_| anyhow!("{} is not a SecondBrain pack", pack.display()))
    };
    let (Some(format), Some(schema), Some(identity)) = (
        meta("pack_format")?,
        meta("schema_version")?,
        meta("pack_identity")?,
    ) else {
        bail!("{} is not a SecondBrain pack", pack.display());
    };
    if format != PACK_FORMAT || schema.parse::<i64>().unwrap_or(i64::MAX) > SCHEMA_VERSION {
        bail!(
            "{} was written by a newer SecondBrain (pack format {format}, schema {schema})",
            pack.display()
        );
    }
    conn.query_row("SELECT count(*) FROM dossier_files", [], |r| {
        r.get::<_, i64>(0)
    })
    .map_err(|_| anyhow!("{} is not a SecondBrain pack", pack.display()))?;
    Ok((conn, identity))
}

/// The repository identity a pack was exported from (after the format and schema checks).
pub fn pack_identity(pack: &Path) -> Result<String> {
    Ok(open_pack(pack)?.1)
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum PackMode {
    Merge,
    Replace,
}

struct PackSource {
    id: i64,
    kind: String,
    title: String,
    origin: Option<String>,
    mime: Option<String>,
    bytes: i64,
    text_hash: String,
    para: String,
    tags: String,
    summary: String,
    task_id: Option<i64>,
    rev: i64,
    supersedes: Option<i64>,
    added_at: String,
    added_by: Option<String>,
}

/// Secrets and personal data anywhere in the pack, as `where: rule xN`.
fn pack_findings(conn: &Connection, files: &[(String, String)]) -> Result<Vec<String>> {
    let mut found = Vec::new();
    for (path, content) in files {
        let hits = sensitive(content);
        if !hits.is_empty() {
            found.push(format!("{path}: {}", hits.join(", ")));
        }
    }
    let mut stmt = conn.prepare(
        "SELECT id, title || char(10) || summary || char(10) || coalesce(origin, '') FROM sources",
    )?;
    for row in stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))? {
        let (id, text) = row?;
        let hits = sensitive(&text);
        if !hits.is_empty() {
            found.push(format!("source #{id} details: {}", hits.join(", ")));
        }
    }
    let mut stmt = conn.prepare("SELECT source_id, text FROM chunks")?;
    let mut by_source: BTreeMap<i64, Vec<String>> = BTreeMap::new();
    for row in stmt.query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)))? {
        let (id, text) = row?;
        by_source.entry(id).or_default().extend(sensitive(&text));
    }
    for (id, hits) in by_source.into_iter().filter(|(_, h)| !h.is_empty()) {
        found.push(format!("source #{id} text: {}", hits.join(", ")));
    }
    Ok(found)
}

/// Copies what `replace` is about to overwrite to `<home>/backups/<dossier>-<time>/`.
fn backup_dossier(home: &Home, d: &Dossier) -> Result<PathBuf> {
    let name = d
        .dir
        .file_name()
        .and_then(|n| n.to_str())
        .ok_or_else(|| anyhow!("the dossier folder has no name"))?;
    let dest = home
        .root
        .join("backups")
        .join(format!("{name}-{}", crate::date::now_secs()));
    fs::create_dir_all(dest.join("tasks"))?;
    for name in ["repo.json", "context.md", "decisions.md", "rules.md"] {
        if d.dir.join(name).is_file() {
            fs::copy(d.dir.join(name), dest.join(name))?;
        }
    }
    for (path, _) in d.task_files()? {
        if let Some(name) = path.file_name() {
            fs::copy(&path, dest.join("tasks").join(name))?;
        }
    }
    if let Some(conn) = connect(d, false)? {
        conn.execute(
            "VACUUM INTO ?1",
            params![dest.join("kb.db").to_string_lossy()],
        )?;
    }
    Ok(dest)
}

fn write_task_file(d: &Dossier, rel: &str, text: &str) -> Result<()> {
    let name = rel.strip_prefix("tasks/").unwrap_or(rel);
    fs::create_dir_all(d.tasks_dir())?;
    crate::store::write_atomic(&d.tasks_dir().join(name), text)
}

/// Brings a pack into the dossier `d`. `Merge` adds what is missing; `Replace` makes the dossier
/// equal to the pack after a backup. The pack is checked (format, schema, identity, secrets)
/// before anything is written; `dry_run` writes nothing.
pub fn import_pack(
    home: &Home,
    d: &Dossier,
    pack: &Path,
    mode: PackMode,
    dry_run: bool,
) -> Result<String> {
    let (src, identity) = open_pack(pack)?;
    if identity != d.meta.identity {
        bail!(
            "the pack belongs to {identity}, not to {}; pass --repo for that repository",
            d.meta.identity
        );
    }
    let replace = mode == PackMode::Replace;
    let mut files = Vec::new();
    {
        let mut stmt = src.prepare("SELECT path, content FROM dossier_files ORDER BY path")?;
        for row in stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))? {
            let (path, content) = row?;
            if !pack_path_ok(&path) {
                bail!("the pack carries an unexpected file '{path}'");
            }
            files.push((path, content));
        }
    }
    let mut pack_tasks: Vec<(String, crate::task::Task)> = Vec::new();
    for (path, content) in &files {
        if path.starts_with("tasks/") {
            let task = crate::task::Task::parse(content)
                .with_context(|| format!("task file {path} in the pack"))?;
            pack_tasks.push((path.clone(), task));
        }
    }
    let found = pack_findings(&src, &files)?;
    if !found.is_empty() {
        bail!(
            "the pack looks like it holds secrets or personal data and was not imported:\n- {}",
            found.join("\n- ")
        );
    }

    let local_tasks = d.task_files()?;
    let mut known_tasks: HashSet<i64> = HashSet::new();
    if replace {
        known_tasks.extend(pack_tasks.iter().map(|(_, t)| i64::from(t.id)));
    } else {
        known_tasks.extend(local_tasks.iter().map(|(_, t)| i64::from(t.id)));
    }

    // Sources to bring in.
    let mut picks: Vec<PackSource> = Vec::new();
    {
        let mut stmt = src.prepare(
            "SELECT id, kind, title, origin, mime, bytes, text_hash, para, tags, summary, task_id,
                    rev, supersedes, added_at, added_by FROM sources ORDER BY id",
        )?;
        let rows = stmt.query_map([], |r| {
            Ok(PackSource {
                id: r.get(0)?,
                kind: r.get(1)?,
                title: r.get(2)?,
                origin: r.get(3)?,
                mime: r.get(4)?,
                bytes: r.get(5)?,
                text_hash: r.get(6)?,
                para: r.get(7)?,
                tags: r.get(8)?,
                summary: r.get(9)?,
                task_id: r.get(10)?,
                rev: r.get(11)?,
                supersedes: r.get(12)?,
                added_at: r.get(13)?,
                added_by: r.get(14)?,
            })
        })?;
        for row in rows {
            picks.push(row?);
        }
    }
    let replaced: HashSet<i64> = picks.iter().filter_map(|s| s.supersedes).collect();
    let mut conn = connect(d, !dry_run)?;
    let existing: HashSet<String> = match &conn {
        Some(c) if !replace => {
            let mut stmt = c.prepare("SELECT text_hash FROM sources")?;
            stmt.query_map([], |r| r.get::<_, String>(0))?
                .collect::<rusqlite::Result<_>>()?
        }
        _ => HashSet::new(),
    };
    let total_picks = picks.len();
    if !replace {
        picks.retain(|s| !replaced.contains(&s.id) && !existing.contains(&s.text_hash));
    }
    for s in &picks {
        check_kind(&s.kind)?;
        check_para(&s.para)?;
        parse_tags(&tags_from(&s.tags))?;
    }
    let skipped_sources = if replace {
        0
    } else {
        total_picks - picks.len()
    };

    let mut out = String::new();
    out.push_str(&format!(
        "{} {} from {}\n",
        if dry_run { "Dry run:" } else { "Imported" },
        d.meta.identity,
        pack.display()
    ));

    // File plan, applied or only reported.
    let backup = if replace && !dry_run {
        Some(backup_dossier(home, d)?)
    } else {
        None
    };
    if let Some(conn) = conn.as_mut() {
        let pack_chunks = |id: i64| -> Result<Vec<(i64, String, i64)>> {
            let mut stmt = src.prepare(
                "SELECT ord, text, tokens FROM chunks WHERE source_id = ?1 ORDER BY ord",
            )?;
            let rows = stmt.query_map(params![id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
            Ok(rows.collect::<rusqlite::Result<_>>()?)
        };
        if !dry_run {
            let tx = conn.transaction()?;
            if replace {
                tx.execute_batch(
                    "DELETE FROM chunks_fts; DELETE FROM chunks; DELETE FROM sources;",
                )?;
            }
            for s in &picks {
                let task_id = s.task_id.filter(|t| known_tasks.contains(t));
                let id = if replace {
                    tx.execute(
                        "INSERT INTO sources (id, kind, title, origin, mime, bytes, text_hash, para,
                                              tags, summary, task_id, rev, supersedes, added_at, added_by)
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)",
                        params![
                            s.id, s.kind, s.title, s.origin, s.mime, s.bytes, s.text_hash, s.para,
                            s.tags, s.summary, task_id, s.rev, s.supersedes, s.added_at, s.added_by
                        ],
                    )?;
                    s.id
                } else {
                    tx.execute(
                        "INSERT INTO sources (kind, title, origin, mime, bytes, text_hash, para,
                                              tags, summary, task_id, rev, supersedes, added_at, added_by)
                         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 1, NULL, ?11, ?12)",
                        params![
                            s.kind, s.title, s.origin, s.mime, s.bytes, s.text_hash, s.para, s.tags,
                            s.summary, task_id, s.added_at, s.added_by
                        ],
                    )?;
                    tx.last_insert_rowid()
                };
                for (ord, text, cost) in pack_chunks(s.id)? {
                    tx.execute(
                        "INSERT INTO chunks (source_id, ord, text, tokens) VALUES (?1, ?2, ?3, ?4)",
                        params![id, ord, text, cost],
                    )?;
                }
                reindex(&tx, id)?;
            }
            tx.commit()?;
        }
    }
    out.push_str(&format!(
        "- sources: {} {}{}\n",
        picks.len(),
        if dry_run { "to import" } else { "imported" },
        if skipped_sources > 0 {
            format!(", {skipped_sources} already present or superseded")
        } else {
            String::new()
        }
    ));

    let mut notes = Vec::new();
    for (path, content) in &files {
        if path.starts_with("tasks/") {
            continue;
        }
        let target = d.dir.join(path);
        let local = read_text(&target)?.unwrap_or_default();
        if replace {
            if !dry_run {
                crate::store::write_atomic(&target, content)?;
            }
            notes.push(format!("{path}: replaced"));
        } else if path == "decisions.md" {
            let have: HashSet<&str> = local.lines().collect();
            let new: Vec<&str> = content
                .lines()
                .filter(|l| l.starts_with("- ") && !have.contains(l))
                .collect();
            if new.is_empty() {
                notes.push(format!("{path}: nothing new"));
            } else {
                notes.push(format!("{path}: {} new line(s)", new.len()));
                if !dry_run {
                    d.with_lock(|| {
                        let mut all = if local.trim().is_empty() {
                            "# Decisions\n\n".to_string()
                        } else {
                            local.clone()
                        };
                        if !all.ends_with('\n') {
                            all.push('\n');
                        }
                        for line in &new {
                            all.push_str(line);
                            all.push('\n');
                        }
                        crate::store::write_atomic(&target, &all)
                    })?;
                }
            }
        } else if local.trim().is_empty() {
            if !dry_run {
                crate::store::write_atomic(&target, content)?;
            }
            notes.push(format!("{path}: taken from the pack"));
        } else {
            notes.push(format!("{path}: kept the local text"));
        }
    }
    if replace {
        for name in ["context.md", "decisions.md", "rules.md"] {
            if !files.iter().any(|(p, _)| p == name) && d.dir.join(name).is_file() {
                if !dry_run {
                    fs::remove_file(d.dir.join(name))?;
                }
                notes.push(format!("{name}: removed (not in the pack)"));
            }
        }
    }
    let (mut added, mut kept, mut removed) = (0, 0, 0);
    if replace {
        let keep: HashSet<&str> = files.iter().map(|(p, _)| p.as_str()).collect();
        for (path, _) in &local_tasks {
            let name = path
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or_default();
            if !keep.contains(format!("tasks/{name}").as_str()) {
                if !dry_run {
                    fs::remove_file(path)?;
                }
                removed += 1;
            }
        }
    }
    for (rel, task) in &pack_tasks {
        let name = rel.strip_prefix("tasks/").unwrap_or(rel);
        let clash = !replace
            && local_tasks.iter().any(|(p, t)| {
                p.file_name().and_then(|n| n.to_str()) == Some(name)
                    || t.id == task.id
                    || (task.key.is_some() && t.key == task.key)
            });
        if clash {
            kept += 1;
            continue;
        }
        if !dry_run {
            let content = files
                .iter()
                .find(|(p, _)| p == rel)
                .map(|(_, c)| c.as_str())
                .unwrap_or_default();
            write_task_file(d, rel, content)?;
        }
        added += 1;
    }
    notes.push(format!(
        "tasks: {added} {}, {kept} already present{}",
        if replace { "written" } else { "added" },
        if replace {
            format!(", {removed} removed")
        } else {
            String::new()
        }
    ));
    for note in notes {
        out.push_str(&format!("- {note}\n"));
    }
    if let Some(b) = backup {
        out.push_str(&format!(
            "Backup of the previous dossier: {}\n",
            b.display()
        ));
    }
    Ok(out)
}

/// One Markdown file per current source in `dir` (front matter, then the text).
pub fn export_md(d: &Dossier, dir: &Path) -> Result<String> {
    if dir.is_file() {
        bail!("{} is a file", dir.display());
    }
    if dir.is_dir() && fs::read_dir(dir)?.next().is_some() {
        bail!(
            "{} is not empty; choose an empty or new folder",
            dir.display()
        );
    }
    let sources = list(d, &Filter::default())?;
    let conn = connect(d, false)?;
    fs::create_dir_all(dir)?;
    let q = |s: &str| serde_json::to_string(s).unwrap_or_else(|_| "\"\"".into());
    for s in &sources {
        let mut text = String::new();
        if let Some(conn) = &conn {
            let mut stmt =
                conn.prepare("SELECT text FROM chunks WHERE source_id = ?1 ORDER BY ord")?;
            let parts: Vec<String> = stmt
                .query_map(params![s.id], |r| r.get(0))?
                .collect::<rusqlite::Result<_>>()?;
            text = parts.join("\n\n");
        }
        let mut md = format!(
            "---\nid: {}\ntitle: {}\nkind: {}\n",
            s.id,
            q(&s.title),
            s.kind
        );
        if let Some(o) = &s.origin {
            md.push_str(&format!("origin: {}\n", q(o)));
        }
        md.push_str(&format!("para: {}\n", s.para));
        let tags: Vec<String> = s.tags.iter().map(|t| q(t)).collect();
        md.push_str(&format!("tags: [{}]\n", tags.join(", ")));
        if !s.summary.is_empty() {
            md.push_str(&format!("summary: {}\n", q(&s.summary)));
        }
        if let Some(t) = s.task_id {
            md.push_str(&format!("task: {t}\n"));
        }
        md.push_str(&format!(
            "rev: {}\nadded: {}\n---\n\n{}\n",
            s.rev, s.added_at, text
        ));
        let slug: String = safe_name(&s.title)
            .trim_matches('_')
            .chars()
            .take(50)
            .collect::<String>()
            .to_lowercase();
        let slug = if slug.is_empty() {
            "source".into()
        } else {
            slug
        };
        crate::store::write_atomic(&dir.join(format!("{:04}-{slug}.md", s.id)), &md)?;
    }
    Ok(format!(
        "Wrote {} source(s) as Markdown to {}\n",
        sources.len(),
        dir.display()
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pack_paths_are_limited_to_dossier_files() {
        assert!(pack_path_ok("context.md") && pack_path_ok("tasks/0001-x.md"));
        for bad in [
            "paths.json",
            "../x.md",
            "tasks/../x.md",
            "tasks/a/b.md",
            "tasks/.md.md",
            "kb.db",
            "tasks/x.txt",
        ] {
            assert!(!pack_path_ok(bad), "{bad}");
        }
    }

    #[test]
    fn chunks_follow_headings_and_stay_within_the_limit() {
        let text = "# One\n\nfirst paragraph\n\n## Two\n\nsecond paragraph\n";
        assert_eq!(chunk_text(text).len(), 1, "small sections share a chunk");
        let long = format!("# Big\n\n{}\n", "word ".repeat(2000));
        let chunks = chunk_text(&long);
        assert!(chunks.len() >= 3);
        assert!(chunks.iter().all(|c| c.chars().count() <= CHUNK_CHARS));
        let one_line = "x".repeat(CHUNK_CHARS * 2 + 5);
        assert!(
            chunk_text(&one_line)
                .iter()
                .all(|c| c.chars().count() <= CHUNK_CHARS)
        );
        assert!(chunk_text("   \n").is_empty());
    }

    #[test]
    fn tags_are_normalized_and_validated() {
        assert_eq!(
            parse_tags(&["Invoice, 2026".into(), "invoice".into()]).unwrap(),
            ["invoice", "2026"]
        );
        assert!(parse_tags(&["bad tag!".into()]).is_err());
        assert_eq!(
            tags_from(&tags_column(&["a".into(), "b".into()])),
            ["a", "b"]
        );
    }

    #[test]
    fn para_and_kind_are_checked() {
        assert_eq!(check_para(" Archive ").unwrap(), "archive");
        assert!(check_para("inbox").is_err());
        assert!(check_kind("pdf").is_err());
    }

    fn words(prefix: &str, n: usize) -> String {
        (0..n)
            .map(|i| format!("{prefix}{i}"))
            .collect::<Vec<_>>()
            .join(" ")
    }

    #[test]
    fn simhash_tells_near_duplicates_from_other_text() {
        let base = words("delta", 150);
        let near = format!("{} extra", words("delta", 149));
        let (a, b) = (simhash(&base).unwrap(), simhash(&near).unwrap());
        assert!(
            (a ^ b).count_ones() <= NEAR_DISTANCE,
            "{}",
            (a ^ b).count_ones()
        );
        let other = simhash(&words("omega", 150)).unwrap();
        assert!((a ^ other).count_ones() > NEAR_DISTANCE);
        assert!(simhash("too short to compare").is_none());
    }

    #[test]
    fn blobs_and_repeated_lines_are_found() {
        let blob = "QUJD".repeat(40);
        assert_eq!(strip_blobs(&blob), (String::new(), 1));
        let (line, n) = strip_blobs(&format!("![x](data:image/png;base64,{blob}) end"));
        assert_eq!(
            (line.as_str(), n),
            ("![x](data:image/png;base64,[blob removed]) end", 1)
        );
        assert_eq!(strip_blobs("plain words"), ("plain words".to_string(), 0));
        assert!(repeatable("Acme Corp - Page footer"));
        assert!(!repeatable("- a list item here"));
    }

    #[test]
    fn original_names_are_made_safe() {
        assert_eq!(
            safe_name("../my report (final).pdf"),
            "_my_report__final_.pdf"
        );
        assert_eq!(safe_name("..."), "original");
    }
}
