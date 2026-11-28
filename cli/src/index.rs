//! A rebuildable search index: SQLite FTS5 with BM25 ranking, in `<data folder>/index.db`.
//!
//! The Markdown files stay the source of truth. Each dossier is indexed as one line per context
//! line, per decision and per task, and re-indexed when the text it holds changes. Deleting
//! `index.db` loses nothing: the next search rebuilds it. No model, no network.

use crate::store::{Dossier, Home};
use anyhow::{Context as _, Result, anyhow};
use rusqlite::{Connection, params};
use std::fs;
use std::path::PathBuf;
use std::time::Duration;

pub fn path(home: &Home) -> PathBuf {
    home.root.join("index.db")
}

fn open(home: &Home) -> Result<Connection> {
    let file = path(home);
    let conn = Connection::open(&file).with_context(|| format!("opening {}", file.display()))?;
    conn.busy_timeout(Duration::from_secs(10))?;
    conn.execute_batch(
        "PRAGMA journal_mode = WAL;
         CREATE TABLE IF NOT EXISTS sigs (repo TEXT PRIMARY KEY, sig TEXT NOT NULL);
         CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5(
             repo UNINDEXED, display UNINDEXED, text,
             tokenize = 'unicode61 remove_diacritics 2'
         );",
    )?;
    Ok(conn)
}

/// What a dossier contributes: (line shown for a hit, text that is searched).
fn lines(d: &Dossier) -> Result<Vec<(String, String)>> {
    let id = &d.meta.identity;
    let mut out = Vec::new();
    for line in d.context().lines().filter(|l| !l.trim().is_empty()) {
        out.push((format!("{id} context: {}", line.trim()), line.to_string()));
    }
    for line in d.decisions()? {
        out.push((
            format!("{id} decision {}", line.trim_start_matches("- ")),
            line,
        ));
    }
    for line in d.archived_decisions()? {
        out.push((
            format!("{id} decision (archived) {}", line.trim_start_matches("- ")),
            line,
        ));
    }
    for t in d.tasks()? {
        out.push((
            format!("{id} {}", t.summary()),
            format!("{}\n{}", t.title, t.body),
        ));
    }
    for t in d.archived_tasks()? {
        out.push((
            format!("{id} {} (archived)", t.summary()),
            format!("{}\n{}", t.title, t.body),
        ));
    }
    Ok(out)
}

/// FNV-1a over everything indexed for one dossier.
fn signature(lines: &[(String, String)]) -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for (display, text) in lines {
        for b in display.bytes().chain([0]).chain(text.bytes()).chain([1]) {
            h ^= u64::from(b);
            h = h.wrapping_mul(0x0000_0100_0000_01b3);
        }
    }
    format!("{h:016x}:{}", lines.len())
}

fn refresh(conn: &mut Connection, d: &Dossier) -> Result<()> {
    let repo = d.meta.identity.clone();
    let lines = lines(d)?;
    let sig = signature(&lines);
    let current: Option<String> = conn
        .query_row("SELECT sig FROM sigs WHERE repo = ?1", params![repo], |r| {
            r.get(0)
        })
        .ok();
    if current.as_deref() == Some(sig.as_str()) {
        return Ok(());
    }
    let tx = conn.transaction()?;
    tx.execute("DELETE FROM docs WHERE repo = ?1", params![repo])?;
    {
        let mut insert =
            tx.prepare("INSERT INTO docs (repo, display, text) VALUES (?1, ?2, ?3)")?;
        for (display, text) in &lines {
            insert.execute(params![repo, display, text])?;
        }
    }
    tx.execute(
        "INSERT INTO sigs (repo, sig) VALUES (?1, ?2)
         ON CONFLICT(repo) DO UPDATE SET sig = excluded.sig",
        params![repo, sig],
    )?;
    tx.commit()?;
    Ok(())
}

/// Words of the query, quoted so FTS5 syntax in the text cannot break the match.
pub(crate) fn terms(query: &str) -> Vec<String> {
    query
        .split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(|w| format!("\"{}\"*", w.to_lowercase()))
        .collect()
}

fn run_match(conn: &Connection, expr: &str, repos: &[String]) -> Result<Vec<String>> {
    let scope = serde_json::to_string(repos)?;
    let mut stmt = conn.prepare(
        "SELECT display FROM docs
         WHERE docs MATCH ?1 AND repo IN (SELECT value FROM json_each(?2))
         ORDER BY bm25(docs) LIMIT 500",
    )?;
    let rows = stmt.query_map(params![expr, scope], |row| row.get(0))?;
    Ok(rows.collect::<rusqlite::Result<Vec<String>>>()?)
}

/// Ranked hits for `query` in the given dossiers: every word must match (prefixes count);
/// when nothing does, any word is enough.
pub fn search(home: &Home, dossiers: &[Dossier], query: &str) -> Result<Vec<String>> {
    let words = terms(query);
    if words.is_empty() {
        return Err(anyhow!("the search text is empty"));
    }
    let mut conn = open(home)?;
    for d in dossiers {
        refresh(&mut conn, d)?;
    }
    let repos: Vec<String> = dossiers.iter().map(|d| d.meta.identity.clone()).collect();
    let mut hits = run_match(&conn, &words.join(" AND "), &repos)?;
    if hits.is_empty() && words.len() > 1 {
        hits = run_match(&conn, &words.join(" OR "), &repos)?;
    }
    Ok(hits)
}

/// Checks the index opens and answers; used by `sb doctor`.
pub fn check(home: &Home) -> Result<()> {
    if !path(home).exists() {
        return Ok(());
    }
    let conn = open(home)?;
    let state: String = conn.query_row("PRAGMA integrity_check", [], |r| r.get(0))?;
    if state != "ok" {
        return Err(anyhow!("integrity check: {state}"));
    }
    conn.query_row("SELECT count(*) FROM docs", [], |r| r.get::<_, i64>(0))?;
    Ok(())
}

/// Removes the index and its WAL files; the next search rebuilds it.
pub fn reset(home: &Home) -> Result<()> {
    let base = path(home);
    for suffix in ["", "-wal", "-shm"] {
        let mut p = base.as_os_str().to_owned();
        p.push(suffix);
        let p = PathBuf::from(p);
        if p.exists() {
            fs::remove_file(&p).with_context(|| format!("removing {}", p.display()))?;
        }
    }
    Ok(())
}
