# Proposal: find guided flows (wf-NAME) from any repository

State: proposed. Not an active directive; approval and distribution follow `scripts/approve-revision.ps1 -Preview`.

## Problem

A user in a product repository writes `wf-security-review`. The agent cannot find it: the repository block and the IDE text say only "load from `sb prompt`", and the workstation template lists the `sb` commands without the guided-flow key form. MCP `get_prompt` accepted cards only, so a `wf-` key failed with "Code not available in the catalog".

## Evidence

- Before the fix: `get_prompt wf-security-review` failed; `list_prompts` and `sb prompt list` did not list presets; private workflows (`<repo-slug>/<name>`) had no CLI or MCP route.
- After the fix (code, this repository): `sb prompt list` and MCP `list_prompts` end with the guided flows; `sb prompt wf-NAME: objective` and MCP `get_prompt` with `wf-NAME`, `wfl-` ID or a private key compose the whole flow.

## Applicable contexts

Every repository bound to SecondBrain, in any IDE. Counterexample: a repository without SecondBrain has no catalog; the line must stay inside the SecondBrain block.

## Minimal text

Add one bullet to the managed repository block (`AGENTS.repo.managed.md`), after the load bullet:

- A guided flow or prompt key such as `wf-security-review`, a prompt code, or a private key `<repo-slug>/<name>` is not a file in this repository: run `sb prompt KEY: objective`, or call MCP `get_prompt` with the key (and `repositoryPath` for private keys). List the keys with `sb prompt list` or MCP `list_prompts`.

Replace the command line in `workstation.template.md` so that `sb prompt KEY: objective` reads `sb prompt KEY: objective (KEY: a prompt code, wf-NAME or <repo-slug>/<name>)`.

Do not change `AGENTS.global_ide.md`: its "find a tool by its role through `sb prompt`" line stays valid.
