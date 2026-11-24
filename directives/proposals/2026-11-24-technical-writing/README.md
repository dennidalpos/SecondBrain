# Proposal: Use ASD-STE100 for technical writing

State: proposed on 2026-11-24. Approval is pending.

## Reason

The owner requested a common rule for code comments, pull request descriptions, issue and ticket descriptions, and documentation. Revision 1.6 sets the default language for product content.

## Source and scope

[ASD-STE100, Issue 9](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf) defines vocabulary and writing rules. Use the standard for English technical text. Use short sentences and active voice. Give one instruction per sentence in procedures. Keep explicit language requirements and preserve original material.

## Distribution

Put the rule under Principles in `AGENTS.global_ide.md`. The global directive applies across projects, including work on pull requests and tickets. The workstation template and repository block are included for proposal checks. Their content is unchanged. Project instructions can supply domain terminology.

Review the proposal with `scripts/approve-revision.ps1 -Preview -ProposalPath directives/proposals/2026-11-24-technical-writing`. After explicit approval, register the reviewed hash and run `sb sync` for managed file-based instructions. Use `scripts/ide-map.ps1 -Guide` for account settings that need manual application. Verify the revision in a new client session.
