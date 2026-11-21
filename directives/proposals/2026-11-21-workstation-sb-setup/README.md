# Proposal (not active): list `sb setup` among the workstation commands

State: proposed on 2026-11-21 for task #442; not approved. It changes no active directive, hash or managed block until `scripts/approve-revision.ps1 -Preview` and the owner's explicit approval.

## Problem

The workstation text already tells agents to run `sb sync` or `sb setup` only when the user asks, but its command list omits `sb setup` (SYS17). An agent reading only the command list does not learn that the command exists.

## Evidence

- `direttive/workstation.template.md` mentions `sb setup` in the `sb check` bullet and omits it from the `Commands:` bullet.
- `sb setup` is implemented (SYS17) and documented in `docs/getting-started.md`.

## Applicable contexts

Every workstation that receives the common workstation text.

## Counterexample

None known: the change adds a command name already mentioned in the same text and gives no new permission.

## Minimal text

In the `Commands:` bullet, add `sb setup` after `sb sync`.
