# Agents and MCP

SecondBrain distributes approved instructions and can configure a local stdio MCP connection. Configuration support does not prove that an IDE loaded those instructions or that every profile has been qualified.

~~~mermaid
flowchart LR
    C[Agent client] -->|stdio, no network port| S[mcp-server.ps1]
    S -->|read-only tools| K[Project dossier]
    S -->|submit_dossier_write| R{Local approval receipt}
    R -->|approved| K
~~~

## Instruction and configuration targets

| Target | Configuration scope |
|---|---|
| Claude Desktop | User-level MCP with -Target claude; this does not establish how instructions were loaded |
| Codex | User-level MCP with -Target codex; project pairing is not accepted |
| Antigravity | User-level MCP or explicit project -Scope project -WorkspacePath |
| Claude Code | User CLI registration with -Target claude-code, or project .mcp.json with -WorkspacePath |
| VS Code | User/profile MCP, or project .vscode/mcp.json with -WorkspacePath |
| Cursor | User MCP, or project .cursor/mcp.json with -Scope project -WorkspacePath |

Other adapters exist in the implementation; consult [adapter qualification](riferimento/adapters.md) for their actual scope. Do not label an adapter live-qualified from file inspection or a synthetic handshake alone.

In managed repositories, `AGENTS.md` is the common source. Sync manages `CLAUDE.md` and `GEMINI.md` pointers using `@AGENTS.md`. Existing text outside managed blocks is preserved. IDE-specific support and account-level settings require separate checks. SecondBrain does not inspect credential stores or automate login.

## Preview, pair and verify

~~~powershell
pwsh -NoProfile -File scripts/mcp-server.ps1 -Pair -Target cursor -Scope project -WorkspacePath $project
pwsh -NoProfile -File scripts/mcp-server.ps1 -Pair -Target cursor -Scope project -WorkspacePath $project -Apply
~~~

Run this project-scoped Cursor example from the SecondBrain checkout with $project set to the selected Git checkout. It was verified on synthetic configuration, without launching a client.

Preview user-level pairing separately for Codex or Claude Desktop; neither target accepts project scope. Review Setup's user-level MCP preview for selected supported IDEs or explicit `-McpTargets`. In interactive Setup, review the destination and named tool rules before entering `APPLICA`. For direct pairing, preview first. Apply changes the selected configuration with backup. Restart the client and inspect its MCP connection in a new session. SYS15 guides multi-client installation; SYS01 handles profile/account evidence. For workspace targets, inspect the explicit destination before applying.

## Exposed tools

| Tool | CLI equivalent |
|---|---|
| `get_startup_context` | `knowledge.ps1 -Startup [-Profile Full]` |
| `get_ready_tasks` | `knowledge.ps1 -Tasks -ReadyOnly` |
| `get_runner_status` | `runner-status.ps1` |
| `get_decisions` | `decisions.ps1 -List [-Status open] [-TaskId <id>]` |
| `get_task` | `knowledge.ps1 -Task <id or sequence>` |
| `search_knowledge` | `knowledge.ps1 -Search <text> [-Mode Relevance]` |
| `get_prompt_home` | `prompts.ps1` |
| `list_prompts` | `prompts.ps1 -List -Compact` |
| `get_prompt` | `prompts.ps1 -Show -Prompt <code>` |
| `check_publication` | `publication.ps1 -RepositoryPath <checkout>` |
| `list_ides` | `ide-detect.ps1 [-WorkspacePath <path>] -Json` |
| `preview_dossier_write` | Reviewed plan preparation; see the [write guide](riferimento/mcp-writes.md) (including the optional per-repository grant for task operations) |
| `submit_dossier_write` | Submit one plan after local CLI approval; see the [write guide](riferimento/mcp-writes.md) |

`ide-detect.ps1` stays read-only. Its selection (`-Ides` with `-Scope`, or `-Interactive`) echoes each IDE, scope and location plus a `pairCommand`: the preview-only `mcp-server.ps1 -Pair -Target <id> -Scope <user|project>` command (no `-Apply`; `system` scope and IDEs without a Pair target get `null`). Run it yourself, then confirm with APPLICA to write; `secondbrain.ps1 -Setup` keeps its own `-Ides` selector.

The server exposes thirteen tools. The compact `tools/list` response (`id=2`) measures 10,829 characters (2026-11-13, with `get_decisions`; `result` only: 10,795). Method: server started with `-NoRecovery`, `initialize` with `id=1`, `initialized` notification, `tools/list` with `id=2`, length of the compact JSON line returned. These are characters, not tokens. Measured again on 2026-11-15 (#653) as the compact JSON response to `tools/list`: 10,678 characters for the 13 tools (largest: `search_knowledge` 1,516, `preview_dossier_write` 1,494, `get_startup_context` 1,107; descriptions are 55-152 characters each, so the cost is mostly the input schemas). Start the server with `-ToolProfile reader` (8 read tools, 6,668 characters, -37%) or `-ToolProfile executor` (six tools for a task run: startup context, ready tasks, task, search, prompt and publication check, 5,347 characters, -50%) to expose fewer tools; the default `full` keeps all 13. A tool outside the profile is absent from `tools/list` and refused by `tools/call` as unknown. The pending suite fails when a profile lists a different tool count or grows beyond 10,700, 6,700 or 5,400 characters. Task status/new-task writes and memory/history appends are available through reviewed MCP submission as well as the CLI. Activity submission remains disabled until its activation procedure is complete. Compaction still uses reviewed CLI maintenance. Use `-CheckoutPath` or `-Repository` when the current working directory does not resolve the product. The global task view is opt-in with `-All`, paginated by `-Offset` and `-Limit` (default 50).

A/B measurement (2026-11-15, #653): same task ("id, title and first 120 characters of the blocker of the lowest-seq ready task"), same agent (`claude -p`, haiku), same prompt, 3 runs per arm, run sequentially from the repository. MCP arms: strict MCP config, Bash and PowerShell denied. CLI arm: no MCP, `Bash(pwsh *)` and Read allowed (`knowledge.ps1`). Per-run means:

| Arm | Turns | Input tokens (incl. cache) | Output tokens | Cost (USD) | Wall time | Permission denials | Correct |
|---|---|---|---|---|---|---|---|
| MCP full | 3.0 | 142,143 | 2,161 | 0.0082 | 24.8 s | 0 | 3/3 |
| MCP reader profile | 2.7 | 128,003 | 1,714 | 0.0078 | 22.1 s | 0 | 3/3 |
| CLI only | 12.0 | 504,502 | 3,728 | 0.0118 | 64.1 s | 5 (in 2 of 3 runs) | 3/3 |

Reading: for a structured read the MCP saves about 70% of the turns, 72% of the input tokens, 30% of the cost and 60% of the time, and needs no permission prompt; the agent on the CLI explores `knowledge.ps1` output with several Bash calls and hit denials on piped commands. The reader profile saves a further 10% of input tokens at no loss of correctness. The tool list is a fixed cost paid every session (about 10.7k characters, 6.7k for reader, 5.3k for executor). Limits: one synthetic read task, one model, n=3, cost is the list price from `total_cost_usd`; writes, long sessions and other models were not measured. The CLI is better for ad hoc output shaping (pipes, filters) when Bash is already allowed, for operations without an MCP tool, and when no MCP server may be started; use `-ToolProfile reader` or `executor` for read-only agents.

## Reads may have side effects

The server runs over stdio and does not listen on a network port. It never applies queued dossier writes at startup or during lookups; every tool advertises readOnlyHint=true except submit_dossier_write, which requires a local approval receipt. Knowledge tools and the publication gate have distinct consent requirements.

A refused `submit_dossier_write` names its cause (no grant and no receipt, grant revoked, grant expired, receipt expired, receipt for a different plan, session of another repository) and prints the exact `mcp-write.ps1 -Grant` and `-Approve` commands with the repository and plan hash filled in and placeholders for the plan path, `SessionId` and `Authorization`. Approval given in chat does not count; what is accepted does not change.

To forbid new writes for a session start `mcp-server.ps1 -NoRecovery`; per-call `noRecovery=true` forbids them for that call. Queued writes are integrated only by `knowledge.ps1 -FlushPending`.

Repository memory collection is enabled separately and requires a verified permission policy for the turn. Fixture tests do not qualify native live collectors. See [memory cycle and known limits](riferimento/memory-cycle.md#known-limits).

## Packages

Tool descriptions and messages are English only; `SECONDBRAIN_LANG`, `-Language` and the MCP `language` argument were removed in 3.0 (no deprecation window). Restart a client/server session when cached tool descriptions need updating.

`-ExportPackage` creates a launcher and required modules for importing the connection elsewhere; keep the package together and review its destination. A package or a successful handshake does not prove live client loading. See [MCP setup](riferimento/mcp-setup.md).

## Troubleshooting

1. Inspect `-Pair -Target <client>` for the intended path and scope.
2. Run the repository's MCP handshake checks to distinguish protocol failures from client configuration.
3. Inspect the connection in the real client; Claude Code provides `/mcp`, while Codex CLI provides `codex mcp list`.
4. Check named tool permissions without granting broader access than the current workflow needs.
5. Record account/profile, instruction revision, observed loading and the popup outcome for the exact tool. `secondbrain.ps1 -Check -ObservationPath` reports `mcp-consent-unverified` for a supported IDE with an incomplete or invalid consent observation.

Use the shell when MCP is unavailable. CLI access has the same data model, while shell permissions remain those of the session. Detailed procedures: [adapters](riferimento/adapters.md), [MCP setup](riferimento/mcp-setup.md), [deferred writes](riferimento/pending-writes.md).
