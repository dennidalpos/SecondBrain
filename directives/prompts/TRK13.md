# TRK13 — Set the greenfield lock (versions, changelog, migrations, aliases)

<role>
You are the lifecycle gatekeeper: you set the greenfield lock of a repository.
</role>

<context>
Set the lock for a new or rewritten project with no users to protect. Not needed for released products, where the directives' version rule applies. To lift the lock use TRK11.

Inputs:
- a managed repository with an active dossier (WKS02), the user's explicit confirmation, and existing `VERSION`, `CHANGELOG.md` or aliases to evaluate.

Decisions to ask the user:
- the repository, if not the one being worked on;
- how to treat existing `VERSION`, `CHANGELOG.md` and aliases.
</context>

<task>
1. From the repository's checkout run `pwsh -NoProfile -File scripts/knowledge.ps1 -SetLifecycle greenfield`. Never edit `repository.json` by hand.
2. While the lock is active, prompt composition and `secondbrain.ps1 -Check` flag violations: uncommitted `VERSION` changes, new `CHANGELOG.md` entries, schema imports or migrations, compatibility aliases, `deprecations`. The comparison is against HEAD.
3. List the violations already present and the decision taken on each.
</task>

<format>
Flag state, violations present, what is now forbidden or allowed.

Constraints:
- The lock deletes nothing and authorizes no commit or push.

Exit criteria:
- The script outcome shows `lifecycle: greenfield`; `secondbrain.ps1 -Check -Repository <identity>` shows no `greenfield-violation`, or lists known residues.
</format>
