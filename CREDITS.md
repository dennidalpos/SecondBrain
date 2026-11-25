# Credits and third-party attributions

SecondBrain is distributed under the [MIT](LICENSE) license. This page lists what it is built with.

## Rust crates

`sb` is built from source with Cargo; the versions are pinned in [cli/Cargo.lock](cli/Cargo.lock).

| Crate | Version | License (SPDX) | Role |
| --- | --- | --- | --- |
| [anyhow](https://github.com/dtolnay/anyhow) | 1.0.105 | MIT OR Apache-2.0 | Error handling |
| [clap](https://github.com/clap-rs/clap) (derive) | 4.6.10 | MIT OR Apache-2.0 | Command-line parsing |
| [regex](https://github.com/rust-lang/regex) | 1.13.2 | MIT OR Apache-2.0 | Publication check rules |
| [serde](https://github.com/serde-rs/serde) | 1.0.229 | MIT OR Apache-2.0 | Serialization |
| [serde_json](https://github.com/serde-rs/json) (`preserve_order`) | 1.0.154 | MIT OR Apache-2.0 | JSON for MCP and client configuration files |

Transitive dependencies: 37 crates in the lock (all platforms), all permissive: MIT OR Apache-2.0 (31), Unlicense OR MIT (2), MIT (2), Zlib (1), and `unicode-ident` under (MIT OR Apache-2.0) AND Unicode-3.0. If a binary is distributed, attach the license notices of the included crates and the Unicode-3.0 notice.

## Tools and formats

- [Git](https://git-scm.com/) (GPL-2.0): invoked as an external command, neither embedded nor redistributed.
- [AGENTS.md](https://agents.md): the open format for coding-agent instructions; [Claude Code memory](https://code.claude.com/docs/en/memory) for the `@AGENTS.md` import in `CLAUDE.md`.
- [Model Context Protocol](https://modelcontextprotocol.io/): the stdio transport and tool interface served by `sb mcp`.
- The name echoes Tiago Forte's *Building a Second Brain* (2022); SecondBrain does not implement its method.

## Trademarks

Claude, Codex, Gemini, Cursor, Visual Studio Code, Windsurf and the other names mentioned belong to their owners. SecondBrain is not affiliated with them.
