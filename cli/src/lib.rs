//! SecondBrain: private project context, decisions and tasks for coding agents,
//! kept outside the repositories and shared by the CLI (`sb`) and an MCP server (`sb mcp`).

pub mod block;
pub mod check;
pub mod cli;
pub mod date;
pub mod doctor;
mod executable;
pub mod git;
pub mod guide;
pub mod index;
pub mod kb;
pub mod mcp;
pub mod mcp_install;
pub mod migrate;
pub mod ops;
pub mod portable;
mod prepare;
pub mod run;
pub mod skills;
pub mod start;
pub mod store;
pub mod sync;
pub mod task;
