// Prompts tab (#722): system prompts read-only, default prompts to view and duplicate, the user's own prompts (stored outside Git by
// user-prompts.ps1) to create with an RCTFE wizard, preview and delete. The scripts stay the final judge of every rule.
import { $, call, el, errorText, fmtStamp, input, onBusyClick, setError, type LightChoice } from "./common";
import type { Catalog, CatalogPrompt } from "./home";

interface UserPrompt {
  id: string; title: string; created: string; characters: number; text: string;
  fields: { title: string; role: string; context: string; task: string; format: string; directive: string };
}
interface UserPromptList { budget: number; prompts: UserPrompt[] }
interface Preview { valid: boolean; problems: string[]; characters: number; budget: number; text: string }
interface Card { code: string; summary: string; text: string }
type Fields = UserPrompt["fields"];

const BUDGET = 3500;
let viewing: { text: string; fields: Fields } | null = null;
let previewed: string | null = null;

const area = (id: string) => $<HTMLTextAreaElement>(id);
const dialog = (id: string) => $<HTMLDialogElement>(id);

/** The sections of a card body: role, context, task and format (the examples section is not used by user prompts). */
export function parseCard(text: string): Fields {
  const section = (name: string) => (new RegExp(`^<${name}>\\n([\\s\\S]*?)\\n</${name}>`, "m").exec(text.replace(/\r\n/g, "\n"))?.[1] ?? "").trim();
  const title = (/^# \S+ — (.*)$/m.exec(text)?.[1] ?? "").trim();
  return { title, role: section("role"), context: section("context"), task: section("task"), format: section("format"), directive: "" };
}

function readFields(): Fields {
  return { title: input("pr-title").value, role: area("pr-role").value, context: area("pr-context").value, task: area("pr-task").value, format: area("pr-format").value, directive: area("pr-directive").value };
}
function writeFields(f: Fields) {
  input("pr-title").value = f.title;
  area("pr-role").value = f.role; area("pr-context").value = f.context; area("pr-task").value = f.task; area("pr-format").value = f.format; area("pr-directive").value = f.directive;
}

/** The first problems visible without a script call, so Preview is never wasted on an empty form. */
export function localProblems(f: Fields): string[] {
  const p: string[] = [];
  if (!f.title.trim()) p.push("Write a title.");
  for (const [k, label] of [["role", "Role"], ["context", "Context"], ["task", "Task"], ["format", "Format"]] as const) if (!f[k].trim()) p.push(`${label} is empty.`);
  if (f.task.trim() && (f.task.match(/^\d+\. /gm) ?? []).length < 2) p.push('Task needs at least two numbered steps ("1. ...").');
  return p;
}

function openWizard(f: Fields) {
  writeFields(f);
  input("pr-goal").value = "";
  previewed = null;
  $("pr-preview").hidden = true; $("pr-problems").hidden = true; setError("pr-wizard-error", null);
  $("pr-budget").textContent = `Budget: ${BUDGET} characters for the composed prompt.`;
  (document.getElementById("pr-save") as HTMLButtonElement).disabled = true;
  dialog("pr-wizard-dialog").showModal();
}

function row(cells: (string | Node)[], testId: string): HTMLTableRowElement {
  const tr = el("tr", {}, ...cells.map((c) => el("td", {}, c)));
  tr.dataset.id = testId;
  return tr;
}

async function showCard(code: string) {
  const card = await call<Card>("read_prompt_card", { code }, "pr-error");
  if (!card) return;
  $("pr-view-title").textContent = `${card.code} — ${card.summary}`;
  $("pr-view-text").textContent = card.text;
  viewing = { text: card.text, fields: parseCard(card.text) };
  $("pr-view-duplicate").hidden = false;
  dialog("pr-view-dialog").showModal();
}

function catalogRows(list: CatalogPrompt[], body: HTMLElement) {
  body.replaceChildren(...list.map((p) => {
    const view = el("button", { textContent: "View" });
    view.addEventListener("click", () => void showCard(p.code));
    return row([p.code, p.summary, view], p.code);
  }));
}

export async function showPrompts() {
  $("pr-state").textContent = "Loading…";
  const [catalog, mine] = await Promise.all([call<Catalog>("read_catalog", {}, "pr-error"), call<UserPromptList>("user_prompts_list", {}, "pr-error")]);
  const all: CatalogPrompt[] = catalog ? catalog.categories.flatMap((c) => c.prompts) : [];
  const system = all.filter((p) => p.kind === "system"), defaults = all.filter((p) => p.kind === "user");
  catalogRows(system, $("pr-system"));
  catalogRows(defaults, $("pr-default"));
  $("pr-system-count").textContent = `(${system.length})`;
  $("pr-default-count").textContent = `(${defaults.length})`;
  const prompts = mine?.prompts ?? [];
  $("pr-mine").replaceChildren(...prompts.map((p) => {
    const view = el("button", { textContent: "View" });
    view.addEventListener("click", () => {
      $("pr-view-title").textContent = `${p.id} — ${p.title}`;
      $("pr-view-text").textContent = p.text;
      viewing = { text: p.text, fields: p.fields };
      $("pr-view-duplicate").hidden = false;
      dialog("pr-view-dialog").showModal();
    });
    const del = el("button", { textContent: "Delete" });
    del.setAttribute("aria-label", `Delete ${p.title}`);
    onBusyClick(del, async () => {
      if (!window.confirm(`Delete the prompt "${p.title}"? It cannot be undone.`)) return;
      if (await call("user_prompt_delete", { id: p.id }, "pr-error")) await showPrompts();
    });
    return row([p.id, p.title, `${p.characters} / ${BUDGET}`, fmtStamp(p.created), el("span", {}, view, " ", del)], p.id);
  }));
  $("pr-mine-empty").hidden = prompts.length > 0;
  $("pr-state").textContent = `${prompts.length} of your own, ${all.length} shipped.`;
}

/** The draft of the light model (#753): it fills the wizard and nothing else; the person previews and saves. */
interface Draft { provider: string; model: string | null; effort: string | null; fields: Omit<Fields, "directive"> }

export function initPrompts(light: () => LightChoice | null) {
  $("pr-refresh").addEventListener("click", () => void showPrompts());
  $("pr-new").addEventListener("click", () => openWizard({ title: "", role: "", context: "", task: "", format: "", directive: "" }));
  $("pr-view-close").addEventListener("click", () => dialog("pr-view-dialog").close());
  $("pr-view-duplicate").addEventListener("click", () => { dialog("pr-view-dialog").close(); if (viewing) openWizard({ ...viewing.fields, title: viewing.fields.title ? `${viewing.fields.title} (copy)` : "" }); });
  $("pr-wizard-close").addEventListener("click", () => dialog("pr-wizard-dialog").close());
  // Any edit invalidates the previewed text: Save always sends exactly what the last preview validated.
  for (const id of ["pr-title", "pr-role", "pr-context", "pr-task", "pr-format", "pr-directive"]) {
    $(id).addEventListener("input", () => { previewed = null; (document.getElementById("pr-save") as HTMLButtonElement).disabled = true; $("pr-preview").hidden = true; });
  }
  onBusyClick($("pr-draft-btn"), async () => {
    const goal = input("pr-goal").value.trim();
    if (!goal) { setError("pr-wizard-error", "Write the goal of the prompt in one line."); return; }
    const l = light();
    if (!l) { setError("pr-wizard-error", "No agent is ready for the draft: detect agents or choose the light model in the settings."); return; }
    const d = await call<Draft>("draft_user_prompt", { goal, provider: l.provider, model: l.model, effort: l.effort }, "pr-wizard-error");
    if (!d) return;
    writeFields({ ...d.fields, directive: area("pr-directive").value });
    previewed = null; $("pr-preview").hidden = true; $("pr-problems").hidden = true;
    (document.getElementById("pr-save") as HTMLButtonElement).disabled = true;
    $("pr-budget").textContent = `Draft by ${l.label}: review the fields, then Preview and Save.`;
  }, "Drafting…");
  onBusyClick($("pr-preview-btn"), async () => {
    const f = readFields();
    const local = localProblems(f);
    $("pr-problems").hidden = local.length === 0;
    $("pr-problems").textContent = local.join(" ");
    if (local.length) return;
    const r = await call<Preview>("user_prompt_preview", { fields: f }, "pr-wizard-error");
    if (!r) return;
    $("pr-preview").hidden = false;
    $("pr-preview").textContent = r.text;
    $("pr-budget").textContent = `${r.characters} of ${r.budget} characters.`;
    $("pr-problems").hidden = r.valid;
    $("pr-problems").textContent = r.problems.join(" ");
    previewed = r.valid ? JSON.stringify(f) : null;
    (document.getElementById("pr-save") as HTMLButtonElement).disabled = !r.valid;
  });
  onBusyClick($("pr-save"), async () => {
    const f = readFields();
    if (previewed !== JSON.stringify(f)) { setError("pr-wizard-error", "Preview the prompt again before saving."); return; }
    try {
      const saved = await call<UserPrompt>("user_prompt_create", { fields: f }, "pr-wizard-error");
      if (!saved) return;
      dialog("pr-wizard-dialog").close();
      await showPrompts();
    } catch (e) { setError("pr-wizard-error", errorText(e)); }
  });
}
