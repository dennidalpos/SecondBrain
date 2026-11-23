# Per-repository workflow

Use chat conventions or the same PowerShell scripts. Run central scripts from the SecondBrain checkout and identify the product checkout explicitly when needed.

~~~mermaid
flowchart LR
    A[Activate] --> B[Sync]
    B --> C[Load context]
    C --> D[Choose ready work]
    D --> E[Implement]
    E --> F[Publication check]
    F --> G[Close work]
    G -.->|only when necessary| H[Compact]
~~~

| Step | Chat | CLI or action |
|---|---|---|
| Activate once per workstation | `sb activate` | `scripts/secondbrain.ps1 -Setup -Interactive` |
| Sync approved instructions | `sb sync` | `scripts/secondbrain.ps1 -Sync` |
| Verify the IDE integration | `sb prompt WKS05` | `scripts/ide-map.ps1 -Verify` plus live client evidence |
| Load essential context | `sb prompt TRK01` | `scripts/knowledge.ps1 -Startup -CheckoutPath <product>` |
| Choose ready work | `sb prompt TRK02` | `scripts/knowledge.ps1 -Tasks -ReadyOnly -CheckoutPath <product>` |
| Implement authorized work | Agent in the product repository | Follow repository instructions and session permissions |
| Check before any authorized push | `sb prompt RSK07` | `scripts/publication.ps1 -RepositoryPath <product>` |
| Close authorized work | `sb prompt SES02` | Update permitted tracker/context/memory, then Sync and Check |
| Compaction | `sb compact` · `sb compact ai` | Mechanical and lossless at every task close (`knowledge.ps1 -Compact -Mechanical`; add `-Apply` to write by hand); `scripts/compact-ai.ps1 -Provider <p>` for the light-model pass, then `-CandidatePath <file> -Apply -ReviewNote <text>` after your review |

Knowledge lookups never write; pending writes are integrated only by an explicit `knowledge.ps1 -FlushPending`. Audits that propose tracker changes leave the tracker unchanged; do not close a task simply because some code exists.

## Show the current next step

~~~powershell
pwsh -NoProfile -File scripts/prompts.ps1 -RepositoryPath C:/Projects/MyProduct
~~~

The MCP equivalent is `get_prompt_home` with `repositoryPath`. Without a checkout argument the menu is generic. The chat agent must supply the actual checkout rather than infer it from a dossier folder name.

## Chat and CLI boundaries

`sb` commands are conventions written in managed instructions, not shell executables. The CLI and MCP expose the same knowledge operations, but permissions and client approvals are separate. Installing an instruction file, registering an account/profile, successful stdio communication and proving live loading are separate checks.

The product agent runs builds and tests and captures screenshots. Build output, caches, temporary files, fixtures and evidence stay in Git-ignored folders of the product checkout. A dedicated work folder created for a capture or test run (fixtures, fixture files, raw screenshots) is removed when the work ends, once the reviewed results are stored where they belong; nothing is left behind for later runs. The SecondBrain dossier retains summaries and references to those results.

See [daily use](daily-use.md), [agents and MCP](ide-e-mcp.md), [trackers](reference/trackers.md) and [runtime maintenance](reference/runtime-maintenance.md).
