---
name: secondbrain-context
description: Loads the project context from SecondBrain before work. Use at the start of a session in a repository managed by SecondBrain.
---

# Load the project context

1. Run `sb context` in the repository (or call the MCP tool `get_context`). It prints the current state, recent decisions and open tasks. Run `sb start` to check checkouts and managed files.
2. Read the repository instructions (AGENTS.md) and follow their checks.
3. Track work with `sb task add`, `sb task ready`, `sb task set <id> --status doing` and `sb task done <id>`; record durable decisions with `sb decide "..."`.
4. A task that lacks inputs, scope or decisions: interview the owner (`sb prepare`, `sb task prepare`); if nobody can answer, mark it `--needs-user true` and do not guess.
5. When the state changes, replace it with `sb context --set` (reads standard input). Never copy dossier content into the repository.
6. Ask before any commit, push or publication; run `sb check` before a push (exit 2 means findings).
