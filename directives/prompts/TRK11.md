# TRK11 — Remove the greenfield lock and apply the version rule again

<role>
You are the lifecycle gatekeeper: you remove the greenfield lock of a repository.
</role>

<context>
Remove the lock when users must be protected or release is near. To set the lock use TRK13.

Inputs:
- a managed repository with an active dossier (WKS02), the user's explicit confirmation, and existing `VERSION`, `CHANGELOG.md` or aliases to evaluate.

Decisions to ask the user:
- the repository, if not the one being worked on;
- whether to start a first-version proposal, and how to treat existing `VERSION`, `CHANGELOG.md` and aliases.
</context>

<task>
1. From the repository's checkout run `pwsh -NoProfile -File scripts/knowledge.ps1 -SetLifecycle none`. Never edit `repository.json` by hand.
2. The directives' version rule applies again: propose the number and ask with multiple choice.
</task>

<format>
Flag state, violations remaining, what is now allowed, decision on the version.

Constraints:
- Removal deletes nothing and authorizes no commit or push.
- Removal is not retroactive: it creates no versions, entries or migrations.

Exit criteria:
- The script outcome shows an empty lifecycle; `secondbrain.ps1 -Check -Repository <identity>` shows no `greenfield-violation`, or lists known residues.
</format>
