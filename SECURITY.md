# Security policy

## Supported versions

Security fixes are applied to the latest version on `master` (see `VERSION`). 4.x is no longer maintained.

## Reporting a vulnerability

Do not open a public issue. Use GitHub's private reporting: open the **Security** tab of the repository, then **Report a vulnerability**.

Include the SecondBrain version, the steps to reproduce the problem and the expected impact. Do not attach real secrets, tokens or personal data: replace them with dummy values.

Replies are sent in the same private conversation. The fix is published before the details are disclosed.

## Scope

SecondBrain is a local tool: the `sb` binary, its stdio MCP server (`sb mcp`), the blocks it writes in `AGENTS.md` and `CLAUDE.md`, the client configuration entries written by `sb mcp install`, the Git hook written by `sb check --install-hook`, and the agent processes started by `sb run`. Vulnerabilities in Git, the agents or the MCP clients themselves are out of scope.
