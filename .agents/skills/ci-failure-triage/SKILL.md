---
name: ci-failure-triage
description: Triages a failing CI run from its logs. Use when a pull request or push shows failing checks.
---

# CI failure triage

1. List the failing jobs (`gh run list --limit 5`, `gh run view <id> --log-failed`) and open the first failing step's log.
2. Separate the root failure from the follow-on errors. CI runs on Ubuntu, macOS and Windows: note which platforms fail.
3. Reproduce locally from `cli/` with the same step: `cargo fmt --check`, `cargo clippy --locked --all-targets -- -D warnings`, `cargo test --locked`.
4. Report the cause, the minimal fix and anything you could not verify.
5. Do not re-run, skip or disable checks to make them pass.
