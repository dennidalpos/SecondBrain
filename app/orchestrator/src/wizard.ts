// Agent creation wizard (#623): seven steps, each validated before the next opens; the last one previews the definition exactly as
// subagents.ps1 -Operation Create would write it, and Save sends that same previewed definition (id included).
import { $, call, el, input, select, setError } from "./common";

export const STEPS = ["Purpose", "Target", "Provider and model", "Tools and permissions", "Prompts", "Budget and output", "Preview and save"];
export const READ_TOOLS = ["get_startup_context", "get_ready_tasks", "get_task", "search_knowledge", "list_prompts", "get_prompt_home", "get_prompt"];
export const WRITE_TOOLS = ["preview_dossier_write", "submit_dossier_write"];
export const SPECIAL_TOOLS = ["check_publication"];

export interface WizardState {
  template: string; name: string; description: string; status: string; provider: string; model: string;
  tools: string[]; write: boolean; role: string; context: string; cards: string; output: string; schema: string; turns: string; minutes: string;
}
interface Template { label: string; description: string; role: string; context: string; tools: string[]; write: boolean; output: string; turns: string }

export const TEMPLATES: Record<string, Template> = {
  blank: { label: "Blank", description: "", role: "", context: "", tools: [], write: false, output: "text", turns: "" },
  reviewer: { label: "Read-only reviewer", description: "Reviews one task read-only.", role: "You are a read-only reviewer.", context: "Start from the tracker task; cite sources.", tools: ["get_task", "search_knowledge"], write: false, output: "report", turns: "20" },
  researcher: { label: "Researcher", description: "Collects facts from the dossier for the parent.", role: "You are a researcher who answers only from the dossier.", context: "Load the startup context first; report what you could not verify.", tools: ["get_startup_context", "search_knowledge", "get_prompt_home"], write: false, output: "text", turns: "15" },
};

const NAME = /^[a-z0-9][a-z0-9-]{0,63}$/;
const CARD = /^(pmt-[0-9a-f]{8}|[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)*)$/;
const SCHEMA = /^config\/[A-Za-z0-9._/-]+\.json$/;
const MODEL = /^[A-Za-z0-9._:/@[\]-]{1,120}$/;

function cardList(s: WizardState): string[] { return s.cards.split(",").map((c) => c.trim()).filter(Boolean); }
function whole(v: string, min: number, max: number): boolean { return /^\d+$/.test(v) && Number(v) >= min && Number(v) <= max; }

/** The first problem of a step, or null when the step may be left. Mirrors the script's rules; the script stays the final judge. */
export function validateStep(step: number, s: WizardState): string | null {
  switch (step) {
    case 1:
      if (!NAME.test(s.name)) return "The name needs lowercase letters, digits and hyphens, starting with a letter or digit (up to 64 characters).";
      if (!s.description.trim() || s.description.length > 8192) return "Describe the purpose in one line (up to 8192 characters).";
      return null;
    case 2: return ["draft", "active"].includes(s.status) ? null : "Choose draft or active.";
    case 3:
      if (!["any", "claude", "codex", "gemini"].includes(s.provider)) return "Choose a provider.";
      if (s.model.trim() && s.provider === "any") return "A model needs a provider.";
      if (s.model.trim() && !MODEL.test(s.model.trim())) return "The model name has invalid characters.";
      return null;
    case 4:
      if (!s.tools.length) return "Allow at least one tool.";
      if (!s.write && s.tools.some((t) => WRITE_TOOLS.includes(t))) return "Write tools need the write permission.";
      return null;
    case 5: {
      if (!s.role.trim() || s.role.length > 8192) return "Write the role (up to 8192 characters).";
      if (!s.context.trim() || s.context.length > 8192) return "Write the initial context (up to 8192 characters).";
      const cards = cardList(s);
      if (cards.some((c) => !CARD.test(c))) return "Cards are pmt- IDs or roles such as analysis.task.";
      if (new Set(cards).size !== cards.length) return "A card is listed twice.";
      return null;
    }
    case 6:
      if (s.output === "object" && !SCHEMA.test(s.schema.trim())) return "An object output needs a schema such as config/result.json.";
      if (s.output !== "object" && s.schema.trim()) return "A schema is only for an object output.";
      if (!s.turns.trim() && !s.minutes.trim()) return "Set a budget: turns, minutes or both.";
      if (s.turns.trim() && !whole(s.turns.trim(), 1, 1000)) return "Turns are a whole number from 1 to 1000.";
      if (s.minutes.trim() && !whole(s.minutes.trim(), 1, 1440)) return "Minutes are a whole number from 1 to 1440.";
      return null;
    default: return null;
  }
}

/** The schema 2 definition for the state; id and revision are assigned by the script on the first preview. */
export function buildDefinition(s: WizardState): Record<string, unknown> {
  const budget: Record<string, number> = {};
  if (s.turns.trim()) budget.turns = Number(s.turns);
  if (s.minutes.trim()) budget.minutes = Number(s.minutes);
  const def: Record<string, unknown> = {
    schemaVersion: 2, name: s.name, status: s.status, description: s.description.trim(), role: s.role.trim(), context: s.context.trim(),
    permissions: { tools: s.tools, write: s.write },
    output: { kind: s.output, ...(s.output === "object" ? { schema: s.schema.trim() } : {}) },
    bounds: { depth: 1, budget },
  };
  const cards = cardList(s);
  if (cards.length) def.cards = cards;
  if (s.provider !== "any") def.model = { provider: s.provider, ...(s.model.trim() ? { name: s.model.trim() } : {}) };
  return def;
}

let step = 1;
let previewed: { key: string; definition: Record<string, unknown> } | null = null;
let identity = "";

function state(): WizardState {
  return {
    template: select("agw-template").value, name: input("agw-name").value.trim(), description: input("agw-description").value, status: select("agw-status").value,
    provider: select("agw-provider").value, model: input("agw-model").value,
    tools: [...document.querySelectorAll<HTMLInputElement>("#agw-tools input:checked")].map((c) => c.value), write: input("agw-write").checked,
    role: $<HTMLTextAreaElement>("agw-role").value, context: $<HTMLTextAreaElement>("agw-context").value, cards: input("agw-cards").value,
    output: select("agw-output").value, schema: input("agw-schema").value, turns: input("agw-turns").value, minutes: input("agw-minutes").value,
  };
}
const stateKey = () => JSON.stringify(buildDefinition(state()));

function render() {
  document.querySelectorAll<HTMLElement>(".agw-step").forEach((n) => { n.hidden = Number(n.dataset.step) !== step; });
  $("agw-steps").replaceChildren(...STEPS.map((t, i) => el("li", { textContent: t, ariaCurrent: i + 1 === step ? "step" : null, className: i + 1 === step ? "current" : i + 1 < step ? "done" : "" })));
  $<HTMLButtonElement>("agw-back").disabled = step === 1;
  $("agw-next").hidden = step === STEPS.length;
  $("agw-save").hidden = step !== STEPS.length;
  $<HTMLButtonElement>("agw-save").disabled = !previewed || previewed.key !== stateKey();
}

function applyTemplate(id: string) {
  const t = TEMPLATES[id] ?? TEMPLATES.blank;
  if (!input("agw-description").value.trim() || Object.values(TEMPLATES).some((x) => x.description === input("agw-description").value)) input("agw-description").value = t.description;
  $<HTMLTextAreaElement>("agw-role").value = t.role;
  $<HTMLTextAreaElement>("agw-context").value = t.context;
  document.querySelectorAll<HTMLInputElement>("#agw-tools input").forEach((c) => { c.checked = t.tools.includes(c.value); });
  input("agw-write").checked = t.write;
  select("agw-output").value = t.output;
  input("agw-turns").value = t.turns;
}

/** Shows the wizard for the selected project (null hides it) and starts from the first step. */
export function syncWizard(project: { identity: string; name: string } | null) {
  $("agw-box").hidden = !project;
  if (!project) return;
  if (identity !== project.identity) { identity = project.identity; resetWizard(); }
  $("agw-target").textContent = project.name;
}

function resetWizard() {
  step = 1;
  previewed = null;
  input("agw-name").value = "";
  select("agw-template").value = "blank";
  applyTemplate("blank");
  select("agw-status").value = "draft";
  select("agw-provider").value = "any";
  input("agw-model").value = "";
  input("agw-cards").value = "";
  input("agw-schema").value = "";
  input("agw-minutes").value = "";
  $("agw-plan").hidden = true;
  setError("agw-error", null);
  render();
}

export function initWizard(onSaved: () => void) {
  select("agw-template").replaceChildren(...Object.entries(TEMPLATES).map(([k, t]) => el("option", { value: k, textContent: t.label })));
  $("agw-tools").replaceChildren(...[...READ_TOOLS, ...SPECIAL_TOOLS, ...WRITE_TOOLS].map((t) => el("label", { className: "inline" }, el("input", { type: "checkbox", value: t }), " " + t)));
  applyTemplate("blank");
  select("agw-template").addEventListener("change", () => { applyTemplate(select("agw-template").value); previewed = null; render(); });
  $("agw-box").addEventListener("input", () => { previewed = null; render(); });
  $("agw-box").addEventListener("change", () => { previewed = null; render(); });
  $("agw-back").addEventListener("click", () => { if (step > 1) { step--; setError("agw-error", null); render(); } });
  $("agw-next").addEventListener("click", () => {
    const problem = validateStep(step, state());
    if (problem) { setError("agw-error", problem); return; }
    setError("agw-error", null);
    step++;
    render();
  });
  $("agw-preview").addEventListener("click", async () => {
    for (let i = 1; i < STEPS.length; i++) {
      const problem = validateStep(i, state());
      if (problem) { setError("agw-error", `Step ${i} (${STEPS[i - 1]}): ${problem}`); return; }
    }
    const definition = buildDefinition(state());
    const r = await call<{ definition: Record<string, unknown> }>("agent_wizard", { identity, definition, apply: false }, "agw-error");
    if (!r) return;
    previewed = { key: stateKey(), definition: r.definition };
    $("agw-plan").textContent = "Preview, nothing written yet. This is the file that is saved:\n" + JSON.stringify(r.definition, null, 2);
    $("agw-plan").hidden = false;
    render();
  });
  $("agw-save").addEventListener("click", async () => {
    if (!previewed || previewed.key !== stateKey()) return;
    // The previewed definition itself is saved, so the file equals what the person reviewed.
    const r = await call<{ state: string; definition: Record<string, unknown> }>("agent_wizard", { identity, definition: previewed.definition, apply: true }, "agw-error");
    if (!r) return;
    const same = JSON.stringify(r.definition) === JSON.stringify(previewed.definition);
    $("agw-plan").textContent = (same ? "Saved exactly as previewed" : "Saved, but the file differs from the preview: check it") + ` (${String(previewed.definition.name)}, ${String(previewed.definition.id)}).\n` + JSON.stringify(r.definition, null, 2);
    previewed = null;
    $<HTMLButtonElement>("agw-save").disabled = true;
    onSaved();
  });
  render();
}
