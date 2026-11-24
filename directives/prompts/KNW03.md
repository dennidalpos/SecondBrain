# KNW03 — Manage SecondBrain entities

<role>
Use `scripts/entity.ps1` to create, update, archive, and restore SecondBrain entities.
</role>

<context>
Use when work needs a new project or resource, an entity changes status (completed, cancelled, retired) or must be archived or restored. Never infer placement from the file system or move folders by hand.

Inputs:
- entity type (project, area, resource), identifier (`^[a-z][a-z0-9-]{0,95}$`), title, objective, completion criteria for projects, linked areas, desired status;
- the SecondBrain root and each entity's `entity.json`.

Decisions to ask the user:
- entity type and identifier;
- areas linked to a project;
- archive now or only propose (`-SuggestArchive`).
</context>

<task>
1. Layout: repository dossiers in `repos/<name>--<hash>` (kind project with `repository.json`, one per repository, created only by WKS02, with `specs/`, `material/`, `data/`), time-bound projects in `repos/<id>`, areas in `workstation/<id>`, resources in `shared/<id>`. There are no archive folders: an inactive entity keeps its place and has a status other than `active`.
2. Read first: `scripts/entity.ps1 -Check` and `-SuggestArchive`.
3. Insert: `-NewProject -Id -Title [-Areas] -Objective -Acceptance` (`-Areas` optional: ids of active repository dossiers or areas) or `-NewResource -Id -Title -Objective`. The identifier must be free.
4. Update: `-SetStatus -EntityId -Status` (project `active|completed|cancelled`; area and resource `active|retired`); update `brief.md`, `context.md`, `memory.md` with the minimal-summary rule.
5. Archive only completed, cancelled or retired entities, and areas with no active linked projects: `-Archive -EntityId`. Restore with `-Restore -EntityId`.
6. After every write run `secondbrain.ps1 -Sync` and `-Check`, and `entity.ps1 -Check`.
</task>

<format>
Report each changed entity, its ID, its path, and its status before and after the change. Include check results and recovery manifests.

Constraints:
- Writes use the `-SessionId` of a write session.
- Use `recover.ps1` to recover an interrupted transaction. Leave recovery markers and generated views to the tools that manage them. Deletion and overwrite require specific authorization.
- An archived dossier is never reactivated implicitly.

Exit criteria:
- `entity.ps1 -Check` and `secondbrain.ps1 -Check` are clean; the entity is present at the expected path with the expected status.
</format>
