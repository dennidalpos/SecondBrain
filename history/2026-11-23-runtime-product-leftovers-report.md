# #447 Runtime product leftovers: report (preview only, nothing deleted)

Sources: `cleanup.ps1 -ListRuntime`, `-ProposeRuntime`; manifest: `history/2026-11-23-runtime-product-leftovers-manifest.json` (per-folder file count, bytes, tree SHA-256).

| Folder under `.runtime/hosts/ws-c73fc81f38f82abe/repos/` | Files | Size | OnlyWorkspace-* dirs | Class |
|---|---|---|---|---|
| onlyworkspace-3ea3da05 | 32827 | 4152 MB | 18 | product output (bin/obj/nuget), modified 4 days ago |
| onlyworkspace-cf86dc06 | 0 | 0 | 0 | empty product folder |
| tmp-20261110-28dc74a2 | 3007 | 201 MB | 783 | test output |
| tmp-20261111-28dc74a2 | 2248 | 135 MB | 536 | test output |
| fixture-20261110-28dc74a2 | 1062 | 54 MB | 96 | test output |
| fixture-20261111-28dc74a2 | 846 | 36 MB | 64 | test output |

Also proposed by cleanup.ps1: 123 old fixture folders in `tests/` (1.2 GB, regenerable), 143 `.bin` backups of Git-tracked files.
Left: owner confirms #446 (no product still writes in `.runtime`), re-verify hashes, then `-Apply` with `-Authorization`.
