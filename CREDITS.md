# Credits and third-party attributions

SecondBrain is distributed under the [MIT](LICENSE) license. These are its direct dependencies and the formats it uses.

## Rust crates

`sb` is built from source with Cargo; the versions are pinned in [cli/Cargo.lock](cli/Cargo.lock).

| Crate | License (SPDX) | Role |
| --- | --- | --- |
| [anyhow](https://github.com/dtolnay/anyhow) | MIT OR Apache-2.0 | Error handling |
| [clap](https://github.com/clap-rs/clap) (derive) | MIT OR Apache-2.0 | Command-line parsing |
| [regex](https://github.com/rust-lang/regex) | MIT OR Apache-2.0 | Publication check rules |
| [rusqlite](https://github.com/rusqlite/rusqlite) (`bundled`) | MIT | SQLite FTS5 search index (SQLite itself is public domain) |
| [serde](https://github.com/serde-rs/serde) | MIT OR Apache-2.0 | Serialization |
| [serde_json](https://github.com/serde-rs/json) (`preserve_order`) | MIT OR Apache-2.0 | JSON for MCP and client configuration files |

The lockfile records the exact versions for all direct and transitive dependencies. Release archives include the applicable upstream notices in `THIRD-PARTY-LICENSES.txt`.

## Tools and formats

- [Git](https://git-scm.com/) (GPL-2.0): invoked as an external command, neither embedded nor redistributed.
- [AGENTS.md](https://agents.md): the open format for coding-agent instructions; [Claude Code memory](https://code.claude.com/docs/en/memory) for the `@AGENTS.md` import in `CLAUDE.md`.
- [Model Context Protocol](https://modelcontextprotocol.io/): the stdio transport and tool interface served by `sb mcp`.
- The name echoes Tiago Forte's *Building a Second Brain* (2022); SecondBrain does not implement its method.

## Trademarks

Claude, Codex, Gemini, Cursor, Visual Studio Code, Windsurf and the other names mentioned belong to their owners. SecondBrain is not affiliated with them.
