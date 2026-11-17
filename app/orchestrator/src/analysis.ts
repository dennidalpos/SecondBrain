// Analysis that makes a task autonomous (REP18 through agents.ps1 -Analyze): the light model answers with tool calls that this
// dialog dispatches. ask_user becomes a multiple-choice question (recommended option first, free text under "Other"); the answers go
// back for the next round; propose_task_update is shown as a before/after diff and written to the tracker only after confirmation;
// mark_not_automatable records the reason. The analysis state lives in its work folder, so a closed window loses nothing.
import { $, call, el, setError, type LightChoice } from "./common";

interface Option { id: string; label: string; description: string }
interface CallArgs {
  questionId: string | null; header: string | null; question: string | null; options: Option[] | null; multiSelect: boolean | null; recommended: string | null;
  description: string | null; acceptance: string[] | null; execution: string | null; awaiting: string | null; requires: string[] | null; dependencies: string[] | null;
  stateReason: string | null; reason: string | null;
}
interface ToolCall { name: "ask_user" | "propose_task_update" | "mark_not_automatable"; arguments: CallArgs }
interface AnalysisResult { taskId: string; verdict: "autonomous-now" | "needs-answers" | "not-automatable"; summary: string; calls: ToolCall[]; blockersRemaining: { kind: string; detail: string }[] }
interface TaskSnapshot { id: string; seq: number; title: string; status: string; execution: string; description: string | null; acceptance: string[]; extensions: Record<string, unknown> | null }
export interface AnalysisView {
  analysisPath: string; taskId: string; seq: number; provider: string; model: string | null; effort: string | null; round: number; maxRounds: number;
  reason: string | null; dependencies: { id: string; status: string }[]; task: TaskSnapshot; result: AnalysisResult;
  answered: { questionId: string; question: string; answer: string }[]; applied?: { at: string; state: unknown; verdict: string } | null;
}
interface Hooks { repo: () => string; identity: () => string; light: () => LightChoice | null; onChange: () => void }

export const VERDICT_LABEL: Record<string, string> = { "autonomous-now": "ready for autonomy", "needs-answers": "answers needed", "not-automatable": "not automatable" };
const BLOCKER_LABEL: Record<string, string> = { "owner-consent": "consent of the person", credential: "credential", hardware: "hardware", "live-access": "live access", "computer-use": "computer use", "other-repository": "other repository" };
let hooks: Hooks;
let current: AnalysisView | null = null;
let busy = false;
const verdicts = new Map<string, string>();

function storeKey() { return "sb-analyses:" + hooks.identity(); }
function stored(): Record<string, string> { try { return JSON.parse(localStorage.getItem(storeKey()) ?? "{}"); } catch { return {}; } }
function remember(taskId: string, path: string | null) {
  const map = stored();
  if (path) map[taskId] = path; else delete map[taskId];
  localStorage.setItem(storeKey(), JSON.stringify(map));
}
export function storedAnalysis(taskId: string): string | null { return stored()[taskId] ?? null; }
export function verdictOf(taskId: string): string | null { return verdicts.get(taskId) ?? null; }

export function initAnalysis(h: Hooks) {
  hooks = h;
  $("an-close").addEventListener("click", () => $<HTMLDialogElement>("an-dialog").close());
}

function lightArgs(): Record<string, unknown> | null {
  const l = hooks.light();
  if (!l) return null;
  return { provider: l.provider, model: l.model || null, effort: l.effort || null };
}

/** First round on one task; the dialog opens on its result unless quiet. */
export async function analyzeTask(taskId: string, quiet = false, errorId = "q-error"): Promise<AnalysisView | null> {
  const args = lightArgs();
  if (!args) { setError(errorId, "No agent is ready for the analysis: detect agents or choose the light model in the settings."); return null; }
  const view = await call<AnalysisView>("analyze_task", { repo: hooks.repo(), taskId, ...args }, errorId);
  if (!view) return null;
  remember(taskId, view.analysisPath);
  verdicts.set(taskId, view.result.verdict);
  if (!quiet) show(view);
  hooks.onChange();
  return view;
}

/** Reopens a stored analysis (no agent call). */
export async function openAnalysis(taskId: string, errorId = "q-error") {
  const path = storedAnalysis(taskId);
  if (!path) return analyzeTask(taskId, false, errorId);
  const view = await call<AnalysisView>("view_task_analysis", { repo: hooks.repo(), analysisPath: path }, errorId);
  if (!view) { remember(taskId, null); return null; }
  verdicts.set(taskId, view.result.verdict);
  show(view);
  return view;
}

function show(view: AnalysisView) {
  current = view;
  render();
  const d = $<HTMLDialogElement>("an-dialog");
  if (!d.open) d.showModal();
}

function setBusy(on: boolean, text = "") {
  busy = on;
  $("an-state").textContent = text;
  const primary = $<HTMLButtonElement>("an-primary");
  primary.disabled = on;
  primary.classList.toggle("busy", on);
  if (on) primary.setAttribute("aria-busy", "true"); else primary.removeAttribute("aria-busy");
}

function render() {
  const v = current!;
  const r = v.result;
  setError("an-error", null);
  $("an-title").textContent = `#${v.task.seq} ${String(v.task.title).replace(/^#\d+\s*[-–—:]?\s*/, "")}`;
  $("an-meta").textContent = `Analysis with ${v.provider}${v.model ? " · " + v.model : ""}${v.effort ? " · " + v.effort : ""} · round ${v.round} of ${v.maxRounds} · ${VERDICT_LABEL[r.verdict] ?? r.verdict}`;
  $("an-reason").textContent = v.reason ? "Reason for exclusion: " + v.reason : "";
  $("an-summary").textContent = r.summary;
  const body = $("an-body");
  body.replaceChildren();
  if (v.answered.length) {
    body.append(el("details", {}, el("summary", {}, `Answers already given (${v.answered.length})`),
      el("ul", { className: "small" }, ...v.answered.map((a) => el("li", {}, el("strong", {}, a.question), " — ", a.answer)))));
  }
  if (r.blockersRemaining.length) {
    body.append(el("div", { className: "warning" }, "Real prerequisites: ", ...r.blockersRemaining.map((b, i) => `${i ? "; " : ""}${BLOCKER_LABEL[b.kind] ?? b.kind}: ${b.detail}`)));
  }
  const primary = $<HTMLButtonElement>("an-primary");
  primary.hidden = false;
  primary.onclick = null;
  $<HTMLButtonElement>("an-secondary").hidden = true;
  if (v.applied) {
    body.append(el("p", { className: "ok-note" }, `Result already applied on ${new Date(v.applied.at).toLocaleString()} (${v.applied.state === "deferred" ? "in the write queue" : "written to the tracker"}).`));
    primary.hidden = true;
    return;
  }
  if (r.verdict === "needs-answers") renderQuestions(body, primary);
  else if (r.verdict === "autonomous-now") renderUpdate(body, primary);
  else renderNotAutomatable(body, primary);
}

function renderQuestions(body: HTMLElement, primary: HTMLButtonElement) {
  const v = current!;
  const asks = v.result.calls.filter((c) => c.name === "ask_user" && c.arguments.question);
  const form = el("form", { className: "questions" });
  asks.forEach((c, qi) => {
    const a = c.arguments;
    const name = "q" + qi;
    const type = a.multiSelect ? "checkbox" : "radio";
    const options = [...(a.options ?? [])].sort((x, y) => Number(y.id === a.recommended) - Number(x.id === a.recommended));
    const set = el("fieldset", {}, el("legend", {}, a.header ? `${a.header}: ` : "", a.question ?? ""));
    for (const o of options) {
      const box = el("input", { type, name, value: o.label });
      set.append(el("label", { className: "choice" }, box, el("span", {}, el("strong", {}, o.label + (o.id === a.recommended ? " (recommended)" : "")), el("span", { className: "muted small" }, " — " + o.description))));
    }
    const otherBox = el("input", { type, name, value: "__other", ariaLabel: "Other answer" });
    const otherText = el("input", { type: "text", placeholder: "Other: write your own answer", className: "other" });
    otherText.addEventListener("input", () => { if (otherText.value.trim()) otherBox.checked = true; update(); });
    set.append(el("label", { className: "choice" }, otherBox, otherText));
    set.dataset.questionId = a.questionId ?? name;
    set.dataset.question = a.question ?? "";
    form.append(set);
  });
  const update = () => {
    const sets = [...form.querySelectorAll<HTMLFieldSetElement>("fieldset")];
    primary.disabled = busy || !sets.length || sets.some((s) => !s.querySelector("input:checked"));
  };
  form.addEventListener("change", update);
  body.append(form);
  if (v.round >= v.maxRounds) {
    body.append(el("p", { className: "warning" }, "Last round reached: another round is not possible with these answers. Restart the analysis from the queue if needed."));
    primary.hidden = true;
    return;
  }
  primary.textContent = "Send answers";
  update();
  primary.onclick = async () => {
    const answers = [...form.querySelectorAll<HTMLFieldSetElement>("fieldset")].map((s) => {
      const chosen = [...s.querySelectorAll<HTMLInputElement>("input:checked")].map((i) => (i.value === "__other" ? (s.querySelector<HTMLInputElement>("input.other")?.value.trim() || "Other") : i.value));
      return { questionId: s.dataset.questionId, question: s.dataset.question, answer: chosen.join("; ") };
    });
    setBusy(true, "New analysis round with your answers…");
    const next = await call<AnalysisView>("resolve_task_analysis", { repo: hooks.repo(), analysisPath: v.analysisPath, answers }, "an-error");
    setBusy(false);
    if (!next) return;
    verdicts.set(next.taskId, next.result.verdict);
    current = next;
    render();
    hooks.onChange();
  };
}

function listText(items: string[] | null | undefined): string { return items && items.length ? items.join("\n") : "—"; }

function renderUpdate(body: HTMLElement, primary: HTMLButtonElement) {
  const v = current!;
  const u = v.result.calls.find((c) => c.name === "propose_task_update")?.arguments;
  if (!u) { body.append(el("p", { className: "warning" }, "The model did not propose the update: restart the analysis.")); primary.hidden = true; return; }
  const ext = (v.task.extensions ?? {}) as Record<string, unknown>;
  const awaiting = String(ext.awaiting ?? "");
  const deps = (v.dependencies ?? []).map((d) => d.id);
  const rows: [string, string, string][] = [
    ["Description", v.task.description ?? "—", u.description ?? "(unchanged)"],
    ["Acceptance criteria", listText(v.task.acceptance), u.acceptance?.length ? listText(u.acceptance) : "(unchanged)"],
    ["Execution",v.task.execution, u.execution ?? "autonomous"],
    ["Status", v.task.status, ["blocked", "unknown"].includes(v.task.status) ? "todo" : v.task.status],
    ["Awaiting",awaiting || "—", u.awaiting || "—"],
    ["Requirements",listText(ext.requires as string[] | undefined), listText(u.requires)],
    ["Dependencies", listText(deps), u.dependencies ? listText(u.dependencies) : "(unchanged)"],
    ["State reason", String(ext.stateReason ?? "—"), u.stateReason ?? "(unchanged)"],
  ];
  const table = el("table", { className: "tasks diff" }, el("thead", {}, el("tr", {}, el("th", {}, "Field"), el("th", {}, "Current"), el("th", {}, "Proposed"))));
  const tbody = el("tbody");
  for (const [f, a, b] of rows) tbody.append(el("tr", { className: a === b ? "" : "changed" }, el("td", {}, f), el("td", { className: "pre" }, a), el("td", { className: "pre" }, b)));
  table.append(tbody);
  body.append(table);
  if (awaiting && awaiting !== "structural-completion" && (u.awaiting ?? "") !== awaiting) {
    body.append(el("p", { className: "warning" }, `The wait «${awaiting}» is removed: this applies only if your answers grant it explicitly.`));
  }
  primary.textContent = "Apply to the tracker";
  primary.disabled = busy;
  primary.onclick = () => apply("Update the task in the tracker with the proposal shown? The write goes through knowledge.ps1 and stays in the run ledger.");
}

function renderNotAutomatable(body: HTMLElement, primary: HTMLButtonElement) {
  const v = current!;
  const why = v.result.calls.find((c) => c.name === "mark_not_automatable")?.arguments.reason ?? v.result.summary;
  body.append(el("p", {}, el("strong", {}, "Reason: "), why));
  primary.textContent = "Record the reason on the task";
  primary.disabled = busy;
  primary.onclick = () => apply("Record the reason on the task (execution user_required)?");
}

async function apply(question: string) {
  const v = current!;
  if (!confirm(question)) return;
  setBusy(true, "Writing to the tracker…");
  const r = await call<{ applied: boolean | string }>("apply_task_analysis", { repo: hooks.repo(), analysisPath: v.analysisPath, authorization: "Confirmed in the desktop orchestrator " + new Date().toISOString() }, "an-error");
  setBusy(false);
  if (!r) return;
  current = { ...v, applied: { at: new Date().toISOString(), state: r.applied, verdict: v.result.verdict } };
  render();
  $("an-state").textContent = r.applied === "deferred" ? "Write accepted: it is applied as soon as the tracker is free." : "Task updated.";
  hooks.onChange();
}

/** Analyzes the given tasks one after the other (quietly), reporting progress; the dialog opens on demand. */
export async function analyzeMany(ids: string[], progress: (done: number, total: number, id: string) => void) {
  for (let i = 0; i < ids.length; i++) {
    progress(i, ids.length, ids[i]);
    await analyzeTask(ids[i], true);
  }
  progress(ids.length, ids.length, "");
}

// Enrichment proposal of the light model (#608, #645): the task keeps only a pointer; this dialog shows the proposal and the person applies
// or rejects it. Apply writes only the proposal's own fields; reject changes only the pointer status; a proposal whose file changed is refused.
interface EnrichPointer { path: string; sha256: string; status: "proposed" | "applied" | "rejected"; at?: string }
interface EnrichRecord {
  summary: string; gaps: string[]; discarded: string[]; questions: unknown[]; provider: string; model: string | null; effort: string | null;
  proposal: { description?: string; acceptance?: string[]; stream?: string; requires?: string[] };
}
interface EnrichView { taskId: string; seq: number; title: string; pointer: EnrichPointer | null; hashMatches: boolean; proposal: EnrichRecord | null }

/** Shows the stored proposal of a task, or asks the light model for one when the task has none (or only a rejected one). */
export async function openEnrichment(taskId: string, errorId = "q-error"): Promise<void> {
  let view = await call<EnrichView>("view_task_enrichment", { repo: hooks.repo(), taskId }, errorId);
  if (!view) return;
  if (!view.pointer || view.pointer.status === "rejected") {
    const args = lightArgs();
    if (!args) { setError(errorId, "No agent is ready for the analysis: detect agents or choose the light model in the settings."); return; }
    const run = await call<{ called: boolean }>("enrich_task", { repo: hooks.repo(), taskId, ...args }, errorId);
    if (!run) return;
    if (!run.called) { setError(errorId, `Task ${taskId} is already complete: there is nothing to enrich.`); return; }
    view = await call<EnrichView>("view_task_enrichment", { repo: hooks.repo(), taskId }, errorId);
    if (!view) return;
    hooks.onChange();
  }
  showEnrichment(view);
}

function showEnrichment(view: EnrichView) {
  const p = view.pointer;
  const rec = view.proposal;
  setError("an-error", null);
  $("an-title").textContent = `#${view.seq} ${view.title}`;
  $("an-meta").textContent = rec ? `Enrichment proposal from ${rec.provider}${rec.model ? " · " + rec.model : ""}${rec.effort ? " · " + rec.effort : ""} · ${p?.status ?? "none"}` : "No enrichment proposal";
  $("an-reason").textContent = rec ? `Missing detail: ${rec.gaps.join(", ") || "none"}` : "";
  $("an-summary").textContent = rec?.summary ?? "";
  const body = $("an-body");
  body.replaceChildren();
  const primary = $<HTMLButtonElement>("an-primary");
  const secondary = $<HTMLButtonElement>("an-secondary");
  primary.onclick = null;
  secondary.onclick = null;
  secondary.hidden = true;
  if (!p || !rec) { primary.hidden = true; return; }
  const fields: [string, string][] = [];
  if (rec.proposal.description) fields.push(["Description", rec.proposal.description]);
  if (rec.proposal.acceptance?.length) fields.push(["Acceptance criteria", rec.proposal.acceptance.join("\n")]);
  if (rec.proposal.stream) fields.push(["Stream", rec.proposal.stream]);
  if (rec.proposal.requires?.length) fields.push(["Requirements", rec.proposal.requires.join("\n")]);
  const table = el("table", { className: "tasks diff" }, el("thead", {}, el("tr", {}, el("th", {}, "Field"), el("th", {}, "Proposed"))));
  const tbody = el("tbody");
  for (const [f, v] of fields) tbody.append(el("tr", { className: "changed" }, el("td", {}, f), el("td", { className: "pre" }, v)));
  table.append(tbody);
  body.append(fields.length ? table : el("p", { className: "muted" }, "The model proposed no field; see its questions."));
  if (rec.discarded.length) body.append(el("p", { className: "small muted" }, `Discarded outside the gaps: ${rec.discarded.join(", ")}`));
  if (rec.questions.length) {
    body.append(el("details", {}, el("summary", {}, `Questions from the model (${rec.questions.length})`),
      el("ul", { className: "small" }, ...rec.questions.map((q) => el("li", {}, typeof q === "string" ? q : String((q as { question?: string }).question ?? JSON.stringify(q)))))));
  }
  const reject = (label: string) => { secondary.hidden = false; secondary.textContent = label; secondary.onclick = () => decideEnrichment(view, false); };
  if (p.status !== "proposed") {
    body.append(el("p", { className: "ok-note" }, `This proposal is already ${p.status}${p.at ? " on " + new Date(p.at).toLocaleString() : ""}.`));
    primary.hidden = true;
  } else if (!view.hashMatches) {
    body.append(el("div", { className: "warning" }, "The proposal file changed after it was recorded: it cannot be applied. Reject it and ask for a new one."));
    primary.hidden = true;
    reject("Reject");
  } else {
    primary.hidden = false;
    primary.disabled = false;
    primary.textContent = "Apply to the task";
    primary.onclick = () => decideEnrichment(view, true);
    reject("Reject");
  }
  const d = $<HTMLDialogElement>("an-dialog");
  if (!d.open) d.showModal();
}

async function decideEnrichment(view: EnrichView, apply: boolean) {
  if (!confirm(apply ? "Apply the proposed fields to the task? Only the fields shown are written." : "Reject this proposal? The task is not changed.")) return;
  setBusy(true, apply ? "Applying the proposal…" : "Rejecting the proposal…");
  const r = await call<{ applied: boolean | string }>("decide_task_enrichment", {
    repo: hooks.repo(), taskId: view.taskId, apply, authorization: "Confirmed in the desktop orchestrator " + new Date().toISOString(),
  }, "an-error");
  setBusy(false);
  if (!r) return;
  const next = await call<EnrichView>("view_task_enrichment", { repo: hooks.repo(), taskId: view.taskId }, "an-error");
  if (next) showEnrichment(next);
  $("an-state").textContent = r.applied === "deferred" ? "Accepted: it is applied as soon as the tracker is free." : apply ? "Proposal applied." : "Proposal rejected.";
  hooks.onChange();
}
