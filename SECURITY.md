# Security Policy

## Supported versions

Only the latest commit on the `master` branch is supported (see [VERSION](VERSION)).

## Reporting a vulnerability

Please do not open a public issue for security problems.

Use GitHub's private vulnerability reporting: open the **Security** tab of this repository and choose **Report a vulnerability**. Include the SecondBrain version, the steps to reproduce and the impact you observed. Use dummy values; never attach real secrets, tokens or personal data.

You can expect an acknowledgement within a few days. Confirmed issues are fixed on `master` and disclosed after a fix is available.

## Scope notes

- SecondBrain is a local tool: the `sb` binary, its stdio MCP server (`sb mcp`), the blocks it writes in `AGENTS.md` and `CLAUDE.md`, the client configuration entries written by `sb mcp install`, the Git hook written by `sb check --install-hook`, and the agent processes started by `sb run`.
- Vulnerabilities in Git, the agents or the MCP clients themselves are out of scope.
