// Tracker: read-only view of the trackers of every project bound on this workstation. The project list comes from projects.ps1 -List;
// the tasks of the selected project come from the same registry read as the Registry tab (knowledge.ps1 -Registry on its checkout).
import { $, call, el, fmtDate, input, option, select, setError, toolBadge } from "./common";
import { initWizard, syncWizard } from "./wizard";

interface Project {
  identity: string; name: string; path: string; dossier: string; checkoutExists: boolean; trackerUpdatedAt: string | null;
  tasks: { total: number; todo: number; in_progress: number; blocked: number; done: number; cancelled: number };
  gitUpdate: { mode: string; branch: string; confirmed: boolean } | null;
  kind?: "repository" | "workspace"; access?: string; outputScope?: string[];
}
interface NextStep {
  id: string; kind: string; title: string; why: string; action: { type: string; value: string };
  followUp?: { title: string; description: string; priority: string; acceptance: string[] };
  card?: { id: string; file: string; title: string };
}
interface TrackerTask { id: string; seq: number | null; title: string; status: string; priority: string; archived: boolean; lastActivity: string | null; closedAt: string | null }
interface TrackerPage { total: number; offset: number; nextOffset: number | null; tasks: TrackerTask[] }

const STATUS_LABEL: Record<string, string> = { todo: "to do", in_progress: "in progress", blocked: "blocked", done: "done", cancelled: "cancelled", unknown: "unknown" };
const GIT_LABEL: Record<string, string> = { "commit-push-main": "commit and push on the main branch", "branch-pr": "branch and pull request", none: "no Git update" };
const PAGE_SIZE = 50;
let projects: Project[] = [];
let page = 0;
// Each read is numbered: a slower answer for a previous project or filter never overwrites the current rows.
let listRequest = 0;
let taskRequest = 0;

export function initTracker() {
  select("trk-status").replaceChildren(option("", "All statuses"), ...Object.keys(STATUS_LABEL).map((s) => option(s, STATUS_LABEL[s])));
  select("trk-project").addEventListener("change", () => { page = 0; renderProject(); refreshTasks(); $("trk-next-list").replaceChildren(); $("trk-next-state").textContent = ""; });
  select("trk-status").addEventListener("change", () => { page = 0; refreshTasks(); });
  let timer = 0;
  input("trk-search").addEventListener("input", () => { window.clearTimeout(timer); timer = window.setTimeout(() => { page = 0; refreshTasks(); }, 350); });
  $("trk-prev").addEventListener("click", () => { if (page > 0) { page--; refreshTasks(); } });
  $("trk-next").addEventListener("click", () => { page++; refreshTasks(); });
  $("trk-refresh").addEventListener("click", () => showTracker());
  $("trk-next-load").addEventListener("click", () => loadNextSteps());
  initGitUpdate();
  initWizard(() => {});
}

function isWorkspace(p: Project): boolean { return p.kind === "workspace"; }

function selected(): Project | undefined {
  const id = select("trk-project").value;
  return projects.find((p) => p.identity === id);
}

export async function showTracker() {
  const request = ++listRequest;
  $("trk-state").textContent = "Reading the projects…";
  const previous = select("trk-project").value;
  const r = await call<{ projects: Project[] }>("list_projects", {}, "trk-error");
  if (request !== listRequest) return;
  if (!r) { $("trk-state").textContent = ""; return; }
  projects = r.projects;
  select("trk-project").replaceChildren(...projects.map((p) => option(p.identity, isWorkspace(p) ? `${p.name} (workspace)` : `${p.name} (${p.tasks.total})`)));
  if (previous && projects.some((p) => p.identity === previous)) select("trk-project").value = previous;
  $("trk-state").textContent = `${projects.length} projects bound on this workstation`;
  renderProject();
  refreshTasks();
}

function renderProject() {
  const p = selected();
  const facts = $("trk-facts");
  facts.hidden = !p;
  if (!p) { $("trk-counts").replaceChildren(); $("trk-git-box").hidden = true; syncWizard(null); return; }
  const g = p.gitUpdate;
  const rows: [string, string][] = isWorkspace(p)
    ? [["Identity", p.identity], ["Workspace folder", p.path + (p.checkoutExists ? "" : " (not found)")], ["Dossier", p.dossier || "—"],
      ["Access", p.access ?? "read-only"], ["Output scope", p.outputScope?.length ? p.outputScope.join(", ") : "none"]]
    : [
      ["Identity", p.identity], ["Checkout", p.path + (p.checkoutExists ? "" : " (not found)")], ["Dossier", p.dossier || "—"],
      ["Tracker updated", fmtDate(p.trackerUpdatedAt)],
      ["Git and GitHub update", g ? (GIT_LABEL[g.mode] ?? g.mode) + (g.mode === "none" ? "" : ` on ${g.branch}`) + (g.confirmed ? "" : " (proposed default, not confirmed)") : "—"],
    ];
  facts.replaceChildren(...rows.flatMap(([k, v]) => [el("dt", {}, k), el("dd", {}, v)]));
  $("trk-counts").replaceChildren(...(["todo", "in_progress", "blocked", "done", "cancelled"] as const).filter((s) => p.tasks[s] > 0).map((s) => toolBadge(STATUS_LABEL[s], String(p.tasks[s]))));
  syncGitBox();
  syncWizard(isWorkspace(p) ? null : p);
}

async function refreshTasks() {
  const p = selected();
  const rows = $("trk-rows");
  if (!p) { rows.replaceChildren(); $("trk-empty").hidden = true; return; }
  if (isWorkspace(p)) {
    rows.replaceChildren();
    $("trk-empty").hidden = false;
    $("trk-empty").textContent = "This is a personal workspace without a tracker: the task runner and task reads do not apply to it.";
    return;
  }
  if (!p.checkoutExists) {
    rows.replaceChildren();
    $("trk-empty").hidden = false;
    $("trk-empty").textContent = "The checkout of this project is not on this workstation: its tasks cannot be read here.";
    return;
  }
  const query = { repo: p.path, page, pageSize: PAGE_SIZE, status: select("trk-status").value || null, archived: "include", search: input("trk-search").value.trim() || null };
  const request = ++taskRequest;
  const r = await call<TrackerPage>("read_registry", { query }, "trk-error");
  if (request !== taskRequest || !r) return;
  $("trk-empty").textContent = "No task matches these filters.";
  $("trk-empty").hidden = r.tasks.length > 0;
  $<HTMLButtonElement>("trk-prev").disabled = page === 0;
  $<HTMLButtonElement>("trk-next").disabled = r.nextOffset === null;
  rows.replaceChildren(...r.tasks.map((t) => {
    const tr = el("tr", { className: t.archived ? "archived" : "" });
    [t.seq != null ? String(t.seq) : "—", t.id, t.title + (t.archived ? " (archived)" : ""), el("span", { className: "state-" + t.status }, STATUS_LABEL[t.status] ?? t.status), t.priority, fmtDate(t.lastActivity ?? t.closedAt)]
      .forEach((c) => tr.append(el("td", {}, c)));
    return tr;
  }));
}

// Next steps (#659, #664): proposals for the selected project. An action needs two explicit clicks: Preview shows exactly what it does,
// Confirm performs it. The window never starts a run or writes a tracker from here: "Open in the queue" only selects the task in the Queue tab.
let nextRequest = 0;
function actionText(a: NextStep["action"]): string {
  if (a.type === "task") return `Run task ${a.value} (queue tab, or run-ready-tasks.ps1 -TaskIds ${a.value})`;
  return a.value;
}
function stepItem(s: NextStep, repo: string, errId: string): HTMLElement {
  const copy = el("button", {}, "Copy action");
  copy.addEventListener("click", async () => { try { await navigator.clipboard.writeText(actionText(s.action)); copy.textContent = "Copied"; } catch { copy.textContent = "Copy failed"; } });
  const buttons: HTMLElement[] = [copy];
  const extra: HTMLElement[] = [];
  if (s.followUp) {
    // Create follow-up (#672): the preview comes from the backend (validated, nothing written); only Confirm writes, through knowledge.ps1 -NewTask.
    const f = s.followUp;
    const box = el("pre", { className: "box small followup-preview", hidden: true });
    const result = el("div", { className: "small followup-result" });
    const confirm = el("button", { className: "primary followup-confirm", hidden: true }, "Confirm: create the task");
    const open = el("button", { className: "followup-preview-btn" }, "Preview follow-up task");
    const args = (apply: boolean) => ({ repo, title: f.title, description: f.description, priority: f.priority, acceptance: f.acceptance, apply });
    open.addEventListener("click", async () => {
      const r = await call<{ task: { title: string; description: string; priority: string; acceptance: string[] } }>("create_followup_task", args(false), errId);
      if (!r) return;
      box.textContent = `New task, nothing written yet:\n${r.task.priority} ${r.task.title}\n${r.task.description}\nAcceptance:\n${r.task.acceptance.map((a) => "- " + a).join("\n")}`;
      box.hidden = false;
      confirm.hidden = false;
    });
    confirm.addEventListener("click", async () => {
      confirm.disabled = true;
      const r = await call<{ apply: boolean }>("create_followup_task", args(true), errId);
      confirm.disabled = false;
      if (!r) return;
      result.textContent = "Task created through the SecondBrain task tool.";
      box.hidden = true;
      confirm.hidden = true;
    });
    buttons.push(open, confirm);
    extra.push(box, result);
  }
  if (s.card) {
    // Open card (#672): read-only, shows the card text; nothing is written.
    const c = s.card;
    const view = el("pre", { className: "box small card-view", hidden: true });
    const open = el("button", { className: "card-open" }, "Open card");
    open.addEventListener("click", async () => {
      const text = await call<string>("open_card", { file: c.file }, errId);
      if (text == null) return;
      view.textContent = text;
      view.hidden = false;
    });
    buttons.push(open);
    extra.push(view);
  }
  if (s.action.type === "task") {
    const preview = el("div", { className: "box small", hidden: true });
    const confirm = el("button", { className: "primary", hidden: true }, "Confirm: open in the queue");
    const open = el("button", { className: "next-preview" }, "Preview action");
    open.addEventListener("click", () => {
      preview.textContent = `Opens the Queue tab of ${repo} with task ${s.action.value} selected. Nothing is started or written; you still start the run yourself.`;
      preview.hidden = false;
      confirm.hidden = false;
    });
    confirm.addEventListener("click", () => {
      document.dispatchEvent(new CustomEvent("sb-open-task", { detail: { repo, taskId: s.action.value } }));
      preview.hidden = true;
      confirm.hidden = true;
    });
    buttons.push(open, confirm);
    return el("li", {}, el("strong", {}, s.title), el("div", { className: "muted small" }, s.why), el("div", { className: "mono small" }, actionText(s.action)), ...buttons, preview, ...extra);
  }
  return el("li", {}, el("strong", {}, s.title), el("div", { className: "muted small" }, s.why), el("div", { className: "mono small" }, actionText(s.action)), ...buttons, ...extra);
}
/** Loads the proposals of a project into a list; shared by the Tracker tab and the end of a run. */
export async function loadNextStepsInto(repo: string, ids: { list: string; state: string; error: string }, token: () => number): Promise<void> {
  $(ids.state).textContent = "Reasoning on the tracker and the last run…";
  const request = token();
  const r = await call<{ steps: NextStep[] }>("next_steps", { repo }, ids.error);
  if (request !== nextRequest) return;
  if (!r) { $(ids.state).textContent = ""; return; }
  $(ids.state).textContent = r.steps.length ? `${r.steps.length} proposals` : "Nothing to propose: the tracker, the last run and the setup are in order.";
  $(ids.list).replaceChildren(...r.steps.map((s) => stepItem(s, repo, ids.error)));
}
/** Panel of proposals shown when a run ends; same preview-then-confirm actions as the Tracker tab. */
export async function showRunEndNextSteps(repo: string): Promise<void> {
  await loadNextStepsInto(repo, { list: "run-next-list", state: "run-next-state", error: "run-next-error" }, () => ++nextRequest);
}
async function loadNextSteps() {
  const p = selected();
  const list = $("trk-next-list");
  if (!p || isWorkspace(p) || !p.checkoutExists) { list.replaceChildren(); $("trk-next-state").textContent = "Select a project whose checkout is on this workstation."; return; }
  await loadNextStepsInto(p.path, { list: "trk-next-list", state: "trk-next-state", error: "trk-next-error" }, () => ++nextRequest);
}

// Git and GitHub update preference (#663): preview first, then an explicit confirmation; the window never commits or pushes.
let gitPreviewKey = "";
function gitKey(): string { return `${select("trk-git-mode").value}|${select("trk-git-mode").value === "none" ? "" : input("trk-git-branch").value.trim()}`; }
function syncGitBox() {
  const p = selected();
  const box = $("trk-git-box");
  box.hidden = !p || isWorkspace(p) || !p.gitUpdate;
  if (box.hidden || !p || !p.gitUpdate) return;
  select("trk-git-mode").value = p.gitUpdate.mode;
  input("trk-git-branch").value = p.gitUpdate.branch || "main";
  input("trk-git-branch").disabled = p.gitUpdate.mode === "none";
  gitPreviewKey = "";
  $<HTMLButtonElement>("trk-git-apply").disabled = true;
  $("trk-git-plan").hidden = true;
  setError("trk-git-error", null);
}
function gitArgs(apply: boolean) {
  const p = selected()!;
  const mode = select("trk-git-mode").value;
  return { identity: p.identity, mode, branch: mode === "none" ? null : input("trk-git-branch").value.trim() || null, apply };
}
export function initGitUpdate() {
  select("trk-git-mode").addEventListener("change", () => { input("trk-git-branch").disabled = select("trk-git-mode").value === "none"; gitPreviewKey = ""; $<HTMLButtonElement>("trk-git-apply").disabled = true; });
  input("trk-git-branch").addEventListener("input", () => { gitPreviewKey = ""; $<HTMLButtonElement>("trk-git-apply").disabled = true; });
  $("trk-git-preview").addEventListener("click", async () => {
    if (!selected()) return;
    const r = await call<{ apply: boolean; dossiers: { repository: string; before: { mode: string; branch?: string }; after: { mode: string; branch?: string }; changed: boolean }[] }>("set_git_update", gitArgs(false), "trk-git-error");
    if (!r) return;
    const lines = r.dossiers.map((d) => `${d.repository}: ${d.before.mode}${d.before.branch ? " on " + d.before.branch : ""} -> ${d.after.mode}${d.after.branch ? " on " + d.after.branch : ""}${d.changed ? "" : " (no change)"}`);
    $("trk-git-plan").textContent = "Preview, nothing written yet:\n" + lines.join("\n");
    $("trk-git-plan").hidden = false;
    gitPreviewKey = gitKey();
    $<HTMLButtonElement>("trk-git-apply").disabled = false;
  });
  $("trk-git-apply").addEventListener("click", async () => {
    if (!selected() || gitPreviewKey !== gitKey()) return;
    const r = await call<{ apply: boolean }>("set_git_update", gitArgs(true), "trk-git-error");
    if (!r) return;
    $("trk-git-plan").textContent = "Saved. The runner and the agents still never commit or push.";
    gitPreviewKey = "";
    $<HTMLButtonElement>("trk-git-apply").disabled = true;
    await showTracker();
    $("trk-git-plan").hidden = false;
  });
}
