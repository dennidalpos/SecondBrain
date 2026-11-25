//! SecondBrain 5: private project context, decisions and tasks for coding agents,
//! kept outside the repositories and shared by the CLI (`sb`) and an MCP server (`sb mcp`).

pub mod block;
pub mod cli;
pub mod date;
pub mod git;
pub mod mcp;
pub mod migrate;
pub mod ops;
pub mod store;
pub mod task;
