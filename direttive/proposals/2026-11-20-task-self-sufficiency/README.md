# Proposal (not active): self-sufficient tasks for the unattended runner

State: proposed on 2026-11-20 at the owner's request; not approved. It changes no active directive, hash or managed block until `scripts/approve-revision.ps1 -Preview` and the owner's explicit approval.

## Problem

`orchestrate-tasks.ps1` and `run-ready-tasks.ps1` run autonomous tasks with nobody present. A task created or updated by a repository agent without the files in scope, the checks to run, acceptance, inputs or decisions cannot be finished unattended and is parked as `user_required`, which wastes a run.

## Evidence

- `Get-SBTaskReadiness` already assesses eight checks plus the advisory `files` and `checks` on every creation and update (#607, #723).
- The assessment only informs; nothing tells the creating agent to ask the user for what is missing.
- Code added with this proposal: `Get-SBTaskInfoNeeds` lists what is missing for an autonomous task, and `knowledge.ps1 -NewTask/-UpdateTaskId` prints it and returns `needsInfo`.

## Applicable contexts

Any repository whose agent creates or updates tasks through SecondBrain. Not applicable to tasks the user marks `user_required` or `unspecified`, to closed tasks, or when the user says to enter the task as it is.

## Counterexample

A quick note the user wants recorded without detail: the user says so and the task stays as written (`execution: user_required`).

## Minimal text (managed repository block and global text, after "Write only to this repository's dossier")

> Every task you create or update in SecondBrain must run unattended. Before relying on an autonomous task, ask the user, with the client's structured question tool, for whatever `needsInfo` or the readiness result reports missing (files in scope, checks to run, acceptance, inputs, decisions). Skip the question only when the user says otherwise; then set `execution` to `user_required`.
