//! Tauri commands of the orchestrator. Each command calls one SecondBrain PowerShell CLI; the queue starts run-ready-tasks.ps1 -Run
//! detached (its output goes to a log file) and the window follows it through the run's status.json and events.jsonl, so a run keeps
//! going when the window closes and is found again when it reopens.
mod events;
mod pwsh;
mod settings;

use serde::Deserialize;
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager, State};

pub use settings::Settings;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QueueRequest {
    pub repo: String,
    pub provider: String,
    pub model: Option<String>,
    pub effort: Option<String>,
    #[serde(default)]
    pub allow_custom_model: bool,
    pub task_ids: Vec<String>,
    pub timeout_minutes: u32,
    #[serde(default)]
    pub stall_minutes: Option<u32>,
    /// Wait for the plan limit to reset and go on (-WaitForReset), for at most this many hours (-MaxWaitHours).
    #[serde(default)]
    pub wait_for_reset: bool,
    #[serde(default)]
    pub max_wait_hours: Option<u32>,
    /// Continue the run a quota stop left (run-ready-tasks.ps1 -Resume <runId>): the queue comes from its resume.json, not from task_ids.
    #[serde(default)]
    pub resume: Option<String>,
    /// Run without the Windows power request after the owner chose Run anyway (-AllowNoPowerRequest, #604).
    #[serde(default)]
    pub allow_no_power_request: bool,
}

/// The runner started by this window (while it lives): its process and its stop file.
struct RunInfo {
    pid: u32,
    stop_file: PathBuf,
}

#[derive(Default)]
struct AppState {
    run: Mutex<Option<RunInfo>>,
}

/// pwsh and the SecondBrain root from the saved settings.
fn context(app: &AppHandle) -> Result<(String, PathBuf), String> {
    let s = settings::load(app);
    Ok((pwsh::resolve_pwsh(&s.pwsh_path), pwsh::resolve_root(&s.secondbrain_home)?))
}

async fn script(app: AppHandle, name: &'static str, args: Vec<String>) -> Result<Value, String> {
    let (pwsh_path, root) = context(&app)?;
    tauri::async_runtime::spawn_blocking(move || pwsh::run_json(&pwsh_path, &root, name, &args))
        .await
        .map_err(|e| e.to_string())?
}

fn checkout(path: &str) -> Result<String, String> {
    let p = PathBuf::from(path.trim());
    if !p.is_dir() {
        return Err(format!("Folder not found: {path}"));
    }
    Ok(p.to_string_lossy().into_owned())
}

/// `--repo <path>` or `--repo=<path>` among the process arguments (sb runner passes the checkout it was started from).
pub fn repo_argument(args: &[String]) -> Option<String> {
    let mut it = args.iter();
    while let Some(a) = it.next() {
        if a == "--repo" {
            return it.next().map(|v| v.trim().to_string()).filter(|v| !v.is_empty());
        }
        if let Some(v) = a.strip_prefix("--repo=") {
            let v = v.trim();
            if !v.is_empty() {
                return Some(v.to_string());
            }
        }
    }
    None
}

#[tauri::command]
fn get_launch_context(app: AppHandle) -> Value {
    // What the window needs at start: the repository passed by sb runner, the effective SecondBrain root and PowerShell.
    let args: Vec<String> = std::env::args().collect();
    let s = settings::load(&app);
    let root = pwsh::resolve_root(&s.secondbrain_home);
    serde_json::json!({
        "repo": repo_argument(&args),
        "secondbrainHome": root.as_ref().map(|p| p.to_string_lossy().into_owned()).ok(),
        "rootError": root.err(),
        "pwsh": pwsh::resolve_pwsh(&s.pwsh_path),
        "version": env!("CARGO_PKG_VERSION"),
    })
}

#[tauri::command]
fn get_settings(app: AppHandle) -> Result<Settings, String> {
    // As saved: an empty root means "SECONDBRAIN_HOME or the build checkout" and is never filled in here, so it is not persisted by accident.
    Ok(settings::load(&app))
}

#[tauri::command]
fn save_settings(app: AppHandle, secondbrain_home: String, pwsh_path: String) -> Result<Settings, String> {
    if !secondbrain_home.trim().is_empty() {
        pwsh::resolve_root(&secondbrain_home)?;
    }
    settings::update(&app, |s| {
        s.secondbrain_home = secondbrain_home.trim().to_string();
        s.pwsh_path = pwsh_path.trim().to_string();
    })
}

#[tauri::command]
fn save_light_model(app: AppHandle, provider: String, model: String, effort: String) -> Result<Settings, String> {
    // Empty values are allowed: they mean "agent of the queue" and "light role of the model table".
    if !provider.is_empty() && !valid_provider(&provider) {
        return Err(format!("Unsupported provider: {provider}"));
    }
    for v in [&model, &effort] {
        if !v.is_empty() && !valid_token(v) {
            return Err(format!("Invalid value: {v}"));
        }
    }
    settings::update(&app, |s| {
        s.light_provider = provider.trim().to_string();
        s.light_model = model.trim().to_string();
        s.light_effort = effort.trim().to_string();
    })
}

#[tauri::command]
fn list_recent_repos(app: AppHandle) -> Value {
    let s = settings::load(&app);
    Value::Array(s.recent_repos.iter().map(|p| serde_json::json!({ "path": p, "exists": Path::new(p).is_dir() })).collect())
}

#[tauri::command]
fn add_recent_repo(app: AppHandle, path: String) -> Result<Settings, String> {
    let path = path.trim().to_string();
    settings::update(&app, |s| settings::push_recent(&mut s.recent_repos, &path))
}

#[tauri::command]
fn remove_recent_repo(app: AppHandle, path: String) -> Result<Settings, String> {
    settings::update(&app, |s| settings::remove_recent(&mut s.recent_repos, &path))
}

#[tauri::command]
async fn probe_agents(app: AppHandle) -> Result<Value, String> {
    script(app, "agents.ps1", vec!["-Probe".into(), "-Clients".into()]).await
}

#[tauri::command]
async fn resolve_repository(app: AppHandle, path: String) -> Result<Value, String> {
    script(app, "prompts.ps1", vec!["-Context".into(), "-RepositoryPath".into(), checkout(&path)?]).await
}

#[tauri::command]
async fn read_catalog(app: AppHandle) -> Result<Value, String> {
    // Public prompt catalog as JSON (prompts.ps1 -List -Json, schema secondbrain.prompts.catalog v1).
    script(app, "prompts.ps1", vec!["-List".into(), "-Json".into()]).await
}

#[tauri::command]
async fn read_prompt_card(app: AppHandle, code: String) -> Result<Value, String> {
    // One public card as JSON (prompts.ps1 -Show -Json, schema secondbrain.prompts.card v1).
    if !code.chars().all(|c| c.is_ascii_alphanumeric() || c == '-') || code.is_empty() || code.len() > 16 {
        return Err("Invalid prompt code.".to_string());
    }
    script(app, "prompts.ps1", vec!["-Show".into(), "-Json".into(), "-Prompt".into(), code]).await
}

#[tauri::command]
async fn user_prompts_list(app: AppHandle) -> Result<Value, String> {
    // The user's own prompts (user-prompts.ps1 -List, outside Git in .runtime/user-prompts).
    script(app, "user-prompts.ps1", vec!["-List".into()]).await
}

fn user_prompt_args(mode: &str, fields: &Value) -> Result<Vec<String>, String> {
    let mut args: Vec<String> = vec![mode.into()];
    for (flag, key) in [("-Title", "title"), ("-Role", "role"), ("-Context", "context"), ("-Task", "task"), ("-Format", "format"), ("-Directive", "directive")] {
        let text = fields.get(key).and_then(Value::as_str).unwrap_or("");
        if text.len() > 20_000 {
            return Err(format!("The {key} text is too long."));
        }
        if key == "directive" && text.trim().is_empty() {
            continue;
        }
        args.push(flag.into());
        args.push(text.to_string());
    }
    Ok(args)
}

#[tauri::command]
async fn user_prompt_preview(app: AppHandle, fields: Value) -> Result<Value, String> {
    // Validates the RCTFE fields and returns the composed prompt with its size (user-prompts.ps1 -Preview); writes nothing.
    script(app, "user-prompts.ps1", user_prompt_args("-Preview", &fields)?).await
}

#[tauri::command]
async fn user_prompt_create(app: AppHandle, fields: Value) -> Result<Value, String> {
    script(app, "user-prompts.ps1", user_prompt_args("-Create", &fields)?).await
}

#[tauri::command]
async fn user_prompt_delete(app: AppHandle, id: String) -> Result<Value, String> {
    if id.len() != 12 || !id.starts_with("pmt-") || !id[4..].chars().all(|c| matches!(c, '0'..='9' | 'a'..='f')) {
        return Err("Invalid prompt ID.".to_string());
    }
    script(app, "user-prompts.ps1", vec!["-Delete".into(), "-Id".into(), id]).await
}

#[tauri::command]
async fn read_workflows(app: AppHandle, path: Option<String>) -> Result<Value, String> {
    // Workstation state, next step and start chain as JSON (prompts.ps1 -Json, schema secondbrain.prompts.home v1).
    let mut args: Vec<String> = vec!["-Json".into()];
    if let Some(p) = path.filter(|p| !p.trim().is_empty()) {
        args.push("-RepositoryPath".into());
        args.push(checkout(&p)?);
    }
    script(app, "prompts.ps1", args).await
}

#[tauri::command]
async fn read_setup_status(app: AppHandle) -> Result<Value, String> {
    // Setup status as JSON (setup-status.ps1); -ExitZero keeps "recommendations pending" (exit 1) from being read as a failure.
    script(app, "setup-status.ps1", vec!["-ExitZero".into()]).await
}

fn valid_provider(p: &str) -> bool {
    ["claude", "codex", "gemini"].contains(&p)
}

#[tauri::command]
async fn list_tasks(app: AppHandle, repo: String, provider: Option<String>) -> Result<Value, String> {
    // Preview only: runnable tasks with their prompt, and the excluded ones with the reason; nothing is written.
    // The provider decides the computer-use filter, so the preview uses the agent chosen in the queue.
    let mut args = vec!["-CheckoutPath".into(), checkout(&repo)?, "-MaxTasks".into(), "0".into()];
    if let Some(p) = provider.filter(|p| valid_provider(p)) {
        args.push("-Provider".into());
        args.push(p);
    }
    script(app, "run-ready-tasks.ps1", args).await
}

#[tauri::command]
async fn read_directives(app: AppHandle, repo: String) -> Result<Value, String> {
    script(app, "agents.ps1", vec!["-Directives".into(), "-RepositoryPath".into(), checkout(&repo)?]).await
}

#[tauri::command]
fn read_text_file(path: String) -> Result<String, String> {
    // Directive files only: Markdown, at most 2 MB.
    let p = PathBuf::from(&path);
    let is_md = p.extension().map(|e| e.eq_ignore_ascii_case("md")).unwrap_or(false);
    if !is_md {
        return Err("Only Markdown (.md) files are allowed.".into());
    }
    let meta = std::fs::metadata(&p).map_err(|e| format!("{path}: {e}"))?;
    if meta.len() > 2 * 1024 * 1024 {
        return Err("File too large (over 2 MB).".into());
    }
    std::fs::read_to_string(&p).map_err(|e| format!("{path}: {e}"))
}

fn stamp() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0)
}

#[tauri::command]
async fn preview_directives(app: AppHandle, repo: String, text: String) -> Result<Value, String> {
    // The text goes to a temporary file in the app cache; agents.ps1 copies it into a SecondBrain work folder and previews the proposal.
    let dir = app.path().app_cache_dir().map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let file = dir.join(format!("directives-{}.md", stamp()));
    std::fs::write(&file, text).map_err(|e| e.to_string())?;
    let args = vec![
        "-Directives".into(),
        "-RepositoryPath".into(),
        checkout(&repo)?,
        "-DirectivesFile".into(),
        file.to_string_lossy().into_owned(),
    ];
    let result = script(app, "agents.ps1", args).await;
    let _ = std::fs::remove_file(&file);
    result
}

#[tauri::command]
async fn apply_directives(app: AppHandle, repo: String, proposal_path: String, proposal_hash: String, authorization: String) -> Result<Value, String> {
    if proposal_hash.len() != 64 || !proposal_hash.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err("Invalid proposal hash.".into());
    }
    let args = vec![
        "-Directives".into(),
        "-RepositoryPath".into(),
        checkout(&repo)?,
        "-ProposalPath".into(),
        proposal_path,
        "-ExpectedProposalHash".into(),
        proposal_hash,
        "-Authorization".into(),
        authorization,
        "-Apply".into(),
    ];
    script(app, "agents.ps1", args).await
}

fn valid_token(value: &str) -> bool {
    !value.is_empty() && value.len() <= 120 && value.chars().all(|c| c.is_ascii_alphanumeric() || "._-:/@[]".contains(c))
}
/// Model and effort of an analysis: the explicit choice, or nothing for the light role of the model table.
fn analysis_args(args: &mut Vec<String>, provider: &str, model: Option<String>, effort: Option<String>) -> Result<(), String> {
    if !valid_provider(provider) {
        return Err(format!("Unsupported provider: {provider}"));
    }
    args.push("-Provider".into());
    args.push(provider.into());
    if let Some(m) = model.filter(|m| !m.trim().is_empty()) {
        if !valid_token(m.trim()) {
            return Err(format!("Invalid model name: {m}"));
        }
        args.push("-Model".into());
        args.push(m.trim().into());
        args.push("-AllowCustomModel".into());
    }
    if let Some(e) = effort.filter(|e| !e.trim().is_empty()) {
        if !valid_token(e.trim()) {
            return Err(format!("Invalid effort level: {e}"));
        }
        args.push("-Effort".into());
        args.push(e.trim().into());
    }
    Ok(())
}

#[tauri::command]
async fn analyze_directives(app: AppHandle, repo: String, provider: String, model: Option<String>, effort: Option<String>) -> Result<Value, String> {
    // One read-only run of the light model in the checkout (analysis.directives): proposed sections, what is covered elsewhere, warnings, counts.
    let mut args = vec!["-Analyze".into(), "-Kind".into(), "directives".into(), "-RepositoryPath".into(), checkout(&repo)?];
    analysis_args(&mut args, &provider, model, effort)?;
    script(app, "agents.ps1", args).await
}

#[tauri::command]
async fn analyze_task(app: AppHandle, repo: String, task_id: String, provider: String, model: Option<String>, effort: Option<String>) -> Result<Value, String> {
    // First round of the autonomy analysis of one task (analysis.task): verdict and tool calls (questions or the proposed update).
    if !valid_token(&task_id) {
        return Err("Invalid task ID.".into());
    }
    let mut args = vec!["-Analyze".into(), "-Kind".into(), "task".into(), "-RepositoryPath".into(), checkout(&repo)?, "-TaskId".into(), task_id];
    analysis_args(&mut args, &provider, model, effort)?;
    script(app, "agents.ps1", args).await
}

fn analysis_folder(path: &str) -> Result<String, String> {
    let p = PathBuf::from(path.trim());
    let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    if !p.is_dir() || !name.contains("-analysis-task-") {
        return Err(format!("Invalid analysis folder: {path}"));
    }
    Ok(p.to_string_lossy().into_owned())
}

#[tauri::command]
async fn view_task_analysis(app: AppHandle, repo: String, analysis_path: String) -> Result<Value, String> {
    let args = vec![
        "-Analyze".into(),
        "-Kind".into(),
        "task-view".into(),
        "-RepositoryPath".into(),
        checkout(&repo)?,
        "-AnalysisPath".into(),
        analysis_folder(&analysis_path)?,
    ];
    script(app, "agents.ps1", args).await
}

#[tauri::command]
async fn resolve_task_analysis(app: AppHandle, repo: String, analysis_path: String, answers: Value) -> Result<Value, String> {
    // The owner's answers go to a temporary JSON file; agents.ps1 records them in the analysis folder and runs the next round.
    if answers.as_array().map(|a| a.is_empty()).unwrap_or(true) {
        return Err("No answer to send.".into());
    }
    let dir = app.path().app_cache_dir().map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let file = dir.join(format!("answers-{}.json", stamp()));
    std::fs::write(&file, serde_json::to_string(&answers).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    let args = vec![
        "-Analyze".into(),
        "-Kind".into(),
        "task-resolve".into(),
        "-RepositoryPath".into(),
        checkout(&repo)?,
        "-AnalysisPath".into(),
        analysis_folder(&analysis_path)?,
        "-AnswersFile".into(),
        file.to_string_lossy().into_owned(),
    ];
    let result = script(app, "agents.ps1", args).await;
    let _ = std::fs::remove_file(&file);
    result
}

#[tauri::command]
async fn apply_task_analysis(app: AppHandle, repo: String, analysis_path: String, authorization: String) -> Result<Value, String> {
    if authorization.trim().is_empty() || authorization.len() > 300 {
        return Err("Authorization is missing or too long.".into());
    }
    let args = vec![
        "-Analyze".into(),
        "-Kind".into(),
        "task-apply".into(),
        "-RepositoryPath".into(),
        checkout(&repo)?,
        "-AnalysisPath".into(),
        analysis_folder(&analysis_path)?,
        "-Authorization".into(),
        authorization,
    ];
    script(app, "agents.ps1", args).await
}

/// Arguments of the reviewed enrichment decision (#645): apply needs the person's authorization text, reject needs none.
fn enrichment_decision_args(repo: &str, task_id: &str, apply: bool, authorization: &str) -> Result<Vec<String>, String> {
    if !valid_token(task_id) {
        return Err("Invalid task ID.".into());
    }
    let mut args = vec!["-UpdateTaskId".into(), task_id.into(), "-CheckoutPath".into(), checkout(repo)?];
    if apply {
        if authorization.trim().is_empty() || authorization.len() > 300 {
            return Err("Authorization is missing or too long.".into());
        }
        args.push("-ApplyEnrichment".into());
        args.push("-EnrichmentAuthorization".into());
        args.push(authorization.into());
    } else {
        args.push("-RejectEnrichment".into());
    }
    Ok(args)
}

#[tauri::command]
async fn enrich_task(app: AppHandle, repo: String, task_id: String, provider: String, model: Option<String>, effort: Option<String>) -> Result<Value, String> {
    // The light model proposes the missing detail of an incomplete task (#608); only a pointer reaches the tracker.
    if !valid_token(&task_id) {
        return Err("Invalid task ID.".into());
    }
    let mut args = vec!["-Analyze".into(), "-Kind".into(), "task-enrich".into(), "-RepositoryPath".into(), checkout(&repo)?, "-TaskId".into(), task_id];
    analysis_args(&mut args, &provider, model, effort)?;
    script(app, "agents.ps1", args).await
}

#[tauri::command]
async fn view_task_enrichment(app: AppHandle, repo: String, task_id: String) -> Result<Value, String> {
    // Read-only: the stored proposal of a task, with whether its file still has the recorded hash.
    if !valid_token(&task_id) {
        return Err("Invalid task ID.".into());
    }
    let args = vec!["-Analyze".into(), "-Kind".into(), "task-enrich-view".into(), "-RepositoryPath".into(), checkout(&repo)?, "-TaskId".into(), task_id];
    script(app, "agents.ps1", args).await
}

#[tauri::command]
async fn decide_task_enrichment(app: AppHandle, repo: String, task_id: String, apply: bool, authorization: String) -> Result<Value, String> {
    let args = enrichment_decision_args(&repo, &task_id, apply, &authorization)?;
    script(app, "knowledge.ps1", args).await
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegistryQuery {
    pub repo: String,
    #[serde(default)]
    pub page: u32,
    #[serde(default)]
    pub page_size: Option<u32>,
    pub tool: Option<String>,
    pub status: Option<String>,
    pub archived: Option<String>,
    pub search: Option<String>,
}

/// Arguments of knowledge.ps1 -Registry from the window's filters (values checked against their closed sets).
fn registry_args(q: &RegistryQuery, checkout_path: String) -> Result<Vec<String>, String> {
    let mut args = vec![
        "-Registry".into(),
        "-CheckoutPath".into(),
        checkout_path,
        "-Page".into(),
        q.page.to_string(),
        "-PageSize".into(),
        q.page_size.unwrap_or(50).min(500).to_string(),
    ];
    if let Some(t) = q.tool.as_deref().filter(|t| !t.is_empty()) {
        if !["claude", "codex", "gemini", "antigravity", "human", "unknown"].contains(&t) {
            return Err(format!("Invalid tool: {t}"));
        }
        args.push("-Tool".into());
        args.push(t.into());
    }
    if let Some(s) = q.status.as_deref().filter(|s| !s.is_empty()) {
        if !["todo", "in_progress", "blocked", "done", "cancelled", "unknown"].contains(&s) {
            return Err(format!("Invalid status: {s}"));
        }
        args.push("-TaskStatus".into());
        args.push(s.into());
    }
    if let Some(a) = q.archived.as_deref().filter(|a| !a.is_empty()) {
        if !["include", "exclude", "only"].contains(&a) {
            return Err(format!("Invalid archive filter: {a}"));
        }
        args.push("-Archived".into());
        args.push(a.into());
    }
    if let Some(s) = q.search.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        if s.len() > 100 || s.chars().any(|c| c.is_control()) {
            return Err("Invalid search text.".into());
        }
        args.push("-Filter".into());
        args.push(s.into());
    }
    Ok(args)
}

#[tauri::command]
async fn read_registry(app: AppHandle, query: RegistryQuery) -> Result<Value, String> {
    // Every task of the repository (active and archived) with the tools that worked on it: dossier ledger plus runner reports.
    let args = registry_args(&query, checkout(&query.repo)?)?;
    script(app, "knowledge.ps1", args).await
}

#[tauri::command]
async fn list_projects(app: AppHandle) -> Result<Value, String> {
    // Read-only: the projects bound on this workstation with the task counts of each tracker (projects.ps1 -List).
    script(app, "projects.ps1", vec!["-List".into()]).await
}

/// Git and GitHub update preference (#663): `-SetGitUpdate` of entity.ps1. Without `apply` it only previews; with it the owner has confirmed in the window
/// (`-Apply -Confirmed`). The runner and delegates still never commit or push.
fn git_update_args(identity: &str, mode: &str, branch: Option<&str>, apply: bool) -> Result<Vec<String>, String> {
    if identity.is_empty() || identity.len() > 200 || !identity.chars().all(|c| c.is_ascii_alphanumeric() || "._:/-".contains(c)) {
        return Err("Invalid project identity.".into());
    }
    if !["commit-push-main", "branch-pr", "none"].contains(&mode) {
        return Err(format!("Invalid mode: {mode}"));
    }
    let mut args: Vec<String> = vec!["-SetGitUpdate".into(), "-GitMode".into(), mode.into(), "-Only".into(), identity.into()];
    let branch = branch.map(str::trim).filter(|b| !b.is_empty());
    if mode == "none" {
        if branch.is_some() {
            return Err("No branch is allowed with mode none.".into());
        }
    } else if let Some(b) = branch {
        if b.len() > 100 || b.contains("..") || b.starts_with('-') || !b.chars().all(|c| c.is_ascii_alphanumeric() || "._/-".contains(c)) {
            return Err(format!("Invalid branch: {b}"));
        }
        args.push("-GitBranch".into());
        args.push(b.into());
    }
    if apply {
        args.push("-Apply".into());
        args.push("-Confirmed".into());
    }
    Ok(args)
}

#[tauri::command]
async fn set_git_update(app: AppHandle, identity: String, mode: String, branch: Option<String>, apply: bool) -> Result<Value, String> {
    script(app, "entity.ps1", git_update_args(&identity, &mode, branch.as_deref(), apply)?).await
}

/// Workstation view (#577): a closed set of upkeep actions. Each one is one SecondBrain script; without `apply` the script only previews
/// (or only reads), with it the script writes under its own rules (its own write session and backups), so the window adds no authority.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WorkstationRequest {
    /// hook-install | hook-remove | launcher | check | sync
    action: String,
    client: Option<String>,
    hook: Option<String>,
    identity: Option<String>,
    #[serde(default)]
    apply: bool,
}

fn workstation_args(r: &WorkstationRequest) -> Result<(&'static str, Vec<String>), String> {
    let mut args: Vec<String> = Vec::new();
    let script = match r.action.as_str() {
        "hook-install" | "hook-remove" => {
            let client = r.client.as_deref().unwrap_or_default();
            if !["claude-code", "codex", "antigravity"].contains(&client) {
                return Err(format!("Invalid client: {client}"));
            }
            let hook = r.hook.as_deref().unwrap_or_default();
            if !["resources-hook", "trace-hook"].contains(&hook) {
                return Err(format!("Invalid hook: {hook}"));
            }
            args.push(if r.action == "hook-install" { "-Install" } else { "-Uninstall" }.into());
            args.extend(["-Client".into(), client.into(), "-Hook".into(), hook.into()]);
            if r.apply {
                args.push("-Apply".into());
            }
            "client-hooks.ps1"
        }
        "launcher" => {
            if let Some(id) = r.identity.as_deref().filter(|i| !i.is_empty()) {
                if id.len() > 200 || !id.chars().all(|c| c.is_ascii_alphanumeric() || "._:/-".contains(c)) {
                    return Err("Invalid project identity.".into());
                }
                args.extend(["-Repository".into(), id.into()]);
            }
            if r.apply {
                args.push("-Apply".into());
            }
            "install-task-launcher.ps1"
        }
        // -Check is the read-only preview of -Sync: only a real sync writes.
        "check" | "sync" => {
            if r.action == "sync" && r.apply {
                args.push("-Sync".into());
            } else {
                args.push("-Check".into());
            }
            "secondbrain.ps1"
        }
        other => return Err(format!("Unknown workstation action: {other}")),
    };
    Ok((script, args))
}

/// The exact command line of the action, as the person would type it from the SecondBrain checkout.
fn workstation_command_line(script: &str, args: &[String]) -> String {
    let quoted: Vec<String> = args.iter().map(|a| if a.contains(' ') { format!("\"{a}\"") } else { a.clone() }).collect();
    format!("pwsh -NoProfile -File scripts/{script} {}", quoted.join(" ")).trim_end().to_string()
}

#[tauri::command]
fn workstation_command(request: WorkstationRequest) -> Result<String, String> {
    let (script, args) = workstation_args(&request)?;
    Ok(workstation_command_line(script, &args))
}

#[tauri::command]
async fn workstation_run(app: AppHandle, request: WorkstationRequest) -> Result<Value, String> {
    let (script_name, args) = workstation_args(&request)?;
    let command = workstation_command_line(script_name, &args);
    let result = script(app, script_name, args).await?;
    Ok(serde_json::json!({ "command": command, "apply": request.apply, "result": result }))
}

/// Arguments of subagents.ps1 -Operation Create for the agent wizard (#623): the definition travels in a file, never on the command line.
fn agent_wizard_args(identity: &str, file: &str, apply: bool) -> Result<Vec<String>, String> {
    if identity.is_empty() || identity.len() > 200 || !identity.chars().all(|c| c.is_ascii_alphanumeric() || "._:/-".contains(c)) {
        return Err("Invalid project identity.".into());
    }
    let mut args: Vec<String> = vec!["-Operation".into(), "Create".into(), "-Repository".into(), identity.into(), "-DefinitionPath".into(), file.into()];
    if apply {
        args.push("-Apply".into());
    }
    Ok(args)
}

#[tauri::command]
async fn agent_wizard(app: AppHandle, identity: String, definition: Value, apply: bool) -> Result<Value, String> {
    // Preview or save of one new schema 2 definition. The script validates the same definition both times; its answer carries the
    // definition as it is (or would be) written, so the window shows exactly what is saved.
    let text = serde_json::to_string(&definition).map_err(|e| e.to_string())?;
    if !definition.is_object() || text.len() > 100_000 {
        return Err("Invalid definition.".into());
    }
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let file = std::env::temp_dir().join(format!("sb-agent-wizard-{}-{nanos}.json", std::process::id()));
    std::fs::write(&file, text).map_err(|e| e.to_string())?;
    let result = match agent_wizard_args(&identity, &file.to_string_lossy(), apply) {
        Ok(a) => script(app, "subagents.ps1", a).await,
        Err(e) => Err(e),
    };
    let _ = std::fs::remove_file(&file);
    result
}

fn clean_text(value: &str, max: usize, what: &str) -> Result<String, String> {
    let v = value.trim();
    if v.is_empty() || v.chars().count() > max || v.chars().any(|c| c.is_control()) {
        return Err(format!("Invalid {what}."));
    }
    Ok(v.to_string())
}

/// Arguments of knowledge.ps1 -NewTask for a follow-up task proposed by a next step (#672). `-NewTask` is the SecondBrain task tool:
/// the window never edits a tracker itself. A criterion cannot contain `;` (the script splits the list on it).
fn followup_args(repo: &str, title: &str, description: &str, priority: &str, acceptance: &[String]) -> Result<Vec<String>, String> {
    let title = clean_text(title, 200, "title")?;
    let description = clean_text(description, 2000, "description")?;
    if !["P0", "P1", "P2", "P3"].contains(&priority) {
        return Err(format!("Invalid priority: {priority}"));
    }
    if acceptance.is_empty() || acceptance.len() > 10 {
        return Err("One to ten acceptance criteria are required.".into());
    }
    // -Provenance is mandatory: the dossier's context.md always exists; the pointer names the proposed task.
    let title_pointer = title.clone();
    let mut criteria = Vec::new();
    for a in acceptance {
        let a = clean_text(a, 300, "acceptance criterion")?;
        if a.contains(';') {
            return Err("An acceptance criterion cannot contain ';'.".into());
        }
        criteria.push(a);
    }
    Ok(vec![
        "-CheckoutPath".into(), repo.into(),
        "-NewTask".into(), title,
        "-Description".into(), description,
        "-Priority".into(), priority.into(),
        "-Provenance".into(), "context.md".into(),
        "-ProvenancePointer".into(), title_pointer,
        "-Acceptance".into(), criteria.join(";"),
    ])
}

#[tauri::command]
async fn create_followup_task(app: AppHandle, repo: String, title: String, description: String, priority: String, acceptance: Vec<String>, apply: bool) -> Result<Value, String> {
    // Preview (apply = false) validates and returns the task exactly as it would be created; nothing is written. With apply the owner has confirmed.
    let args = followup_args(&checkout(&repo)?, &title, &description, &priority, &acceptance)?;
    if !apply {
        return Ok(serde_json::json!({ "apply": false, "task": { "title": title.trim(), "description": description.trim(), "priority": priority, "acceptance": acceptance.iter().map(|a| a.trim()).collect::<Vec<_>>() } }));
    }
    let result = script(app, "knowledge.ps1", args).await?;
    Ok(serde_json::json!({ "apply": true, "result": result }))
}

#[tauri::command]
fn open_card(app: AppHandle, file: String) -> Result<String, String> {
    // Read-only: shows a prompt card of the SecondBrain checkout (direttive/prompts/<CODE>.md); no script runs and nothing is written.
    let ok = file.len() <= 16 && file.ends_with(".md") && file[..file.len() - 3].chars().enumerate().all(|(i, c)| if i < 2 { c.is_ascii_uppercase() } else { c.is_ascii_uppercase() || c.is_ascii_digit() });
    if !ok {
        return Err("Invalid card.".into());
    }
    let (_, root) = context(&app)?;
    read_text_file(root.join("direttive").join("prompts").join(&file).to_string_lossy().into_owned())
}

#[tauri::command]
async fn next_steps(app: AppHandle, repo: String) -> Result<Value, String> {
    // Read-only: reasoned next steps for the project (next-steps.ps1); an action is only named here, the owner chooses it.
    script(app, "next-steps.ps1", vec!["-CheckoutPath".into(), checkout(&repo)?]).await
}

#[tauri::command]
async fn list_runs(app: AppHandle, repo: String, limit: Option<u32>) -> Result<Value, String> {
    let n = limit.unwrap_or(50).min(1000).to_string();
    script(app, "runner-status.ps1", vec!["-CheckoutPath".into(), checkout(&repo)?, "-List".into(), "-Limit".into(), n]).await
}

#[tauri::command]
async fn add_run_note(app: AppHandle, repo: String, folder: String, note: String) -> Result<Value, String> {
    // A note of the window (start, stop, reattach) kept in the run's events.jsonl, so it survives a reattach.
    let note = note.trim().to_string();
    if note.is_empty() || note.len() > 500 || note.chars().any(|c| c.is_control()) {
        return Err("Invalid note.".into());
    }
    script(app, "runner-status.ps1", vec!["-CheckoutPath".into(), checkout(&repo)?, "-Note".into(), note, "-RunFolder".into(), folder]).await
}


/// Arguments of run-ready-tasks.ps1 for a queue started by the window: the chosen tasks, or the resume point of a run stopped by a plan limit.
fn queue_args(request: &QueueRequest, checkout_path: String, stop_file: &str) -> Result<Vec<String>, String> {
    if !valid_provider(&request.provider) {
        return Err(format!("Unsupported provider: {}", request.provider));
    }
    let resume = request.resume.as_deref().map(str::trim).filter(|r| !r.is_empty());
    if let Some(r) = resume {
        if !valid_token(r) || r.contains('/') {
            return Err(format!("Invalid resume point: {r}"));
        }
    } else if request.task_ids.is_empty() || !request.task_ids.iter().all(|t| valid_token(t)) {
        return Err("Task list empty or invalid.".into());
    }
    let mut args: Vec<String> = vec![
        "-CheckoutPath".into(),
        checkout_path,
        "-Run".into(),
        "-Events".into(),
        "-MaxTasks".into(),
        "0".into(),
        "-TimeoutMinutes".into(),
        request.timeout_minutes.clamp(1, 240).to_string(),
        "-Provider".into(),
        request.provider.clone(),
        "-StopFile".into(),
        stop_file.into(),
    ];
    match resume {
        Some(r) => {
            args.push("-Resume".into());
            args.push(r.into());
        }
        None => {
            args.push("-TaskIds".into());
            args.push(request.task_ids.join(","));
        }
    }
    if let Some(s) = request.stall_minutes {
        args.push("-StallMinutes".into());
        args.push(s.clamp(1, 240).to_string());
    }
    if request.allow_no_power_request {
        args.push("-AllowNoPowerRequest".into());
    }
    if request.wait_for_reset {
        args.push("-WaitForReset".into());
        args.push("-MaxWaitHours".into());
        args.push(request.max_wait_hours.unwrap_or(24).clamp(1, 168).to_string());
    }
    if let Some(m) = request.model.as_deref().filter(|m| !m.is_empty()) {
        if !valid_token(m) {
            return Err(format!("Invalid model name: {m}"));
        }
        args.push("-Model".into());
        args.push(m.into());
    }
    if let Some(e) = request.effort.as_deref().filter(|e| !e.is_empty()) {
        if !valid_token(e) {
            return Err(format!("Invalid effort level: {e}"));
        }
        args.push("-Effort".into());
        args.push(e.into());
    }
    if request.allow_custom_model {
        args.push("-AllowCustomModel".into());
    }
    // The person confirmed model and effort in the window (a "predefinito" entry is an explicit choice of the CLI default):
    // the runner refuses an unattended start without that choice, so the window states it.
    let has_model = request.model.as_deref().is_some_and(|m| !m.is_empty());
    let has_effort = request.effort.as_deref().is_some_and(|e| !e.is_empty());
    if !has_model || !has_effort {
        args.push("-UseCliDefault".into());
    }
    Ok(args)
}

#[tauri::command]
fn start_queue(app: AppHandle, state: State<'_, AppState>, request: QueueRequest) -> Result<Value, String> {
    let mut guard = state.run.lock().map_err(|e| e.to_string())?;
    if guard.is_some() {
        return Err("A queue started from this window is already running.".into());
    }
    let (pwsh_path, root) = context(&app)?;
    let cache = app.path().app_cache_dir().map_err(|e| e.to_string())?;
    std::fs::create_dir_all(&cache).map_err(|e| e.to_string())?;
    let id = stamp();
    let stop_file = cache.join(format!("stop-{id}.flag"));
    let log_file = cache.join(format!("runner-{id}.log"));
    let args = queue_args(&request, checkout(&request.repo)?, &stop_file.to_string_lossy())?;
    // Output to files, not pipes: the runner must outlive the window (a closed pipe would break its progress writes).
    let err = std::fs::File::create(&log_file).map_err(|e| e.to_string())?;
    let out = std::fs::File::create(log_file.with_extension("out")).map_err(|e| e.to_string())?;
    let mut child = pwsh::script_command(&pwsh_path, &root, "run-ready-tasks.ps1", &args)
        .stdin(Stdio::null())
        .stdout(Stdio::from(out))
        .stderr(Stdio::from(err))
        .spawn()
        .map_err(|e| format!("Runner start failed ({pwsh_path}): {e}"))?;
    let pid = child.id();
    *guard = Some(RunInfo { pid, stop_file: stop_file.clone() });
    drop(guard);

    let done_app = app.clone();
    let log = log_file.clone();
    std::thread::spawn(move || {
        let code = child.wait().ok().and_then(|s| s.code());
        let _ = std::fs::remove_file(&stop_file);
        if let Some(state) = done_app.try_state::<AppState>() {
            if let Ok(mut g) = state.run.lock() {
                *g = None;
            }
        }
        // The last lines of the runner log explain a run that ended before its status existed (busy repository, invalid model).
        let tail = std::fs::read_to_string(&log).map(|t| events::last_lines(&t, 12)).unwrap_or_default();
        let stdout = std::fs::read_to_string(log.with_extension("out")).unwrap_or_default();
        let _ = done_app.emit("runner-finished", serde_json::json!({ "code": code, "pid": pid, "log": tail, "stdout": stdout }));
    });
    Ok(serde_json::json!({ "pid": pid, "log": log_file.to_string_lossy() }))
}

#[tauri::command]
async fn get_run_status(app: AppHandle, repo: String, tail: Option<u32>) -> Result<Value, String> {
    // Active run of the repository (or the newest one) as runner-status.ps1 reports it: verdict, ages, status.json, recent events.
    let n = tail.unwrap_or(0).min(500).to_string();
    script(app, "runner-status.ps1", vec!["-CheckoutPath".into(), checkout(&repo)?, "-Tail".into(), n]).await
}

#[tauri::command]
fn read_run_events(app: AppHandle, folder: String, offset: u64) -> Result<Value, String> {
    // New lines of events.jsonl from a byte offset; the folder must be a runner run folder under the SecondBrain root.
    let (_, root) = context(&app)?;
    let file = events::run_events_file(&root, Path::new(&folder))?;
    events::read_from(&file, offset)
}

#[tauri::command]
async fn stop_queue(app: AppHandle, state: State<'_, AppState>, repo: String, force: bool) -> Result<bool, String> {
    // A run started by this window: its stop file or its process tree. A run found again after a restart: runner-status.ps1 -Stop,
    // or the process recorded in its status.json.
    let local = {
        let guard = state.run.lock().map_err(|e| e.to_string())?;
        guard.as_ref().map(|r| (r.pid, r.stop_file.clone()))
    };
    if let Some((pid, stop_file)) = local {
        if force {
            pwsh::kill_tree(pid)?;
        } else {
            std::fs::write(&stop_file, "stop").map_err(|e| e.to_string())?;
        }
        return Ok(true);
    }
    if !force {
        script(app, "runner-status.ps1", vec!["-CheckoutPath".into(), checkout(&repo)?, "-Stop".into()]).await?;
        return Ok(true);
    }
    let status = script(app, "runner-status.ps1", vec!["-CheckoutPath".into(), checkout(&repo)?, "-Tail".into(), "0".into()]).await?;
    let active = status.get("active").and_then(Value::as_bool).unwrap_or(false);
    let pid = status.pointer("/status/pid").and_then(Value::as_u64).filter(|p| *p > 0);
    match (active, pid) {
        (true, Some(pid)) => {
            pwsh::kill_tree(pid as u32)?;
            Ok(true)
        }
        _ => Ok(false),
    }
}

#[tauri::command]
fn local_run(state: State<'_, AppState>) -> Option<u32> {
    // PID of the runner started by this window, if it is still running.
    state.run.lock().ok().and_then(|g| g.as_ref().map(|r| r.pid))
}

/// Browser arguments of the windows when WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS is set: wry always passes its own arguments through the
/// WebView2 API, and the runtime then ignores the variable, so the app forwards it after wry's defaults (the end-to-end tests open the
/// DevTools port this way). None leaves wry's defaults untouched.
fn browser_args(extra: Option<String>) -> Option<String> {
    let extra = extra.map(|e| e.trim().to_string()).filter(|e| !e.is_empty())?;
    Some(format!("--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection {extra}"))
}

/// Tray (close-to-tray): the window never ends the app; the runner is detached anyway, so the tray keeps its state in view.
struct TrayHandles {
    status: tauri::menu::MenuItem<tauri::Wry>,
    tray: tauri::tray::TrayIcon<tauri::Wry>,
}

fn show_main_window(app: &AppHandle) {
    if let Some(w) = app.get_webview_window("main") {
        let _ = w.unminimize();
        let _ = w.show();
        let _ = w.set_focus();
    }
}

/// Status line of the tray (menu entry and tooltip), pushed by the window each time the run verdict changes.
#[tauri::command]
fn set_tray_status(state: State<'_, TrayHandles>, text: String) {
    let text: String = text.chars().take(120).collect();
    let _ = state.status.set_text(&text);
    let _ = state.tray.set_tooltip(Some(format!("SecondBrain Orchestrator: {text}")));
}

/// Ends the app. The runner is detached and keeps working; the window asks what to do with an active run before calling this.
#[tauri::command]
fn quit_app(app: AppHandle) {
    app.exit(0);
}

fn build_tray(app: &tauri::App) -> tauri::Result<()> {
    use tauri::menu::{Menu, MenuItem, PredefinedMenuItem};
    use tauri::tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent};
    let status = MenuItem::with_id(app, "status", "Idle", false, None::<&str>)?;
    let show = MenuItem::with_id(app, "show", "Show window", true, None::<&str>)?;
    let stop = MenuItem::with_id(app, "stop", "Stop after the current task", true, None::<&str>)?;
    let abort = MenuItem::with_id(app, "abort", "Abort now…", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, "quit", "Quit", true, None::<&str>)?;
    let sep1 = PredefinedMenuItem::separator(app)?;
    let sep2 = PredefinedMenuItem::separator(app)?;
    let menu = Menu::with_items(app, &[&status, &sep1, &show, &stop, &abort, &sep2, &quit])?;
    let mut builder = TrayIconBuilder::with_id("main")
        .tooltip("SecondBrain Orchestrator: Idle")
        .menu(&menu)
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id.as_ref() {
            "show" => show_main_window(app),
            // The window owns the repository and the confirmations: show it, then it acts.
            id @ ("stop" | "abort" | "quit") => {
                show_main_window(app);
                let _ = app.emit("tray-action", id);
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                show_main_window(tray.app_handle());
            }
        });
    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }
    let tray = builder.build(app)?;
    app.manage(TrayHandles { status, tray });
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let mut context = tauri::generate_context!();
    if let Some(args) = browser_args(std::env::var("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS").ok()) {
        for window in context.config_mut().app.windows.iter_mut() {
            window.additional_browser_args = Some(args.clone());
        }
    }
    tauri::Builder::default()
        // A second launch (sb runner passes --repo <checkout>) shows the running window and asks it to load that repository (#731).
        .plugin(tauri_plugin_single_instance::init(|app, argv, _cwd| {
            if let Some(w) = app.get_webview_window("main") {
                let _ = w.unminimize();
                let _ = w.show();
                let _ = w.set_focus();
            }
            if let Some(repo) = repo_argument(&argv) {
                let _ = app.emit("launch-repo", repo);
            }
        }))
        .plugin(tauri_plugin_dialog::init())
        .manage(AppState::default())
        .setup(|app| {
            build_tray(app)?;
            Ok(())
        })
        // The window's X hides it to the tray; only the tray's Quit (or quit_app) ends the app.
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .invoke_handler(tauri::generate_handler![
            get_launch_context,
            get_settings,
            save_settings,
            save_light_model,
            list_recent_repos,
            add_recent_repo,
            remove_recent_repo,
            probe_agents,
            resolve_repository,
            read_catalog,
            read_prompt_card,
            user_prompts_list,
            user_prompt_preview,
            user_prompt_create,
            user_prompt_delete,
            read_workflows,
            read_setup_status,
            list_tasks,
            read_directives,
            read_text_file,
            preview_directives,
            apply_directives,
            start_queue,
            get_run_status,
            read_run_events,
            stop_queue,
            local_run,
            analyze_directives,
            analyze_task,
            view_task_analysis,
            resolve_task_analysis,
            apply_task_analysis,
            enrich_task,
            view_task_enrichment,
            decide_task_enrichment,
            read_registry,
            list_projects,
            next_steps,
            create_followup_task,
            open_card,
            set_git_update,
            agent_wizard,
            workstation_command,
            workstation_run,
            list_runs,
            add_run_note,
            set_tray_status,
            quit_app
        ])
        .run(context)
        .expect("error while running the orchestrator");
}

#[cfg(test)]
mod tests {
    use super::{workstation_args, workstation_command_line, WorkstationRequest, followup_args, analysis_args, browser_args, enrichment_decision_args, git_update_args, agent_wizard_args, queue_args, registry_args, repo_argument, valid_token, QueueRequest, RegistryQuery};

    fn queue(task_ids: &[&str], resume: Option<&str>) -> QueueRequest {
        QueueRequest {
            repo: ".".into(),
            provider: "claude".into(),
            model: Some("opus".into()),
            effort: None,
            allow_custom_model: false,
            task_ids: task_ids.iter().map(|t| t.to_string()).collect(),
            timeout_minutes: 60,
            stall_minutes: None,
            wait_for_reset: false,
            max_wait_hours: None,
            resume: resume.map(Into::into),
            allow_no_power_request: false,
        }
    }

    #[test]
    fn followup_args_validate_the_task() {
        let ok = followup_args(".", "Title", "Why", "P2", &["one".to_string(), "two".to_string()]).unwrap();
        assert!(ok.contains(&"-NewTask".to_string()) && ok.last().unwrap() == "one;two");
        let at = |flag: &str| ok.iter().position(|a| a == flag).map(|i| ok[i + 1].clone());
        assert_eq!(at("-Provenance").as_deref(), Some("context.md"));
        assert_eq!(at("-ProvenancePointer").as_deref(), Some("Title"));
        assert!(followup_args(".", "", "Why", "P2", &["one".to_string()]).is_err());
        assert!(followup_args(".", "T", "Why", "P9", &["one".to_string()]).is_err());
        assert!(followup_args(".", "T", "Why", "P2", &[]).is_err());
        assert!(followup_args(".", "T", "Why", "P2", &["a;b".to_string()]).is_err());
    }

    #[test]
    fn queue_and_resume_arguments() {
        // A new queue names its tasks; a resume (#554) passes -Resume with the stopped run and no task list: the queue is in resume.json.
        let fresh = queue_args(&queue(&["T-1", "T-2"], None), "C".into(), "stop.flag").unwrap();
        assert!(fresh.windows(2).any(|w| w == ["-TaskIds", "T-1,T-2"]));
        assert!(!fresh.iter().any(|a| a == "-Resume"));
        assert!(fresh.windows(2).any(|w| w == ["-StopFile", "stop.flag"]));
        assert!(fresh.iter().any(|a| a == "-UseCliDefault"));
        // #604: -AllowNoPowerRequest only after the owner chose Run anyway.
        assert!(!fresh.iter().any(|a| a == "-AllowNoPowerRequest"));
        let mut anyway = queue(&["T-1"], None);
        anyway.allow_no_power_request = true;
        assert!(queue_args(&anyway, "C".into(), "s").unwrap().iter().any(|a| a == "-AllowNoPowerRequest"));
        let resumed = queue_args(&queue(&[], Some(" 2026-11-13-runner-run-101500-42 ")), "C".into(), "stop.flag").unwrap();
        assert!(resumed.windows(2).any(|w| w == ["-Resume", "2026-11-13-runner-run-101500-42"]));
        assert!(!resumed.iter().any(|a| a == "-TaskIds"));
        assert!(resumed.windows(2).any(|w| w == ["-Model", "opus"]));
        assert!(queue_args(&queue(&[], Some("latest")), "C".into(), "s").is_ok());
        assert!(queue_args(&queue(&[], None), "C".into(), "s").is_err());
        assert!(queue_args(&queue(&[], Some("  ")), "C".into(), "s").is_err());
        assert!(queue_args(&queue(&[], Some("../x")), "C".into(), "s").is_err());
        assert!(queue_args(&queue(&[], Some("a b")), "C".into(), "s").is_err());
    }

    #[test]
    fn webview_arguments() {
        assert_eq!(browser_args(None), None);
        assert_eq!(browser_args(Some("  ".into())), None);
        let args = browser_args(Some("--remote-debugging-port=9333".into())).unwrap();
        assert!(args.starts_with("--disable-features=msWebOOUI,msPdfOOUI,msSmartScreenProtection "));
        assert!(args.ends_with("--remote-debugging-port=9333"));
    }

    #[test]
    fn tokens() {
        assert!(valid_token("claude-opus-5-5"));
        assert!(valid_token("T-12"));
        assert!(!valid_token("a b"));
        assert!(!valid_token("x;rm"));
        assert!(!valid_token(""));
    }

    #[test]
    fn analysis_and_registry_arguments() {
        let mut a: Vec<String> = Vec::new();
        assert!(analysis_args(&mut a, "claude", Some("haiku".into()), None).is_ok());
        assert_eq!(a, vec!["-Provider", "claude", "-Model", "haiku", "-AllowCustomModel"]);
        let mut b: Vec<String> = Vec::new();
        assert!(analysis_args(&mut b, "other", None, None).is_err());
        assert!(analysis_args(&mut b, "codex", Some("x;y".into()), None).is_err());
        let q = |tool: Option<&str>, status: Option<&str>, search: Option<&str>| RegistryQuery {
            repo: ".".into(),
            page: 1,
            page_size: Some(20),
            tool: tool.map(Into::into),
            status: status.map(Into::into),
            archived: Some("only".into()),
            search: search.map(Into::into),
        };
        let args = registry_args(&q(Some("codex"), Some("done"), Some(" runner ")), "C".into()).unwrap();
        assert!(args.windows(2).any(|w| w == ["-Tool", "codex"]));
        assert!(args.windows(2).any(|w| w == ["-TaskStatus", "done"]));
        assert!(args.windows(2).any(|w| w == ["-Filter", "runner"]));
        assert!(args.windows(2).any(|w| w == ["-Page", "1"]));
        assert!(registry_args(&q(Some("vim"), None, None), "C".into()).is_err());
        assert!(registry_args(&q(None, Some("open"), None), "C".into()).is_err());
        assert!(registry_args(&q(None, None, Some("a\nb")), "C".into()).is_err());
    }

    #[test]
    fn enrichment_decision_arguments() {
        let dir = std::env::temp_dir().to_string_lossy().into_owned();
        let apply = enrichment_decision_args(&dir, "T-1", true, "OK from the desktop app").unwrap();
        assert!(apply.contains(&"-ApplyEnrichment".to_string()) && apply.windows(2).any(|w| w == ["-EnrichmentAuthorization", "OK from the desktop app"]));
        let reject = enrichment_decision_args(&dir, "T-1", false, "").unwrap();
        assert!(reject.contains(&"-RejectEnrichment".to_string()) && !reject.contains(&"-EnrichmentAuthorization".to_string()));
        assert!(enrichment_decision_args(&dir, "T-1", true, "  ").is_err());
        assert!(enrichment_decision_args(&dir, "T 1;x", false, "").is_err());
    }

    #[test]
    fn agent_wizard_arguments() {
        let preview = agent_wizard_args("github.com/test/a", "d.json", false).unwrap();
        assert!(preview.windows(2).any(|w| w == ["-Operation", "Create"]) && preview.windows(2).any(|w| w == ["-DefinitionPath", "d.json"]) && !preview.contains(&"-Apply".to_string()));
        assert!(agent_wizard_args("github.com/test/a", "d.json", true).unwrap().contains(&"-Apply".to_string()));
        assert!(agent_wizard_args("bad id;x", "d.json", false).is_err());
    }

    #[test]
    fn git_update_arguments() {
        let preview = git_update_args("github.com/test/a", "branch-pr", Some("feature/x"), false).unwrap();
        assert!(preview.contains(&"-SetGitUpdate".to_string()) && !preview.contains(&"-Apply".to_string()) && !preview.contains(&"-Confirmed".to_string()));
        assert!(preview.windows(2).any(|w| w == ["-GitBranch", "feature/x"]));
        let apply = git_update_args("github.com/test/a", "commit-push-main", None, true).unwrap();
        assert!(apply.contains(&"-Apply".to_string()) && apply.contains(&"-Confirmed".to_string()) && !apply.contains(&"-GitBranch".to_string()));
        assert!(git_update_args("github.com/test/a", "none", Some("main"), false).is_err());
        assert!(git_update_args("github.com/test/a", "force-push", None, false).is_err());
        assert!(git_update_args("github.com/test/a", "branch-pr", Some("a..b"), false).is_err());
        assert!(git_update_args("github.com/test/a", "branch-pr", Some("--x"), false).is_err());
        assert!(git_update_args("bad id;x", "none", None, false).is_err());
    }

    #[test]
    fn workstation_arguments() {
        let req = |action: &str, client: Option<&str>, hook: Option<&str>, identity: Option<&str>, apply: bool| WorkstationRequest {
            action: action.into(), client: client.map(Into::into), hook: hook.map(Into::into), identity: identity.map(Into::into), apply,
        };
        let (s, a) = workstation_args(&req("hook-install", Some("codex"), Some("trace-hook"), None, false)).unwrap();
        assert_eq!(s, "client-hooks.ps1");
        assert!(!a.contains(&"-Apply".to_string()));
        assert_eq!(workstation_command_line(s, &a), "pwsh -NoProfile -File scripts/client-hooks.ps1 -Install -Client codex -Hook trace-hook");
        let (_, a) = workstation_args(&req("hook-remove", Some("antigravity"), Some("resources-hook"), None, true)).unwrap();
        assert!(a.contains(&"-Uninstall".to_string()) && a.contains(&"-Apply".to_string()));
        assert!(workstation_args(&req("hook-install", Some("codex;x"), Some("trace-hook"), None, false)).is_err());
        assert!(workstation_args(&req("hook-install", Some("codex"), Some("other-hook"), None, false)).is_err());
        let (s, a) = workstation_args(&req("launcher", None, None, Some("github.com/test/a"), true)).unwrap();
        assert_eq!(workstation_command_line(s, &a), "pwsh -NoProfile -File scripts/install-task-launcher.ps1 -Repository github.com/test/a -Apply");
        assert!(workstation_args(&req("launcher", None, None, Some("bad id;x"), false)).is_err());
        // Sync previews as -Check; only an apply is a real -Sync.
        assert_eq!(workstation_args(&req("sync", None, None, None, false)).unwrap().1, vec!["-Check".to_string()]);
        assert_eq!(workstation_args(&req("sync", None, None, None, true)).unwrap().1, vec!["-Sync".to_string()]);
        assert_eq!(workstation_args(&req("check", None, None, None, true)).unwrap().1, vec!["-Check".to_string()]);
        assert!(workstation_args(&req("cleanup", None, None, None, true)).is_err());
    }

    #[test]
    fn repo_argument_forms() {
        let a = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(repo_argument(&a(&["app", "--repo", "D:/x y"])), Some("D:/x y".into()));
        assert_eq!(repo_argument(&a(&["app", "--repo=/srv/u/p"])), Some("/srv/u/p".into()));
        assert_eq!(repo_argument(&a(&["app", "--repo"])), None);
        assert_eq!(repo_argument(&a(&["app", "--repo", "  "])), None);
        assert_eq!(repo_argument(&a(&["app"])), None);
    }
}
