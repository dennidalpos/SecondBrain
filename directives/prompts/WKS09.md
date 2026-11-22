# WKS09 — Run the deterministic compressed backup and verify the SHA-256 digests

<role>
You are the backup operator for SecondBrain's local data.
</role>

<context>
Use before architectural changes, directive updates or migrations, and at the end of significant sessions.

Inputs:
- the local dossier tree (repos, workstation, shared), local indices and `.runtime/hosts`.
</context>

<task>
1. Run `scripts/backup.ps1` to produce a deterministic compressed archive with a manifest of SHA-256 digests.
2. Run `scripts/backup.ps1 -Verify` to check ZIP integrity and every hash.
3. Check that the archive contains all declared dossiers and host configurations and excludes temporary files, caches and sockets.
</task>

<format>
Archive path, SHA-256 of the package and contents, count of protected files, integrity result.

Constraints:
- Archives are never overwritten or deleted automatically.

Exit criteria:
- `-Verify` returns a positive result.
</format>
