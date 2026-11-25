//! The SecondBrain block in a repository's AGENTS.md. Text outside the markers is never touched.

pub const BEGIN: &str = "<!-- secondbrain:begin -->";
pub const END: &str = "<!-- secondbrain:end -->";

/// The block body: how agents reach the dossier, then the shared rules.
pub fn body(rules: &str) -> String {
    let mut s = String::from(
        "## SecondBrain\n\n\
         This repository's private context, decisions and tasks live in SecondBrain, outside the repository.\n\n\
         - At the start of a session run `sb context` (MCP tool `get_context`) and work from it.\n\
         - Track work with `sb task add`, `sb task list` and `sb task done` (MCP task tools).\n\
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
    s
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
    if text.trim().is_empty() {
        return format!("{block}{nl}");
    }
    format!("{}{nl}{nl}{block}{nl}", text.trim_end())
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
    fn body_drops_template_comments() {
        let template = body("# Shared rules\n\n<!-- hint -->\n");
        assert!(!template.contains("Shared rules") && !template.contains("hint"));
        let b = body("# Shared rules\n<!-- hint -->\n- Write tests first.\n");
        assert!(b.contains("# Shared rules") && b.contains("- Write tests first."));
        assert!(!b.contains("hint"));
        assert!(!body("<!-- only a hint -->").contains("<!--"));
    }
}
