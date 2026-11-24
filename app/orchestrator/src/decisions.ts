// Decisions tab (#616): the user decision records of the selected repository (decisions.json of its dossier) listed with their options, and the
// app question UI for headless work. The person answers by clicking one listed option or by writing one answer of their own: the window never
// preselects an option, never turns a recommendation into an answer and has no timeout, so an unanswered decision stays open.
import { $, call, el, onBusyClick, setError } from "./common";

interface Option { id: string; label: string; description: string; recommended?: boolean }
export interface Decision {
  id: string; kind: string; question: string; options: Option[]; scope: string; status: string;
  context: { taskId?: string; evidence?: string[] };
  asked: { at: string; through: string; by: string };
  answer?: { optionId?: string; text?: string; by: string; at: string };
  withdrawn?: { at: string; reason: string };
}
interface DecisionList { repository: string; hash: string; decisions: Decision[] }
interface Answered { decision: Decision; applied: boolean; state: string }

let checkout: () => string = () => "";
let shown: "open" | "answered" | "withdrawn" = "open";
let latest = 0;

/** What the person reads for one answered decision. Pure. */
export function answerText(d: Decision): string {
  if (!d.answer) return "";
  if (d.answer.optionId) return d.options.find((o) => o.id === d.answer?.optionId)?.label ?? d.answer.optionId;
  return d.answer.text ?? "";
}

/** The values to send for one answer: exactly one of option or text, or null while the person has chosen nothing. Pure. */
export function answerPayload(chosen: string | null, text: string): { option: string } | { text: string } | null {
  const own = text.trim();
  if (chosen === "__other") return own ? { text: own } : null;
  return chosen ? { option: chosen } : null;
}

function card(d: Decision): HTMLElement {
  const name = `opt-${d.id}`;
  const box = el("article", { className: "home-card decision" });
  box.dataset.id = d.id;
  box.append(el("h3", {}, d.question), el("p", { className: "muted small" }, `${d.id} · ${d.kind} · ${d.scope}${d.context.taskId ? ` · task ${d.context.taskId}` : ""} · asked through ${d.asked.through}`));
  if (d.status !== "open") {
    box.append(el("p", {}, d.status === "answered" ? `Answered by you: ${answerText(d)}` : `Withdrawn: ${d.withdrawn?.reason ?? ""}`));
    return box;
  }
  const form = el("form", { className: "questions" });
  const fieldset = el("fieldset", {}, el("legend", {}, "Your answer"));
  // No option is checked: the recommended one is only marked, it is never an answer until the person selects it.
  for (const o of d.options) {
    const radio = el("input", { type: "radio", name, value: o.id });
    fieldset.append(el("label", { className: "choice" }, radio, el("strong", {}, ` ${o.label}${o.recommended ? " (recommended)" : ""}`), el("span", { className: "muted small" }, ` — ${o.description}`)));
  }
  const otherRadio = el("input", { type: "radio", name, value: "__other", ariaLabel: "Other answer" });
  const otherText = el("input", { type: "text", placeholder: "Other: write your own answer", ariaLabel: "Other: write your own answer", maxLength: 2000 });
  otherText.addEventListener("input", () => { if (otherText.value.trim()) otherRadio.checked = true; refresh(); });
  fieldset.append(el("label", { className: "choice" }, otherRadio, " ", otherText));
  form.append(fieldset);
  let lesson: HTMLInputElement | null = null;
  if (d.scope === "durable") {
    lesson = el("input", { type: "text", placeholder: "Decision: … — Reason: …", ariaLabel: "Lesson for memory", maxLength: 600 });
    form.append(el("label", {}, "Lesson saved in memory (format “Decision: … — Reason: …”)", lesson));
  }
  const send = el("button", { className: "primary", type: "submit", textContent: "Record my answer", disabled: true });
  const status = el("span", { className: "muted small" });
  form.append(el("div", { className: "row" }, send, status));
  const chosen = () => form.querySelector<HTMLInputElement>(`input[name="${name}"]:checked`)?.value ?? null;
  function refresh() {
    const p = answerPayload(chosen(), otherText.value);
    send.disabled = !p || (d.scope === "durable" && !lesson?.value.trim());
    status.textContent = p ? "" : "Choose an option or write your own answer.";
  }
  form.addEventListener("change", refresh);
  lesson?.addEventListener("input", refresh);
  refresh();
  onBusyClick(send, async () => {
    const p = answerPayload(chosen(), otherText.value);
    if (!p) return;
    const r = await call<Answered>("decisions", { operation: "answer", repo: checkout(), id: d.id, ...p, lesson: lesson?.value ?? "" }, "dec-error");
    if (r) await showDecisions();
  }, "Recording…");
  form.addEventListener("submit", (e) => e.preventDefault());
  box.append(form);
  return box;
}

export async function showDecisions() {
  const mine = ++latest;
  setError("dec-error", null);
  const list = $("dec-list");
  if (!checkout()) { $("dec-state").textContent = "Select a repository to see its decisions."; list.replaceChildren(); return; }
  $("dec-state").textContent = "Loading…";
  const r = await call<DecisionList>("decisions", { operation: "list", repo: checkout() }, "dec-error");
  if (mine !== latest) return;
  if (!r) { $("dec-state").textContent = ""; return; }
  const open = r.decisions.filter((d) => d.status === "open").length;
  const items = r.decisions.filter((d) => d.status === shown);
  list.replaceChildren(...items.map(card));
  $("dec-empty").hidden = items.length > 0;
  $("dec-empty").textContent = shown === "open" ? "No decision is waiting for you." : "Nothing here.";
  $("dec-state").textContent = `${open} open of ${r.decisions.length}. Nothing is answered for you: an open decision stays open.`;
}

export function initDecisions(repoPath: () => string = () => "") {
  checkout = repoPath;
  document.querySelectorAll<HTMLButtonElement>("#dec-kinds button").forEach((b) => b.addEventListener("click", () => {
    shown = b.dataset.status as typeof shown;
    document.querySelectorAll<HTMLButtonElement>("#dec-kinds button").forEach((x) => x.setAttribute("aria-pressed", String(x === b)));
    void showDecisions();
  }));
  onBusyClick($("dec-refresh"), () => showDecisions());
}
