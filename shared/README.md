# shared

References shared and reusable by all repositories: authoritative sources, architecture, technology radar, troubleshooting.

- **Creation:** `scripts/entity.ps1 -NewResource -Id <id> -Title <title> -Objective <objective>`.
- **Who writes:** SecondBrain scripts and the owner; an entity here never holds data of a single repository.
- **Git:** contents are tracked (catalog, domains, profiles, metadata, transcripts and evidence of public-reusable sources), except the originals (`versions/*/originals/`) and the check screenshots (`census/qa/`). Originals are downloaded with `scripts/resources.ps1 -Sync` (or `-Restore`) and written only when the SHA-256 matches the manifest. A stored text of a source that is not public-reusable is rejected by `scripts/check-distribution.ps1`.
