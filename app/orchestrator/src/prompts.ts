// Prompts tab (#722): system prompts read-only, default prompts to view and duplicate, the user's own prompts (stored outside Git by
// user-prompts.ps1) to create with an RCTFE wizard, preview and delete. The scripts stay the final judge of every rule.
import { $, call, el, errorText, fmtStamp, input, onBusyClick, option, setError, type LightChoice } from "./common";
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
let composeCard: CatalogPrompt | null = null;
let library: Catalog["categories"] = [];
let repoPath: () => string = () => "";

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

/** Library filter: free text over code, summary and area title, optionally limited to one area. */
export function filterLibrary(cats: Catalog["categories"], query: string, areaId: string): CatalogPrompt[] {
  const q = query.trim().toLowerCase();
  return cats.filter((c) => !areaId || c.id === areaId)
    .flatMap((c) => c.prompts.filter((p) => !q || [p.code, p.summary, c.title].some((s) => s.toLowerCase().includes(q))));
}

/** Only a read card is composed for an agent here: write and other modes stay with the commands that guard them. */
export function canCompose(p: CatalogPrompt | null): boolean { return !!p && p.mode === "read"; }

function renderLibrary() {
  const query = input("pr-search").value, areaId = ($("pr-area") as HTMLSelectElement).value;
  const hits = filterLibrary(library, query, areaId);
  const system = hits.filter((p) => p.kind === "system"), defaults = hits.filter((p) => p.kind === "user");
  catalogRows(system, $("pr-system"));
  catalogRows(defaults, $("pr-default"));
  $("pr-system-count").textContent = `(${system.length})`;
  $("pr-default-count").textContent = `(${defaults.length})`;
  if (query.trim() || areaId) {
    (document.getElementById("pr-system-box") as HTMLDetailsElement).open = system.length > 0;
    (document.getElementById("pr-default-box") as HTMLDetailsElement).open = defaults.length > 0;
  }
}

function resetCompose() {
  const ok = canCompose(composeCard);
  $("pr-compose-box").hidden = !ok; $("pr-compose-btn").hidden = !ok; $("pr-copy").hidden = true;
  $("pr-composed").hidden = true; setError("pr-compose-error", null);
  input("pr-objective").value = "";
  $("pr-compose-note").textContent = ok ? "Compose resolves the card for the selected repository, exactly as prompts.ps1 -Compose does." : "";
}

async function showCard(code: string) {
  const card = await call<Card>("read_prompt_card", { code }, "pr-error");
  if (!card) return;
  $("pr-view-title").textContent = `${card.code} — ${card.summary}`;
  $("pr-view-text").textContent = card.text;
  viewing = { text: card.text, fields: parseCard(card.text) };
  composeCard = library.flatMap((c) => c.prompts).find((p) => p.code === code) ?? null;
  resetCompose();
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
  library = catalog ? catalog.categories : [];
  const all: CatalogPrompt[] = library.flatMap((c) => c.prompts);
  const areaSel = $("pr-area") as HTMLSelectElement, keep = areaSel.value;
  areaSel.replaceChildren(option("", "All areas"), ...library.map((c) => option(c.id, c.title)));
  areaSel.value = library.some((c) => c.id === keep) ? keep : "";
  renderLibrary();
  const prompts = mine?.prompts ?? [];
  $("pr-mine").replaceChildren(...prompts.map((p) => {
    const view = el("button", { textContent: "View" });
    view.addEventListener("click", () => {
      $("pr-view-title").textContent = `${p.id} — ${p.title}`;
      $("pr-view-text").textContent = p.text;
      viewing = { text: p.text, fields: p.fields };
      composeCard = null; resetCompose();
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

export function initPrompts(light: () => LightChoice | null, repo: () => string = () => "") {
  repoPath = repo;
  $("pr-search").addEventListener("input", renderLibrary);
  $("pr-area").addEventListener("change", renderLibrary);
  onBusyClick($("pr-compose-btn"), async () => {
    if (!canCompose(composeCard)) return;
    const text = await call<string>("compose_prompt", { code: composeCard!.code, objective: input("pr-objective").value, repo: repoPath() || null }, "pr-compose-error");
    if (text === null) return;
    $("pr-composed").hidden = false; $("pr-composed").textContent = text; $("pr-copy").hidden = false;
  }, "Composing…");
  $("pr-copy").addEventListener("click", () => {
    void navigator.clipboard.writeText($("pr-composed").textContent ?? "").then(() => { $("pr-compose-note").textContent = "Copied."; }, (e) => setError("pr-compose-error", e));
  });
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
