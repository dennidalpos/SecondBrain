// Library management tab (#634): the three kinds of assets (prompts, workflows, agent definitions) as searchable views with a preview and the
// references of each item. A retirement is only planned here: every reference is shown, a retirement that would break one is refused, and the
// lifecycle command that applies it is named (library.ps1 reads and writes nothing).
import { $, call, el, input, onBusyClick, setError } from "./common";

export type Kind = "prompt" | "workflow" | "agent";
export interface Item { kind: Kind; id: string; key: string; title: string; status: string; revision: number | null; area: string; mode: string | null; pack: string | null; usedBy: string[] }
interface ItemList { kind: Kind; items: Item[]; count: number }
interface Shown { item: Item; preview: string; references: string[] }
export interface RetirePlan {
  item: Item; references: string[]; available: boolean; refused: boolean; errors: string[]; notes: string[];
  plan: { valid: boolean; changeCount: number; changes: string[] } | null; command: string | null;
}

const KIND_LABEL: Record<Kind, string> = { prompt: "prompts", workflow: "workflows", agent: "agent definitions" };
let kind: Kind = "prompt";
let identity: () => string = () => "";

/** What the person reads for a planned retirement: the verdict first, then every reason and the command that would apply it. Pure. */
export function retireSummary(r: RetirePlan): { verdict: "refused" | "allowed" | "unavailable"; lines: string[] } {
  if (!r.available) return { verdict: "unavailable", lines: [...r.errors, ...r.references.map((x) => `Used by ${x}`)] };
  if (r.refused) return { verdict: "refused", lines: [...r.errors, ...r.references.map((x) => `Used by ${x}`)] };
  return { verdict: "allowed", lines: [...r.notes, ...(r.plan?.changes ?? []), ...(r.command ? [`To apply, run: ${r.command}`] : [])] };
}

async function lib<T>(operation: string, extra: Record<string, unknown> = {}): Promise<T | null> {
  return call<T>("library", { operation, identity: identity(), kind, ...extra }, "lib-error");
}

function selectKind(next: Kind) {
  kind = next;
  document.querySelectorAll<HTMLButtonElement>("#lib-kinds button").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.kind === next)));
  $("lib-detail").hidden = true;
  void showLibrary();
}

function row(item: Item): HTMLTableRowElement {
  const view = el("button", { textContent: "View" });
  view.addEventListener("click", () => void showItem(item));
  const retire = el("button", { textContent: "Retire…" });
  retire.setAttribute("aria-label", `Plan the retirement of ${item.key}`);
  retire.addEventListener("click", () => void planRetire(item));
  const cells: (string | Node)[] = [item.key, item.title, `${item.status}${item.revision ? ` · r${item.revision}` : ""}`, String(item.usedBy.length), el("span", {}, view, " ", retire)];
  const tr = el("tr", {}, ...cells.map((c) => el("td", {}, c)));
  tr.dataset.id = item.key;
  return tr;
}

async function showItem(item: Item) {
  const s = await lib<Shown>("show", { id: item.id });
  if (!s) return;
  $("lib-detail").hidden = false;
  $("lib-detail-title").textContent = `${s.item.key} — ${s.item.title}`;
  $("lib-preview").hidden = false; $("lib-preview").textContent = s.preview;
  $("lib-refs").textContent = s.references.length ? `Used by: ${s.references.join("; ")}` : "Not used by any other asset.";
  $("lib-retire-box").hidden = true;
}

async function planRetire(item: Item) {
  const r = await lib<RetirePlan>("retire", { id: item.id });
  if (!r) return;
  const sum = retireSummary(r);
  $("lib-detail").hidden = false;
  $("lib-detail-title").textContent = `Retire ${r.item.key} — ${r.item.title}`;
  $("lib-preview").hidden = true;
  $("lib-refs").textContent = r.references.length ? `Used by: ${r.references.join("; ")}` : "Not used by any other asset.";
  const box = $("lib-retire-box");
  box.hidden = false; box.dataset.verdict = sum.verdict;
  $("lib-verdict").textContent = sum.verdict === "allowed" ? "Retirement allowed: nothing active references it." : sum.verdict === "refused" ? "Retirement refused: it would break an active asset." : "Retirement is not available for this kind yet.";
  $("lib-retire-lines").replaceChildren(...sum.lines.map((l) => el("li", {}, l)));
}

/** Responses can arrive out of order (each list is a script run): only the answer to the latest request is shown. */
let latest = 0;

export async function showLibrary() {
  const mine = ++latest;
  $("lib-state").textContent = "Loading…";
  if (!identity()) { $("lib-state").textContent = "Select a repository to manage its library."; $("lib-rows").replaceChildren(); $("lib-empty").hidden = true; return; }
  const r = await lib<ItemList>("list", { query: input("lib-search").value });
  if (mine !== latest) return;
  if (!r) { $("lib-state").textContent = ""; return; }
  $("lib-rows").replaceChildren(...r.items.map(row));
  $("lib-empty").hidden = r.items.length > 0;
  $("lib-empty").textContent = kind === "agent" ? "No agent definition in this repository's dossier yet." : "Nothing matches.";
  $("lib-state").textContent = `${r.count} ${KIND_LABEL[kind]}.`;
}

export function initLibrary(repoIdentity: () => string = () => "") {
  identity = repoIdentity;
  document.querySelectorAll<HTMLButtonElement>("#lib-kinds button").forEach((b) => b.addEventListener("click", () => selectKind(b.dataset.kind as Kind)));
  input("lib-search").addEventListener("input", () => { clearTimeout(timer); timer = window.setTimeout(() => void showLibrary(), 250); });
  onBusyClick($("lib-refresh"), () => showLibrary());
  $("lib-close").addEventListener("click", () => { $("lib-detail").hidden = true; setError("lib-error", null); });
}
let timer = 0;
