// Tracker: read-only view of the trackers of every project bound on this workstation. The project list comes from projects.ps1 -List;
// the tasks of the selected project come from the same registry read as the Registry tab (knowledge.ps1 -Registry on its checkout).
import { $, call, el, fmtDate, input, option, select, toolBadge } from "./common";

interface Project {
  identity: string; name: string; path: string; dossier: string; checkoutExists: boolean; trackerUpdatedAt: string | null;
  tasks: { total: number; todo: number; in_progress: number; blocked: number; done: number; cancelled: number };
  gitUpdate: { mode: string; branch: string; confirmed: boolean };
}
interface NextStep { id: string; kind: string; title: string; why: string; action: { type: string; value: string } }
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
}

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
  select("trk-project").replaceChildren(...projects.map((p) => option(p.identity, `${p.name} (${p.tasks.total})`)));
  if (previous && projects.some((p) => p.identity === previous)) select("trk-project").value = previous;
  $("trk-state").textContent = `${projects.length} projects bound on this workstation`;
  renderProject();
  refreshTasks();
}

function renderProject() {
  const p = selected();
  const facts = $("trk-facts");
  facts.hidden = !p;
  if (!p) { $("trk-counts").replaceChildren(); return; }
  const rows: [string, string][] = [
    ["Identity", p.identity], ["Checkout", p.path + (p.checkoutExists ? "" : " (not found)")], ["Dossier", p.dossier || "—"],
    ["Tracker updated", fmtDate(p.trackerUpdatedAt)],
    ["Git and GitHub update", (GIT_LABEL[p.gitUpdate.mode] ?? p.gitUpdate.mode) + (p.gitUpdate.mode === "none" ? "" : ` on ${p.gitUpdate.branch}`) + (p.gitUpdate.confirmed ? "" : " (proposed default, not confirmed)")],
  ];
  facts.replaceChildren(...rows.flatMap(([k, v]) => [el("dt", {}, k), el("dd", {}, v)]));
  $("trk-counts").replaceChildren(...(["todo", "in_progress", "blocked", "done", "cancelled"] as const).filter((s) => p.tasks[s] > 0).map((s) => toolBadge(STATUS_LABEL[s], String(p.tasks[s]))));
}

async function refreshTasks() {
  const p = selected();
  const rows = $("trk-rows");
  if (!p) { rows.replaceChildren(); $("trk-empty").hidden = true; return; }
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

// Next steps (#659): read-only proposals for the selected project. The window never runs an action; the owner copies the one they choose.
let nextRequest = 0;
function actionText(a: NextStep["action"]): string {
  if (a.type === "task") return `Run task ${a.value} (queue tab, or run-ready-tasks.ps1 -TaskIds ${a.value})`;
  return a.value;
}
async function loadNextSteps() {
  const p = selected();
  const list = $("trk-next-list");
  if (!p || !p.checkoutExists) { list.replaceChildren(); $("trk-next-state").textContent = "Select a project whose checkout is on this workstation."; return; }
  $("trk-next-state").textContent = "Reasoning on the tracker and the last run…";
  const request = ++nextRequest;
  const r = await call<{ steps: NextStep[] }>("next_steps", { repo: p.path }, "trk-next-error");
  if (request !== nextRequest) return;
  if (!r) { $("trk-next-state").textContent = ""; return; }
  $("trk-next-state").textContent = r.steps.length ? `${r.steps.length} proposals` : "Nothing to propose: the tracker, the last run and the setup are in order.";
  list.replaceChildren(...r.steps.map((s) => {
    const copy = el("button", {}, "Copy action");
    copy.addEventListener("click", async () => { try { await navigator.clipboard.writeText(actionText(s.action)); copy.textContent = "Copied"; } catch { copy.textContent = "Copy failed"; } });
    return el("li", {}, el("strong", {}, s.title), el("div", { className: "muted small" }, s.why), el("div", { className: "mono small" }, actionText(s.action)), copy);
  }));
}
