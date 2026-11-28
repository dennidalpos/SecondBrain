//! The SecondBrain block in a repository's AGENTS.md. Text outside the markers is never touched.

pub const BEGIN: &str = "<!-- secondbrain:begin -->";
pub const END: &str = "<!-- secondbrain:end -->";
const VERSION_PREFIX: &str = "<!-- secondbrain:directive-version: ";

/// The block body: how agents reach the dossier, then the shared rules.
pub fn body(rules: &str) -> String {
    let mut s = String::from(
        "## SecondBrain\n\n\
         The private context, decisions and tasks for linked repositories live in SecondBrain, outside their checkouts. Apply the repository workflow below when working in a linked checkout.\n\n\
         - At the start of a session run `sb context` (MCP tool `get_context`) and work from it.\n\
         - Run `sb start` to check recorded checkouts, refresh managed agent files and see which SecondBrain build is running.\n\
         - When asked to run `sb start` in chat, include the full result in the first reply after execution, even in a new session. Use bullet lists for the executable and PATH status, repository, context and tasks, instruction alignment, MCP configuration, health findings, all suggested next steps and every command shown. Put a brief description and an example beside each command and parameter. State when no issues are reported and distinguish MCP configuration from runtime verification.\n\
         - When asked to onboard a repository with missing or empty context, read `sb guide onboarding` or call `get_guide` with topic `onboarding`. Inspect the checkout and save the verified starting context in the private dossier.\n\
         - When asked to work through tasks in the current chat, read `sb guide chat` or call `get_guide` with topic `chat`.\n\
         - Track work with `sb task add`, `sb task list` and `sb task done` (MCP task tools).\n\
         - When more than one reasonable scenario exists, interview the user before acting, using the client's structured question tool (function calling or tool use, such as AskUserQuestion). Offer two or three concrete options with their trade-offs and a recommendation. Never choose silently.\n\
         - Do not drift from the stated intent on your own initiative. Before adding scope, changing approach or touching files or systems the request did not name, stop, ask and propose alternatives.\n\
         - Collect authorizations before a task starts, not during it, so unattended work is not interrupted: push or commit, network or installs, deleting or overwriting data, spending money, secrets or accounts, external services. Ask once, up front, and record the answer in the task handoff (`sb task prepare`) or in the chat.\n\
         - Without a structured question tool, ask in plain text with numbered options and wait. In an unattended run with nobody to answer, do not guess: mark the task `--needs-user` and record what is missing.\n\
         - Record durable decisions with `sb decide \"...\"` and keep the current state with `sb context --set`.\n\
         - Never copy dossier content into the repository.\n",
    );
    let rules = strip_comments(rules);
    // A rules file with headings only (the untouched template) adds nothing.
    let has_rules = rules
        .lines()
        .any(|l| !l.trim().is_empty() && !l.trim_start().starts_with('#'));
    if has_rules {
        s.push('\n');
        s.push_str(rules.trim());
        s.push('\n');
    }
    let s = s.replace("\r\n", "\n");
    let hash = s
        .trim_end()
        .bytes()
        .fold(0xcbf29ce484222325_u64, |hash, byte| {
            (hash ^ u64::from(byte)).wrapping_mul(0x100000001b3)
        });
    format!("{VERSION_PREFIX}v1-{hash:016x} -->\n{s}")
}

/// The version declared by a generated body or managed block.
pub fn directive_version(text: &str) -> Option<&str> {
    let body = span(text).map_or(text, |(start, end)| &text[start + BEGIN.len()..end]);
    body.trim_start()
        .lines()
        .next()?
        .strip_prefix(VERSION_PREFIX)?
        .strip_suffix(" -->")
}

pub(crate) fn markers_valid(text: &str) -> bool {
    match (text.matches(BEGIN).count(), text.matches(END).count()) {
        (0, 0) => true,
        (1, 1) => has_block(text),
        _ => false,
    }
}

pub fn has_block(text: &str) -> bool {
    span(text).is_some()
}

/// Inserts or replaces the block, keeping the file's line endings.
pub fn upsert(text: &str, body: &str) -> String {
    let nl = if text.contains("\r\n") { "\r\n" } else { "\n" };
    let inner = body.replace("\r\n", "\n");
    let block = format!("{BEGIN}\n{}\n{END}", inner.trim_end()).replace('\n', nl);
    if let Some((start, end)) = span(text) {
        return format!("{}{}{}", &text[..start], block, &text[end..]);
    }
    let separator = if text.is_empty() || text.ends_with(&format!("{nl}{nl}")) {
        String::new()
    } else if text.ends_with(nl) {
        nl.to_string()
    } else {
        format!("{nl}{nl}")
    };
    format!("{text}{separator}{block}{nl}")
}

/// Removes the block; None when the file has none.
pub fn remove(text: &str) -> Option<String> {
    let (start, end) = span(text)?;
    let nl = if text.contains("\r\n") { "\r\n" } else { "\n" };
    let before = text[..start].trim_end();
    let after = text[end..].trim_start_matches(['\r', '\n']);
    let joined = match (before.is_empty(), after.trim().is_empty()) {
        (true, true) => String::new(),
        (true, false) => after.to_string(),
        (false, true) => format!("{before}{nl}"),
        (false, false) => format!("{before}{nl}{nl}{after}"),
    };
    Some(joined)
}

fn span(text: &str) -> Option<(usize, usize)> {
    let start = text.find(BEGIN)?;
    let end = text[start..].find(END)? + start + END.len();
    Some((start, end))
}

fn strip_comments(text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(i) = rest.find("<!--") {
        out.push_str(&rest[..i]);
        match rest[i..].find("-->") {
            Some(j) => rest = &rest[i + j + 3..],
            None => {
                rest = "";
                break;
            }
        }
    }
    out.push_str(rest);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn upsert_is_idempotent_and_keeps_user_text() {
        let user = "# My repo\r\n\r\nOwn rules.\r\n";
        let once = upsert(user, "## SecondBrain\nA");
        assert!(
            once.starts_with("# My repo\r\n\r\nOwn rules.\r\n\r\n<!-- secondbrain:begin -->\r\n")
        );
        assert_eq!(upsert(&once, "## SecondBrain\nA"), once);
        let changed = upsert(&once, "## SecondBrain\nB");
        assert!(changed.contains("\r\nB\r\n") && !changed.contains("\r\nA\r\n"));
        assert_eq!(remove(&changed).unwrap(), user);
    }

    #[test]
    fn remove_from_block_only_file_and_middle() {
        let only = upsert("", "x");
        assert_eq!(remove(&only).unwrap(), "");
        let middle = format!("top\n\n{BEGIN}\nx\n{END}\n\nbottom\n");
        assert_eq!(remove(&middle).unwrap(), "top\n\nbottom\n");
        assert!(remove("no block").is_none());
    }

    #[test]
    fn body_asks_for_interviews_and_up_front_authorizations() {
        let b = body("");
        assert!(b.contains("interview the user before acting"));
        assert!(b.contains("Do not drift from the stated intent"));
        assert!(b.contains("Collect authorizations before a task starts"));
        assert!(b.contains("mark the task `--needs-user`"));
    }

    #[test]
    fn body_drops_template_comments() {
        let template = body("# Shared rules\n\n<!-- hint -->\n");
        assert!(!template.contains("Shared rules") && !template.contains("hint"));
        let b = body("# Shared rules\n<!-- hint -->\n- Write tests first.\n");
        assert!(b.contains("# Shared rules") && b.contains("- Write tests first."));
        assert!(!b.contains("hint"));
        assert!(!body("<!-- only a hint -->").contains("only a hint"));
        assert_eq!(directive_version(&template), directive_version(&body("")));
        assert_eq!(
            directive_version(&b),
            directive_version(&body(
                "# Shared rules\r\n<!-- hint -->\r\n- Write tests first.\r\n"
            ))
        );
        assert_ne!(directive_version(&template), directive_version(&b));
        assert_eq!(
            directive_version(&upsert("User notes\n", &b)),
            directive_version(&b)
        );
    }
}
