---
name: review-checklist
description: Reviews a diff against a short checklist. Use when asked to review a change, a branch or a pull request.
---

# Review checklist

- Correctness: does the diff do what the request says, including edge cases and error paths? No panics on user input.
- Scope: does it change anything the request did not ask for? New dependencies need approval.
- Tests: is new behavior covered, and were fmt, clippy and tests run? Secret-like or personal samples in tests are built from pieces.
- Safety: secrets, personal paths, input from outside the program, destructive operations. Files are written with `store::write_atomic`, never outside the managed block or without a backup.
- Consistency: `VERSION`, `cli/Cargo.toml` and `CHANGELOG.md` change together; the two skill folders stay identical; docs (`COMMANDS.md`, READMEs) match the commands.
- Report findings ordered by severity, each with the file and line, and say what you did not check.
