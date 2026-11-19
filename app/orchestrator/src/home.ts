// Home status from the documented JSON of the SecondBrain scripts: setup status (setup-status.ps1), workflow home and prompt catalog (prompts.ps1 -Json, -List -Json).
import { $, call, el } from "./common";

export interface SetupFeature { id?: string; name?: string; state?: string; recommendation?: string }
export interface SetupStatus { activated: boolean; ides?: unknown[]; features?: SetupFeature[]; recommended: unknown[] }
export interface WorkflowHome {
  schema: "secondbrain.prompts.home"; schemaVersion: 1;
  state: { activated: boolean; hostId: string; repositories: number; ides: number; repository: { path: string; identity: string | null; managed: boolean; location: string } | null };
  nextStep: string; chain: string[];
}
export interface CatalogPrompt { id: string; code: string; kind: "system" | "user"; summary: string; scope: string; mode: string; destructive: boolean; pack: string; surface: string; role: string | null; requires: string; example: string }
export interface Catalog {
  schema: "secondbrain.prompts.catalog"; schemaVersion: 1;
  categories: { id: string; group: string; title: string; prompts: CatalogPrompt[] }[];
}

/** One-line summaries of the three JSON documents; a failed script shows its error inline and leaves the other lines alone. */
export function summarize(setup: SetupStatus | null, home: WorkflowHome | null, catalog: Catalog | null) {
  const promptCount = catalog ? catalog.categories.reduce((n, c) => n + c.prompts.length, 0) : 0;
  return {
    setup: setup ? (setup.activated ? `Workstation activated, ${setup.recommended.length} recommendation(s).` : "Workstation not activated.") : "Setup status unavailable.",
    workflows: home ? home.nextStep : "Workflow state unavailable.",
    catalog: catalog ? `${promptCount} prompts in ${catalog.categories.length} categories.` : "Prompt catalog unavailable.",
  };
}

export async function refreshHomeStatus(repo: string) {
  const [setup, home, catalog] = await Promise.all([
    call<SetupStatus>("read_setup_status", {}, "home-json-error"),
    call<WorkflowHome>("read_workflows", { path: repo || null }),
    call<Catalog>("read_catalog"),
  ]);
  const s = summarize(setup, home, catalog);
  $("home-setup-status").textContent = s.setup;
  $("home-workflow").textContent = s.workflows;
  $("home-catalog").textContent = s.catalog;
  const chain = $("home-chain");
  chain.replaceChildren(...(home?.chain ?? []).map((step) => el("li", { textContent: step })));
}
