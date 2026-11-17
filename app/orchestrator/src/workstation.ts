// Workstation view (#577): setup status, IDEs and MCP, optional features, directive revisions and upkeep. Every action first shows the exact
// command; Preview runs the script without -Apply, and Apply stays disabled until that preview ran and the person authorized this exact command.
// The script keeps its own gates (write session, backups), so the window grants nothing the command line does not.
import { $, call, el, input, setError } from "./common";
import type { SetupFeature } from "./home";

export interface WorkstationRequest { action: string; client?: string; hook?: string; identity?: string; apply: boolean }
interface Feature extends SetupFeature { enableCommand?: string; scope?: string; reason?: string; risk?: string; recommended?: boolean }
interface Ide { name?: string; adapter?: string; confidence?: string; mcpConfigured?: boolean; scopes?: { scope: string; available: boolean; location: string; reason: string }[] }
interface Status { activated: boolean; ides?: Ide[]; features?: Feature[]; recommended: unknown[]; summary?: { features?: number; recommended?: number } }
interface RunResult { command: string; apply: boolean; result: unknown }

const HOOK = /client-hooks\.ps1 -Install -Client (claude-code|codex|antigravity) -Hook (resources-hook|trace-hook)\s*$/;

/** The window action of a feature's enable command, or null when the command is not one the window may run (it is then shown to copy). */
export function featureRequest(f: Feature): WorkstationRequest | null {
  const m = HOOK.exec(f.enableCommand ?? "");
  return m ? { action: "hook-install", client: m[1], hook: m[2], apply: false } : null;
}

export const UPKEEP: { id: string; label: string; note: string; request: WorkstationRequest }[] = [
  { id: "check", label: "Check the workstation", note: "Read-only: directives, IDEs and dossiers.", request: { action: "check", apply: false } },
  { id: "sync", label: "Sync managed blocks", note: "Preview is the check; Apply runs the sync that realigns managed blocks.", request: { action: "sync", apply: false } },
  { id: "launcher", label: "Task launcher in managed checkouts", note: "Writes .secondbrain/run-tasks.ps1 only where absent or outdated.", request: { action: "launcher", apply: false } },
];

let selected: WorkstationRequest | null = null;
let previewedKey = "";
const key = (r: WorkstationRequest) => JSON.stringify({ ...r, apply: false });

function renderStatus(s: Status | null) {
  $("ws-summary").textContent = !s ? "Setup status unavailable."
    : `${s.activated ? "Workstation activated" : "Workstation not activated"}; ${s.summary?.features ?? s.features?.length ?? 0} features, ${s.recommended.length} recommended.`;
  const ides = s?.ides ?? [];
  $("ws-ides").replaceChildren(...ides.map((i) => el("tr", {},
    el("td", { textContent: i.name ?? i.adapter ?? "" }),
    el("td", { textContent: i.mcpConfigured ? "MCP configured" : "MCP not configured" }),
    el("td", { textContent: (i.scopes ?? []).filter((x) => x.available).map((x) => x.scope).join(", ") || "none" }),
    el("td", { textContent: i.confidence ?? "" }))));
  $("ws-ides-empty").hidden = ides.length > 0;
  const features = s?.features ?? [];
  $("ws-features").replaceChildren(...features.map((f) => {
    const req = featureRequest(f);
    const act = el("td", {});
    if (req && f.state === "available") {
      const b = el("button", { textContent: "Review", type: "button" });
      b.setAttribute("aria-label", `Review ${f.id} for ${f.scope ?? ""}`);
      b.addEventListener("click", () => choose(req, `${f.id} (${f.scope ?? ""})`));
      act.append(b);
    } else if (f.enableCommand && f.state === "available") act.append(el("code", { className: "small", textContent: f.enableCommand }));
    return el("tr", { dataset: { feature: `${f.id}:${f.scope ?? ""}` } },
      el("td", { textContent: f.id ?? "" }), el("td", { textContent: f.scope ?? "" }),
      el("td", { textContent: (f.state ?? "") + (f.recommended ? " (recommended)" : "") }),
      el("td", { className: "small", textContent: f.reason ?? "" }), act);
  }));
}

function render() {
  const has = Boolean(selected);
  $("ws-action-box").hidden = !has;
  if (!selected) return;
  $<HTMLButtonElement>("ws-apply").disabled = previewedKey !== key(selected) || !input("ws-authorize").checked || selected.action === "check";
  $("ws-apply").hidden = selected.action === "check";
  input("ws-authorize").parentElement!.hidden = selected.action === "check";
}

async function showCommand() {
  if (!selected) return;
  const c = await call<string>("workstation_command", { request: { ...selected, apply: false } }, "ws-error");
  $("ws-command").textContent = c ?? "";
  const a = selected.action === "check" ? null : await call<string>("workstation_command", { request: { ...selected, apply: true } }, "ws-error");
  $("ws-apply-command").textContent = a ? `Apply runs: ${a}` : "";
}

async function choose(req: WorkstationRequest, label: string) {
  selected = req;
  previewedKey = "";
  input("ws-authorize").checked = false;
  $("ws-action-label").textContent = label;
  $("ws-result").hidden = true;
  setError("ws-error", null);
  render();
  await showCommand();
}

async function run(apply: boolean) {
  if (!selected) return;
  if (apply && (previewedKey !== key(selected) || !input("ws-authorize").checked)) return;
  const r = await call<RunResult>("workstation_run", { request: { ...selected, apply } }, "ws-error");
  if (!r) return;
  $("ws-result").textContent = `${apply ? "Applied" : "Preview, nothing written yet"}: ${r.command}\n` + JSON.stringify(r.result, null, 2);
  $("ws-result").hidden = false;
  previewedKey = apply ? "" : key(selected);
  if (apply) { input("ws-authorize").checked = false; void refreshWorkstation(); }
  render();
}

export async function refreshWorkstation() {
  const s = await call<Status>("read_setup_status", {}, "ws-error");
  renderStatus(s);
}

export function initWorkstation(identity: () => string) {
  $("ws-upkeep").replaceChildren(...UPKEEP.map((u) => {
    const b = el("button", { textContent: u.label, type: "button" });
    b.dataset.upkeep = u.id;
    b.title = u.note;
    b.addEventListener("click", () => void choose({ ...u.request, ...(u.id === "launcher" && identity() ? { identity: identity() } : {}) }, u.label));
    return el("li", {}, b, el("span", { className: "muted small", textContent: " " + u.note }));
  }));
  $("ws-refresh").addEventListener("click", () => void refreshWorkstation());
  $("ws-preview").addEventListener("click", () => void run(false));
  $("ws-apply").addEventListener("click", () => void run(true));
  $("ws-authorize").addEventListener("change", render);
}
