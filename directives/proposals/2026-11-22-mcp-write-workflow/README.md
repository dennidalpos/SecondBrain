# Proposal (approved): tell agents how to write to their dossier through MCP

State: approved by the owner in chat on 2026-11-22 and registered with `scripts/approve-revision.ps1`; reaches repositories with `sb sync`.

## Problem

The managed repository block says to write "only through SecondBrain scripts or MCP write tools" and nothing more. Agents in product repositories do not learn the two-step flow, the `plan` argument, or what an active grant already covers. Observed 2026-11-22 in OnlyWorkspace: the agent submitted without `plan`, received a "no grant" refusal although the grant was active, and asked the owner to run `-Grant` again.

## Evidence

- `scripts/mcp-write.ps1 -Grants` shows an active standing grant for `github.com/dennidalpos/onlyworkspace`; `grant-repositories.ps1` lists every bound repository as `already-granted`.
- Reproduced with the SecondBrain MCP server: `submit_dossier_write` without `plan` is refused, with `plan` it is applied.
- `docs/reference/mcp-writes.md` documents the flow, but agents load it only on request.

## Applicable contexts

Every repository that carries the managed SecondBrain block and has an MCP server of this checkout.

## Counterexample

Repositories without a remote identity (`local:`) have no grant: the owner approves each plan with `mcp-write.ps1 -Approve`. The text must not promise a grant to them.

## Minimal text

Add one bullet after the second bullet of `directives/AGENTS.repo.managed.md` (full text in the proposal copy of that file):


- MCP writes: call `preview_dossier_write`, then `submit_dossier_write` with the same `requestId` and `planHash`, and pass the whole previewed object as `plan` (a grant covers task status, update, evidence, new non-autonomous tasks, memory, activity and history of this dossier; evidence correction, `execution` and `requires` changes need the owner's per-plan approval). A refusal that names a missing grant on a repository that has one means `plan` was left out. Never ask the owner for a grant or approval without first retrying with `plan`; the owner's approval is never given in chat.
