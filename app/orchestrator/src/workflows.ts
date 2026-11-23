// Workflows tab (#576): start a shipped workflow, then follow the run step by step. A run is pinned to the workflow revision and the card hashes,
// persists the status of each step (.runtime/workflow-runs, workflow-runs.ps1) and resumes from the first step that is not done.
// The window tracks state and launches nothing: the person runs each step's card and records the outcome; a confirm gate waits for an answer.
import { $, call, el, fmtStamp, input, onBusyClick, option, setError } from "./common";

interface FlowStep { step: string; ref: string; code: string; summary: string; kind: string; gate: string; choices: { ref: string; code: string; summary: string }[] }
interface Flow { id: string; key: string; title: string; revision: number; pack: string; steps: FlowStep[] }
interface RunStep {
  step: string; ref: string; kind: string; gate: string; status: string; choice: string; decisionId: string;
  decision: { status: string; question: string; answer: string } | null; evidence: string; startedAt: string; endedAt: string;
}
export interface Run {
  runId: string; repository: string; workflow: { id: string; key: string; revision: number; title: string }; objective: string; state: string;
  steps: RunStep[]; current: string | null; done: number; total: number; createdAt: string; updatedAt: string;
}
interface RunList { runs: Run[]; count: number }

let flows: Flow[] = [];
let identity: () => string = () => "";
let open: Run | null = null;

/** Where a run stands for the person: what the next click does. Pure, so it can be tested without the window. */
export function nextAction(run: Run): "begin" | "answer" | "record" | "resume" | "none" {
  if (run.state === "finished") return "none";
  if (run.state === "stopped" || run.state === "failed") return "resume";
  const s = run.steps.find((x) => x.step === run.current);
  if (!s) return "none";
  return s.status === "waiting-user" ? "answer" : s.status === "running" ? "record" : "begin";
}

const STATUS_LABEL: Record<string, string> = { pending: "pending", running: "running", "waiting-user": "waiting for you", done: "done", skipped: "skipped", failed: "failed" };

async function op<T>(operation: string, extra: Record<string, unknown> = {}): Promise<T | null> {
  return call<T>("workflow_run", { operation, identity: identity(), ...extra }, "wf-error");
}

function renderFlows() {
  const sel = $("wf-flow") as HTMLSelectElement;
  sel.replaceChildren(...flows.map((f) => option(f.key, f.title)));
  renderSkips();
}

/** Optional steps of the selected workflow can be skipped before the run starts; required and choice steps cannot. */
function renderSkips() {
  const flow = flows.find((f) => f.key === ($("wf-flow") as HTMLSelectElement).value);
  const box = $("wf-skips");
  box.replaceChildren(...(flow?.steps.filter((s) => s.kind === "optional") ?? []).map((s) => {
    const cb = el("input", { type: "checkbox", value: s.step });
    return el("label", { className: "inline" }, cb, ` Skip ${s.code}: ${s.summary}`);
  }));
}

async function showRuns() {
  const r = await op<RunList>("inspect");
  if (!r) return;
  const rows = r.runs.filter((x) => x.repository === identity()).sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  $("wf-runs").replaceChildren(...rows.map((run) => {
    const view = el("button", { textContent: "Open" });
    view.addEventListener("click", () => { open = run; renderRun(); });
    const tr = el("tr", {}, ...[run.runId, run.workflow.key, run.state, `${run.done}/${run.total}`, fmtStamp(run.updatedAt)].map((c) => el("td", {}, c)), el("td", {}, view));
    tr.dataset.id = run.runId;
    return tr;
  }));
  $("wf-runs-empty").hidden = rows.length > 0;
  if (open) { open = r.runs.find((x) => x.runId === open!.runId) ?? null; renderRun(); }
}

function setOpen(run: Run | null) { if (run) { open = run; renderRun(); } void showRuns(); }

/** The card of a step as the workflow list names it; a retired workflow or card falls back to the stored ID. */
export function cardLabel(list: Flow[], key: string, step: string, ref: string): { code: string; summary: string } {
  const found = list.find((f) => f.key === key)?.steps.find((x) => x.step === step);
  return found && found.ref === ref ? { code: found.code, summary: found.summary } : { code: ref, summary: "" };
}

function stepRow(s: RunStep, current: boolean, key: string): HTMLTableRowElement {
  const card = cardLabel(flows, key, s.step, s.ref);
  const tr = el("tr", {}, ...[s.step, card.summary ? `${card.code} — ${card.summary}` : card.code, `${s.kind}${s.gate === "confirm" ? " · confirm" : ""}`, STATUS_LABEL[s.status] ?? s.status, s.evidence].map((c) => el("td", {}, c)));
  tr.dataset.step = s.step; tr.dataset.status = s.status;
  if (current) tr.classList.add("current");
  return tr;
}

function renderRun() {
  const run = open;
  $("wf-detail").hidden = !run;
  if (!run) return;
  $("wf-title").textContent = `${run.workflow.title} — ${run.runId}`;
  $("wf-run-state").textContent = `${run.state} · ${run.done} of ${run.total} steps done · revision ${run.workflow.revision}${run.objective ? " · " + run.objective : ""}`;
  $("wf-steps").replaceChildren(...run.steps.map((s) => stepRow(s, s.step === run.current, run.workflow.key)));
  const action = nextAction(run);
  const cur = run.steps.find((x) => x.step === run.current);
  $("wf-begin-box").hidden = action !== "begin";
  $("wf-gate-box").hidden = action !== "answer";
  $("wf-record-box").hidden = action !== "record";
  $("wf-resume").hidden = action !== "resume";
  $("wf-stop").hidden = !(run.state === "running" || run.state === "waiting-user");
  const choose = $("wf-choice-box");
  const choices = cur && cur.kind === "choice" && !cur.choice ? flows.find((f) => f.key === run.workflow.key)?.steps.find((x) => x.step === cur.step)?.choices ?? [] : [];
  choose.hidden = choices.length === 0;
  ($("wf-choice") as HTMLSelectElement).replaceChildren(...choices.map((c) => option(c.ref, `${c.code} — ${c.summary}`)));
  if (action === "begin" && cur) $("wf-begin-note").textContent = `Next: ${cur.step} (${cardLabel(flows, run.workflow.key, cur.step, cur.ref).code}).${cur.gate === "confirm" ? " It needs your confirmation first." : ""}`;
  if (action === "answer" && cur?.decision) $("wf-gate-question").textContent = cur.decision.question;
  if (action === "record" && cur) $("wf-record-note").textContent = `Run ${cardLabel(flows, run.workflow.key, cur.step, cur.ref).code} yourself, then record the outcome of ${cur.step}.`;
  $("wf-done").hidden = run.state !== "finished";
}

export async function showWorkflows() {
  $("wf-state").textContent = "Loading…";
  if (!identity()) { $("wf-state").textContent = "Select a repository to start or follow a run."; $("wf-runs").replaceChildren(); $("wf-runs-empty").hidden = true; }
  const list = await call<{ workflows: Flow[]; count: number }>("workflow_run", { operation: "list", identity: identity() || "github.com/none/none" }, "wf-error");
  flows = list?.workflows ?? [];
  renderFlows();
  $<HTMLButtonElement>("wf-start").disabled = !identity() || flows.length === 0;
  if (identity()) await showRuns();
  $("wf-state").textContent = identity() ? `${flows.length} workflows available.` : "Select a repository to start or follow a run.";
}

export function initWorkflows(repoIdentity: () => string = () => "") {
  identity = repoIdentity;
  $("wf-flow").addEventListener("change", renderSkips);
  $("wf-refresh").addEventListener("click", () => void showWorkflows());
  onBusyClick($("wf-start"), async () => {
    const skip = Array.from($("wf-skips").querySelectorAll<HTMLInputElement>("input:checked")).map((c) => c.value);
    const run = await op<Run>("start", { key: ($("wf-flow") as HTMLSelectElement).value, objective: input("wf-objective").value, skip });
    if (run) setOpen(run);
  }, "Starting…");
  onBusyClick($("wf-begin"), async () => {
    if (!open) return;
    const choice = !$("wf-choice-box").hidden ? ($("wf-choice") as HTMLSelectElement).value : "";
    setOpen(await op<Run>("step", { runId: open.runId, option: choice || null }));
  });
  for (const [id, answer] of [["wf-gate-yes", "yes"], ["wf-gate-no", "no"]] as const) {
    onBusyClick($(id), async () => {
      if (!open?.current) return;
      setOpen(await op<Run>("answer", { runId: open.runId, step: open.current, answer }));
    });
  }
  for (const [id, outcome] of [["wf-record-done", "done"], ["wf-record-failed", "failed"]] as const) {
    onBusyClick($(id), async () => {
      if (!open?.current) return;
      const run = await op<Run>("complete", { runId: open.runId, step: open.current, outcome, evidence: input("wf-evidence").value });
      if (run) input("wf-evidence").value = "";
      setOpen(run);
    });
  }
  onBusyClick($("wf-stop"), async () => { if (open) setOpen(await op<Run>("stop", { runId: open.runId })); });
  onBusyClick($("wf-resume"), async () => { if (open) setOpen(await op<Run>("resume", { runId: open.runId })); });
  $("wf-close").addEventListener("click", () => { open = null; renderRun(); setError("wf-error", null); });
}
