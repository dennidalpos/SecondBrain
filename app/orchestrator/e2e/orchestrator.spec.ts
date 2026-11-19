// End-to-end scenarios on the real orchestrator binary (Windows, WebView2) with a synthetic SecondBrain:
// preload from --repo, removal of recent repositories across restarts, the directives proposed by the light model and every Directives
// button with its persistence after a restart, agents and models limited to the installed CLIs, a queue run followed live, closed while
// running and found again after reopening, the registry with tool badges, archived tasks and run labels from the lifecycle verdict (orphaned, finished), the analysis that makes a task autonomous,
// the busy buttons (spinner, second click ignored) with a run that waits for a plan limit to reset and resumes by itself, and a run
// stopped by a plan limit whose resume point the window shows and continues with -Resume, and a refused power request that asks Run anyway or Cancel.
// The fixture comes from scripts/test-orchestrator-fixture.ps1 through SB_E2E_FIXTURE; real user settings are never touched.
import { test, expect, chromium, type Browser, type Locator, type Page } from "@playwright/test";
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import * as net from "node:net";

interface Fixture { brain: string; checkout: string; identity: string; tracker: string; dossier: string; config: string; bin: string; configDir: string; binary: string; webviewData: string }
const fixture: Fixture = JSON.parse(fs.readFileSync(process.env.SB_E2E_FIXTURE ?? "", "utf8"));
const settingsFile = path.join(fixture.configDir, "settings.json");

interface App { proc: ChildProcess; browser: Browser; page: Page; exited: Promise<number | null> }

async function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.listen(0, "127.0.0.1", () => { const p = (srv.address() as net.AddressInfo).port; srv.close(() => resolve(p)); });
    srv.on("error", reject);
  });
}

// PATH without any real agent CLI, so the probe sees only the fake Claude Code of the fixture.
function isolatedPath(): string {
  const names = ["claude.exe", "claude.cmd", "claude", "codex.exe", "codex.cmd", "codex", "gemini.exe", "gemini.cmd", "gemini"];
  const dirs = (process.env.PATH ?? "").split(path.delimiter).filter((d) => d && !names.some((n) => fs.existsSync(path.join(d, n))));
  return [fixture.bin, ...dirs].join(path.delimiter);
}

async function launch(opts: { repo?: string; agentSeconds?: number; limitSeconds?: number; powerFail?: boolean } = {}): Promise<App> {
  const port = await freePort();
  const args = opts.repo ? ["--repo", opts.repo] : [];
  const proc = spawn(fixture.binary, args, {
    cwd: fixture.brain,
    env: {
      ...process.env,
      PATH: isolatedPath(),
      SECONDBRAIN_HOME: fixture.brain,
      SECONDBRAIN_ORCHESTRATOR_CONFIG_DIR: fixture.configDir,
      SECONDBRAIN_AGENT_SEARCH_ONLY: "1",
      SECONDBRAIN_AGENT_SEARCH_PATH: fixture.bin,
      SB_E2E_BRAIN: fixture.brain,
      SB_E2E_AGENT_SECONDS: String(opts.agentSeconds ?? 3),
      ...(opts.limitSeconds ? { SB_E2E_AGENT_LIMIT_SECONDS: String(opts.limitSeconds) } : {}),
      // Test-only refusal of the Windows power request (run-ready-tasks.ps1 honours it inside a test run only).
      ...(opts.powerFail ? { SB_RUNNER_TEST_POWER_FAIL: "1", SECONDBRAIN_TEST_ROOT: process.env.SECONDBRAIN_TEST_ROOT || path.dirname(fixture.brain) } : {}),
      WEBVIEW2_USER_DATA_FOLDER: fixture.webviewData,
      WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${port}`,
    },
    stdio: "ignore",
  });
  const exited = new Promise<number | null>((resolve) => proc.on("exit", (code) => resolve(code)));
  let browser: Browser | null = null;
  const deadline = Date.now() + 60_000;
  while (!browser && Date.now() < deadline) {
    try { browser = await chromium.connectOverCDP(`http://127.0.0.1:${port}`); } catch { await new Promise((r) => setTimeout(r, 500)); }
  }
  if (!browser) { proc.kill(); throw new Error("WebView2 DevTools endpoint not reachable"); }
  let page: Page | undefined;
  while (!page && Date.now() < deadline) {
    page = browser.contexts().flatMap((c) => c.pages()).find((p) => !p.url().startsWith("devtools:"));
    if (!page) await new Promise((r) => setTimeout(r, 300));
  }
  if (!page) throw new Error("orchestrator page not found");
  page.on("dialog", (d) => d.accept());
  // Attached, not visible: the first tab shown is Home (or the queue with --repo), not the repository form.
  await page.waitForSelector("#repo-path", { state: "attached" });
  return { proc, browser, page, exited };
}

async function closeApp(app: App) {
  // The same close request as the title bar; without a running queue the window closes at once.
  await app.page.evaluate(() => (window as unknown as { sbOrchestrator: { requestQuit: () => void } }).sbOrchestrator.requestQuit()).catch(() => {});
  const code = await Promise.race([app.exited, new Promise<"timeout">((r) => setTimeout(() => r("timeout"), 15_000))]);
  if (code === "timeout") app.proc.kill();
  await app.browser.close().catch(() => {});
}

function readTracker(): { tasks: { id: string; status: string; execution: string; acceptance?: string[]; extensions?: Record<string, unknown> }[] } {
  return JSON.parse(fs.readFileSync(fixture.tracker, "utf8"));
}

// Counts the Tauri commands the page sends from now on, read from the IPC requests of the WebView (http://ipc.localhost/<command>);
// the page itself is left untouched.
function watchCalls(page: Page): (cmd: string) => number {
  const seen: Record<string, number> = {};
  page.on("request", (r) => {
    const m = /^(?:https?:\/\/ipc\.localhost|ipc:\/\/localhost)\/([A-Za-z0-9_]+)/.exec(r.url());
    if (m) seen[m[1]] = (seen[m[1]] ?? 0) + 1;
  });
  return (cmd) => seen[cmd] ?? 0;
}
// The button just clicked shows the spinner and takes no pointer; a second click sent straight to its handler must start nothing.
// One read in the page, so the state cannot change between the checks.
async function expectBusyAndClickAgain(button: Locator) {
  const seen = await button.evaluate((b) => {
    const state = { busy: b.getAttribute("aria-busy"), marked: b.classList.contains("busy"), pointer: getComputedStyle(b).pointerEvents, spinner: getComputedStyle(b, "::before").animationName };
    (b as HTMLButtonElement).click();
    return state;
  });
  expect(seen.busy).toBe("true");
  expect(seen.marked).toBe(true);
  expect(seen.pointer).toBe("none");
  expect(seen.spinner).toMatch(/^sb-(spin|pulse)$/);
}

test.describe.configure({ mode: "serial" });

test("repository preloaded from --repo, recent entries removed for good across restarts", async () => {
  const missing = path.join(path.dirname(fixture.checkout), "gone-checkout");
  fs.mkdirSync(fixture.configDir, { recursive: true });
  fs.writeFileSync(settingsFile, JSON.stringify({ secondbrainHome: "", pwshPath: "", recentRepos: [missing] }));
  let app = await launch({ repo: fixture.checkout });
  const { page } = app;
  await expect(page.locator("#repo-label")).toHaveText(fixture.identity);
  await expect(page.locator('.steps button[data-tab="queue"]')).toHaveAttribute("aria-selected", "true");
  await expect(page.locator("#repo-tracker")).toContainText("tracker.json");
  await page.locator('.steps button[data-tab="repo"]').click();
  await expect(page.locator("#recent li")).toHaveCount(2);
  await expect(page.locator("#recent li").filter({ hasText: "gone-checkout" })).toContainText("not found");
  await page.locator(`#recent button[data-remove="${missing.replace(/\\/g, "\\\\")}"]`).click();
  await expect(page.locator("#recent li")).toHaveCount(1);
  await page.locator(`#recent button[data-remove="${fixture.checkout.replace(/\\/g, "\\\\")}"]`).click();
  await expect(page.locator("#recent li")).toHaveCount(0);
  // An unrelated settings change must not bring the removed entries back (the old window rewrote its stale list).
  await page.locator('.steps button[data-tab="settings"]').click();
  await page.locator("#s-save").click();
  await expect(page.locator("#s-info")).toHaveText("Settings saved.");
  expect(JSON.parse(fs.readFileSync(settingsFile, "utf8")).recentRepos).toEqual([]);
  await closeApp(app);

  app = await launch();
  await expect(app.page.locator('.steps button[data-tab="home"]')).toHaveAttribute("aria-selected", "true");
  await app.page.locator('.steps button[data-tab="repo"]').click();
  await expect(app.page.locator("#recent-empty")).toBeVisible();
  await expect(app.page.locator("#repo-label")).toHaveText("No repository");
  await closeApp(app);
});

test("home: three actions, concise status, and opening starts no execution (#630)", async () => {
  fs.mkdirSync(fixture.configDir, { recursive: true });
  fs.writeFileSync(settingsFile, JSON.stringify({ secondbrainHome: "", pwshPath: "", recentRepos: [fixture.checkout] }));
  const runsDir = path.join(fixture.checkout, ".runtime");
  const before = fs.existsSync(runsDir) ? fs.readdirSync(runsDir).length : 0;
  const app = await launch();
  const { page } = app;
  // Opened without --repo: Home is shown, with the three actions and the status.
  await expect(page.locator('.steps button[data-tab="home"]')).toHaveAttribute("aria-selected", "true");
  await expect(page.locator("#tab-home")).toBeVisible();
  await expect(page.locator("#tab-home .home-card h3")).toHaveText(["Runner", "Workstation Setup", "Library"]);
  await expect(page.locator("#home-run")).toHaveText("No run is active.");
  await expect(page.locator("#home-questions")).toContainText(/None|waiting for the person/);
  await expect(page.locator("#run-badge")).toHaveText("Idle");
  // The actions only navigate.
  await page.locator("#home-setup").click();
  await expect(page.locator("#tab-workstation")).toBeVisible();
  await page.locator('.steps button[data-tab="home"]').click();
  await page.locator("#home-runner").click();
  await expect(page.locator("#tab-queue")).toBeVisible();
  await page.locator('.steps button[data-tab="home"]').click();
  await page.locator("#home-library").click();
  await expect(page.locator("#tab-registry")).toBeVisible();
  // Nothing ran: still idle, no run folder created by opening and navigating.
  await expect(page.locator("#run-badge")).toHaveText("Idle");
  expect(fs.existsSync(runsDir) ? fs.readdirSync(runsDir).length : 0).toBe(before);
  await closeApp(app);
});

test("sections: reachable directly, no sequential Next buttons, selected target kept across sections (#631)", async () => {
  fs.mkdirSync(fixture.configDir, { recursive: true });
  fs.writeFileSync(settingsFile, JSON.stringify({ secondbrainHome: "", pwshPath: "", recentRepos: [] }));
  const app = await launch();
  const { page } = app;
  const tabs = ["repo", "workstation", "directives", "queue", "run", "registry", "tracker", "settings"];
  // No repository yet: every section is enabled and opens; the ones that need a repository say so.
  for (const tab of tabs) {
    const b = page.locator(`.steps button[data-tab="${tab}"]`);
    await expect(b).toBeEnabled();
    await b.click();
    await expect(page.locator(`#tab-${tab}`)).toBeVisible();
  }
  await page.locator('.steps button[data-tab="queue"]').click();
  await expect(page.locator("#no-repo-note")).toBeVisible();
  // The step-by-step buttons are gone from the sections.
  await expect(page.locator("#repo-next, #dir-next")).toHaveCount(0);
  // Load a target, then move between sections in any order: it stays selected.
  await page.locator('.steps button[data-tab="repo"]').click();
  await page.locator("#repo-path").fill(fixture.checkout);
  await page.locator("#repo-load").click();
  await expect(page.locator("#repo-label")).toHaveText(fixture.identity);
  for (const tab of ["registry", "run", "directives", "tracker", "queue", "repo"]) {
    await page.locator(`.steps button[data-tab="${tab}"]`).click();
    await expect(page.locator(`#tab-${tab}`)).toBeVisible();
    await expect(page.locator("#repo-label")).toHaveText(fixture.identity);
    await expect(page.locator("#no-repo-note")).toBeHidden();
  }
  await expect(page.locator("#repo-path")).toHaveValue(fixture.checkout);
  await closeApp(app);
});

test("directives: light-model proposal, preview, approve and apply, reload; the text survives a restart", async () => {
  let app = await launch({ repo: fixture.checkout });
  let { page } = app;
  await expect(page.locator("#repo-label")).toHaveText(fixture.identity);
  await expect(page.locator('.steps button[data-tab="queue"]')).toHaveAttribute("aria-selected", "true");
  await page.locator('.steps button[data-tab="directives"]').click();
  await expect(page.locator("#dir-target")).toContainText("AGENTS.managed.md");
  // The global, common and composed blocks are shown read-only with the startup budget.
  await expect(page.locator("#dir-global")).not.toBeEmpty({ timeout: 60_000 });
  await expect(page.locator("#dir-budget")).toContainText("%");
  await expect(page.locator("#dir-light")).toContainText("Claude Code");
  await page.locator("#dir-propose").click();
  await expect(page.locator("#dir-analysis")).toBeVisible({ timeout: 120_000 });
  await expect(page.locator("#dir-sections")).toContainText("Product test script.");
  await expect(page.locator("#dir-covered")).toContainText("Commit and push");
  await page.locator("#dir-use").click();
  await expect(page.locator("#dir-text")).toHaveValue(/## Checks/);
  await expect(page.locator("#dir-apply")).toBeDisabled();
  const text = "## Synthetic E2E directives\n\n- Checks: npm test before closing a task.\n";
  await page.locator("#dir-text").fill(text);
  await page.locator("#dir-preview").click();
  await expect(page.locator("#dir-apply")).toBeEnabled({ timeout: 90_000 });
  await expect(page.locator("#dir-preview-box")).toBeVisible();
  await page.locator("#dir-apply").click();
  await expect(page.locator("#dir-state")).toHaveText("Directives approved and aligned.", { timeout: 120_000 });
  await expect(page.locator("#dir-error")).toBeHidden();
  expect(fs.readFileSync(path.join(fixture.checkout, "AGENTS.md"), "utf8")).toContain("Synthetic E2E directives");
  expect(fs.readFileSync(path.join(fixture.dossier, "AGENTS.managed.md"), "utf8")).toContain("Synthetic E2E directives");
  // Editing invalidates nothing on disk; "Ricarica dal dossier" restores the approved text.
  await page.locator("#dir-text").fill("bozza non approvata");
  await page.locator("#dir-reload").click();
  await expect(page.locator("#dir-text")).toHaveValue(/Synthetic E2E directives/);
  // The import command reads Markdown only (the native file dialog itself cannot be driven here).
  const imported = await page.evaluate(async (p) => {
    const internals = (window as unknown as { __TAURI_INTERNALS__: { invoke: (c: string, a: object) => Promise<string> } }).__TAURI_INTERNALS__;
    const ok = await internals.invoke("read_text_file", { path: p });
    let refused = "";
    try { await internals.invoke("read_text_file", { path: p.replace(/\.md$/, ".txt") }); } catch (e) { refused = String(e); }
    return { ok, refused };
  }, path.join(fixture.checkout, "README.md"));
  expect(imported.ok).toContain("Synthetic product");
  expect(imported.refused).toContain("Markdown");
  await closeApp(app);

  app = await launch({ repo: fixture.checkout });
  page = app.page;
  await page.locator('.steps button[data-tab="directives"]').click();
  await expect(page.locator("#dir-text")).toHaveValue(/Synthetic E2E directives/);
  await expect(page.locator("#dir-current")).toContainText("Synthetic E2E directives");
  await closeApp(app);
});

test("queue lists only the installed agents and the models their CLI exposes", async () => {
  const app = await launch({ repo: fixture.checkout });
  const { page } = app;
  await expect(page.locator("#q-agents label.agent")).toHaveCount(3, { timeout: 60_000 });
  const claude = page.locator("#q-agents label.agent").filter({ hasText: "Claude Code" });
  await expect(claude).toContainText("ready");
  await expect(claude).toContainText("2.1.0");
  await expect(claude.locator("input")).toBeChecked();
  for (const name of ["Codex", "Gemini CLI"]) {
    const off = page.locator("#q-agents label.agent").filter({ hasText: name });
    await expect(off).toContainText("not installed");
    await expect(off.locator("input")).toBeDisabled();
  }
  const models = await page.locator("#q-model option").evaluateAll((o) => o.map((x) => (x as HTMLOptionElement).value));
  expect(models).toEqual(["", "opus", "sonnet"]);
  const efforts = await page.locator("#q-effort option").evaluateAll((o) => o.map((x) => (x as HTMLOptionElement).value));
  expect(efforts[0]).toBe("");
  expect(efforts.every((e) => ["", "low", "medium", "high", "xhigh", "max"].includes(e))).toBe(true);
  await expect(page.locator("#q-tasks tr")).toHaveCount(3);
  await closeApp(app);
});

test("a queue run is followed live, survives closing the window and is found again after reopening", async () => {
  let app = await launch({ repo: fixture.checkout, agentSeconds: 15 });
  let { page } = app;
  await expect(page.locator("#q-tasks tr")).toHaveCount(3, { timeout: 60_000 });
  await expect(page.locator("#q-agents label.agent").filter({ hasText: "Claude Code" }).locator("input")).toBeChecked();
  await page.locator("#q-tasks tr").filter({ hasText: "E2E-1" }).locator('input[type="checkbox"]').check();
  await page.locator("#q-start").click();
  await expect(page.locator('.steps button[data-tab="run"]')).toHaveAttribute("aria-selected", "true");
  await expect(page.locator("#run-verdict")).toHaveText("Working", { timeout: 60_000 });
  await expect(page.locator("#run-steps")).toContainText("Read: README.md", { timeout: 30_000 });
  await expect(page.locator("#run-task")).toContainText("E2E-1");
  await expect(page.locator("#run-folder")).toContainText("runner-run-");
  // #635: steps, run folder and log sit behind labelled disclosure (closed by default); progress and errors stay visible.
  await expect(page.locator("#run-steps-box > summary")).toContainText(/Agent steps \(\d+\)/);
  await expect(page.locator("#run-steps-box")).not.toHaveAttribute("open", "");
  await expect(page.locator("#run-counts")).toBeVisible();
  await expect(page.locator("#run-problems")).toBeHidden();
  // Closing asks what to do; "leave running" closes the window and keeps the detached runner going.
  await page.evaluate(() => (window as unknown as { sbOrchestrator: { requestQuit: () => void } }).sbOrchestrator.requestQuit());
  await expect(page.locator("#close-dialog")).toBeVisible();
  await page.locator('#close-dialog button[data-close="leave"]').click();
  await Promise.race([app.exited, new Promise((r) => setTimeout(r, 15_000))]);
  await app.browser.close().catch(() => {});

  app = await launch({ repo: fixture.checkout, agentSeconds: 15 });
  page = app.page;
  await expect(page.locator('.steps button[data-tab="run"]')).toHaveAttribute("aria-selected", "true", { timeout: 60_000 });
  await expect(page.locator("#run-log")).toContainText("found again and reattached");
  await expect(page.locator("#run-steps")).toContainText("Read: README.md");
  await expect(page.locator("#run-verdict")).toHaveText("Last run finished", { timeout: 120_000 });
  await expect(page.locator("#run-results tr").filter({ hasText: "E2E-1" })).toContainText("finished");
  // #613: the process finished, but the task is only in progress: its acceptance is shown as open, apart from the process outcome.
  await expect(page.locator("#run-results tr").filter({ hasText: "E2E-1" }).locator("td").nth(4)).toHaveText("open");
  // #641: the reopened task counts as a process success, not as accepted.
  await expect(page.locator("#run-counts")).toContainText("(1 succeeded, 0 failed) · 0 accepted");
  await expect(page.locator("#run-steps")).toContainText("npm test");
  expect(readTracker().tasks.find((t) => t.id === "E2E-1")?.status).toBe("in_progress");
  await page.locator('.steps button[data-tab="queue"]').click();
  await expect(page.locator("#q-tasks tr")).toHaveCount(2);
  await closeApp(app);
});

test("registry: every task with its tool badge, archived tasks and the runner history", async () => {
  const app = await launch({ repo: fixture.checkout });
  const { page } = app;
  await page.locator('.steps button[data-tab="registry"]').click();
  await expect(page.locator("#reg-rows tr.reg-row")).toHaveCount(5, { timeout: 60_000 });
  const archived = page.locator("#reg-rows tr.reg-row").filter({ hasText: "E2E-0" });
  await expect(archived).toContainText("archived");
  await expect(archived.locator(".tool-badge")).toHaveAttribute("data-tool", "unknown");
  const ran = page.locator("#reg-rows tr.reg-row").filter({ hasText: "E2E-1" });
  await expect(ran.locator('.tool-badge[data-tool="claude"]')).toBeVisible();
  await ran.click();
  await expect(page.locator("#reg-rows .reg-runs").first()).toContainText("Claude");
  await page.locator("#reg-archived").selectOption("only");
  await expect(page.locator("#reg-rows tr.reg-row")).toHaveCount(1, { timeout: 30_000 });
  await page.locator('[data-reg-view="runs"]').click();
  await expect(page.locator("#reg-run-rows tr").first()).toContainText("Claude", { timeout: 30_000 });
  // #600: a run recorded as running whose process is gone (no pid) is labelled interrupted, never running; a finished run shows its end.
  const finished = page.locator("#reg-run-rows tr").first();
  const folder = ((await finished.locator("td .mono").textContent()) ?? "").trim();
  expect(folder).toMatch(/runner-run-/);
  await expect(finished.locator("td details > summary")).toHaveText("Run folder");
  await expect(page.locator("#reg-run-rows tr").filter({ hasText: "accepted" }).first()).toContainText(/\d+ of \d+ tasks \(\d+ succeeded, \d+ failed\) · \d+ accepted/);
  await expect(finished.locator("td").nth(1)).not.toContainText(/running|interrupted|unknown/);
  const orphanId = "29991231-235959-runner-run-e2eorphan";
  const orphanFolder = path.join(path.dirname(folder), orphanId);
  fs.mkdirSync(orphanFolder, { recursive: true });
  fs.writeFileSync(path.join(orphanFolder, "status.json"), JSON.stringify({ schemaVersion: 1, runId: orphanId, state: "running", phase: "agent", provider: "claude",
    repository: fixture.identity, startedAt: "2026-01-15T10:00:00Z", updatedAt: "2026-01-15T10:05:00Z", results: [] }));
  try {
    await page.locator("#reg-refresh").click();
    const orphan = page.locator("#reg-run-rows tr").filter({ hasText: orphanId });
    await expect(orphan).toHaveCount(1, { timeout: 30_000 });
    await expect(orphan.locator("td").nth(1)).toHaveText("interrupted · finish time unknown");
    await expect(orphan.locator("td").nth(1).locator("span")).toHaveAttribute("title", "verdict: orphaned");
    await expect(page.locator("#reg-run-rows tr").filter({ hasText: path.basename(folder) }).locator("td").nth(1)).not.toContainText(/running|interrupted/);
  } finally {
    fs.rmSync(orphanFolder, { recursive: true, force: true });
  }
  await closeApp(app);
});

test("tracker: the bound projects are listed and the selected tracker is read without writing", async () => {
  const app = await launch({ repo: fixture.checkout });
  const { page } = app;
  const before = fs.readFileSync(fixture.tracker, "utf8");
  await page.locator('.steps button[data-tab="tracker"]').click();
  await expect(page.locator("#trk-project option")).toHaveCount(1, { timeout: 60_000 });
  await expect(page.locator("#trk-facts")).toContainText(fixture.identity);
  await expect(page.locator("#trk-facts")).toContainText("proposed default, not confirmed");
  await expect(page.locator("#trk-rows tr")).toHaveCount(5, { timeout: 60_000 });
  await expect(page.locator("#trk-rows tr").filter({ hasText: "E2E-0" })).toContainText("archived");
  await page.locator("#trk-status").selectOption("done");
  await expect(page.locator("#trk-rows tr")).toHaveCount(1, { timeout: 30_000 });
  await page.locator("#trk-next-load").click();
  await expect(page.locator("#trk-next-list li")).not.toHaveCount(0, { timeout: 90_000 });
  await expect(page.locator("#trk-next-list")).toContainText("Git and GitHub");
  await expect(page.locator("#trk-next-list")).toContainText("Run the next ready task");
  expect(fs.readFileSync(fixture.tracker, "utf8")).toBe(before);
  await closeApp(app);
});

test("queue: a task that cannot run alone is analyzed, the owner answers and the update makes it autonomous", async () => {
  const app = await launch({ repo: fixture.checkout });
  const { page } = app;
  const row = page.locator("#q-skipped tr").filter({ hasText: "E2E-4" });
  await expect(row).toContainText("A choice by the owner is needed", { timeout: 60_000 });
  const calls = watchCalls(page);
  const analyze = row.locator("button", { hasText: "Analyze" });
  await analyze.click();
  await expectBusyAndClickAgain(analyze);
  const dialog = page.locator("#an-dialog");
  await expect(dialog).toBeVisible({ timeout: 120_000 });
  expect(calls("analyze_task")).toBe(1);
  // G01 F4: every control of the dialog has an accessible name, the free-text "Other" radio included.
  await expect(dialog.getByRole("radio", { name: "Other answer" })).toHaveCount(1);
  const unnamed = await dialog.locator("input, button, select, textarea").evaluateAll((nodes) => nodes.filter((e) => {
    const c = e as HTMLInputElement;
    return !(e.getAttribute("aria-label") || e.textContent?.trim() || c.labels?.length || e.getAttribute("title") || c.placeholder);
  }).length);
  expect(unnamed).toBe(0);
  await expect(dialog.locator("legend")).toContainText("Which section should be added to the README?");
  await expect(dialog.locator("label.choice").first()).toContainText("Installation (recommended)");
  await expect(page.locator("#an-primary")).toBeDisabled();
  await dialog.locator("label.choice").first().locator("input").check();
  await page.locator("#an-primary").click();
  await expect(page.locator("#an-primary")).toHaveText("Apply to the tracker", { timeout: 120_000 });
  await expect(dialog.locator("table.diff")).toContainText("autonomous");
  await page.locator("#an-primary").click();
  await expect(page.locator("#an-state")).toHaveText("Task updated.", { timeout: 120_000 });
  const task = readTracker().tasks.find((t) => t.id === "E2E-4");
  expect(task?.execution).toBe("autonomous");
  expect(task?.acceptance).toContain("npm test passa");
  expect(JSON.stringify(task?.extensions?.decisions)).toContain("Installation");
  const ledger = fs.readFileSync(path.join(fixture.dossier, "history", "task-runs.jsonl"), "utf8");
  expect(ledger).toMatch(/"taskId":"E2E-4".*"mode":"analysis"/);
  await page.locator("#an-close").click();
  await page.locator("#q-refresh").click();
  await expect(page.locator("#q-tasks tr").filter({ hasText: "E2E-4" })).toHaveCount(1, { timeout: 60_000 });
  await expect(page.locator("#q-skipped tr").filter({ hasText: "E2E-4" })).toHaveCount(0);
  await closeApp(app);
});

test("busy buttons ignore a second click; a run stopped by a plan limit waits for the reset and resumes by itself", async () => {
  test.setTimeout(420_000);
  const app = await launch({ repo: fixture.checkout, limitSeconds: 8 });
  const { page } = app;
  await expect(page.locator("#repo-label")).toHaveText(fixture.identity);
  await expect(page.locator("#q-tasks tr")).toHaveCount(3, { timeout: 60_000 });
  const calls = watchCalls(page);

  // «Load»: spinner with its own label while the repository is resolved, one resolution only.
  await page.locator('.steps button[data-tab="repo"]').click();
  const load = page.locator("#repo-load");
  await load.click();
  await expect(load).toHaveText("Loading…");
  await expectBusyAndClickAgain(load);
  await expect(load).not.toHaveAttribute("aria-busy", "true", { timeout: 60_000 });
  await expect(load).toHaveText("Load");
  expect(calls("resolve_repository")).toBe(1);

  // «Detect again»: one probe of the agents.
  await page.locator('.steps button[data-tab="queue"]').click();
  await expect(page.locator("#q-tasks tr")).toHaveCount(3, { timeout: 60_000 });
  const reprobe = page.locator("#q-reprobe");
  await expect(reprobe).not.toHaveAttribute("aria-busy", "true", { timeout: 60_000 });
  const probesBefore = calls("probe_agents");
  await reprobe.click();
  await expectBusyAndClickAgain(reprobe);
  await expect(reprobe).not.toHaveAttribute("aria-busy", "true", { timeout: 60_000 });
  expect(calls("probe_agents")).toBe(probesBefore + 1);

  // «Start the queue»: one runner, even with a second click while the first is starting.
  await expect(page.locator("#q-agents label.agent").filter({ hasText: "Claude Code" }).locator("input")).toBeChecked();
  await expect(page.locator("#q-wait")).toBeChecked();
  await page.locator("#q-tasks tr").filter({ hasText: "E2E-2" }).locator('input[type="checkbox"]').check();
  const start = page.locator("#q-start");
  await start.click();
  await expectBusyAndClickAgain(start);
  await expect(page.locator('.steps button[data-tab="run"]')).toHaveAttribute("aria-selected", "true", { timeout: 60_000 });
  await expect(start).not.toHaveAttribute("aria-busy", "true", { timeout: 60_000 });
  expect(calls("start_queue")).toBe(1);

  // The fake agent hits a limit that resets in seconds: the run stays alive and the card says when it resumes, counting down.
  await expect(page.locator("#run-verdict")).toHaveText("Waiting for the reset", { timeout: 120_000 });
  await expect(page.locator("#run-badge")).toHaveText("Waiting for the reset");
  await expect(page.locator("#run-task")).toHaveText("Waiting for the limits to reset, then resumes from E2E-2");
  await expect(page.locator("#run-warning")).toBeVisible();
  // #564: the interrupted attempt is not shown as a failed task, and the resume time sits under its own label.
  await expect(page.locator("#run-counts")).toContainText("0 of 1 tasks (0 succeeded, 0 failed)");
  await expect(page.locator("#run-last-label")).toHaveText("Resumes");
  const countdown = async () => {
    const m = /^Resumes at .+ \(in (?:(\d+) min )?(\d+) s\)/.exec((await page.locator("#run-last").textContent()) ?? "");
    return m ? Number(m[1] ?? 0) * 60 + Number(m[2]) : NaN;
  };
  await expect.poll(countdown, { timeout: 30_000 }).toBeGreaterThan(0);
  const first = await countdown();
  if (process.env.SB_E2E_SCREENSHOTS) await page.screenshot({ path: path.join(process.env.SB_E2E_SCREENSHOTS, "run-waiting-for-reset.png") });
  await expect.poll(countdown, { timeout: 30_000 }).toBeLessThan(first);

  // After the reset the same task runs again and the run closes by itself.
  await expect(page.locator("#run-verdict")).toHaveText("Last run finished", { timeout: 240_000 });
  await expect(page.locator("#run-warning")).toBeHidden();
  await expect(page.locator("#run-last-label")).toHaveText("Last agent signal");
  await expect(page.locator("#run-results tr").filter({ hasText: "E2E-2" }).last()).toContainText("finished");
  expect(readTracker().tasks.find((t) => t.id === "E2E-2")?.status).toBe("in_progress");
  await closeApp(app);
});

test("a run stopped by a plan limit shows its resume point, and the window resumes it with -Resume", async () => {
  test.setTimeout(420_000);
  // A fresh limit for this scenario: the fake agent hits it once more (the marker of the previous scenario is its own fixture state).
  fs.rmSync(path.join(path.dirname(fixture.brain), "agent-limit.mark"), { force: true });
  const app = await launch({ repo: fixture.checkout, limitSeconds: 5 });
  const { page } = app;
  await expect(page.locator("#q-tasks tr").filter({ hasText: "E2E-3" })).toHaveCount(1, { timeout: 60_000 });
  await expect(page.locator("#q-agents label.agent").filter({ hasText: "Claude Code" }).locator("input")).toBeChecked();
  await page.locator("#q-wait").uncheck();
  await page.locator("#q-tasks tr").filter({ hasText: "E2E-3" }).locator('input[type="checkbox"]').check();
  const calls = watchCalls(page);
  await page.locator("#q-start").click();
  await expect(page.locator('.steps button[data-tab="run"]')).toHaveAttribute("aria-selected", "true", { timeout: 60_000 });

  // Without -WaitForReset the run stops at the limit and the card shows the resume point runner-status reports.
  await expect(page.locator("#run-verdict")).toHaveText("Last run finished", { timeout: 180_000 });
  await expect(page.locator("#run-counts")).toContainText("stopped: quota");
  // #602: the quota reading shows provider, state (unknown with its reason), source and observation time.
  await expect(page.locator("#run-counts")).toContainText(/quota claude: (unknown \((missing|stale|malformed|unsupported)\)|exhausted|available), source [a-z-]+/);
  const resume = page.locator("#run-resume");
  await expect(resume).toBeVisible({ timeout: 30_000 });
  const text = page.locator("#run-resume-text");
  await expect(text).toContainText("interrupted task E2E-3");
  await expect(text).toContainText("1 task to run (E2E-3)");
  await expect(text).toContainText("Claude Code");
  const runId = /Run (\S+) stopped/.exec((await text.textContent()) ?? "")?.[1] ?? "";
  expect(runId).toMatch(/runner-run-/);
  expect(readTracker().tasks.find((t) => t.id === "E2E-3")?.status).toBe("todo");
  if (process.env.SB_E2E_SCREENSHOTS) await page.screenshot({ path: path.join(process.env.SB_E2E_SCREENSHOTS, "run-resume-point.png") });

  // After the reset the button starts run-ready-tasks.ps1 -Resume <run>: the interrupted task runs again and the point is used.
  await expect.poll(async () => { await page.locator("#run-refresh").click(); return (await text.textContent()) ?? ""; }, { timeout: 60_000, intervals: [2_000] }).toContain("plan reset reached");
  await page.locator("#run-resume-start").click();
  await expect(resume).toBeHidden({ timeout: 60_000 });
  expect(calls("start_queue")).toBe(2);
  // #650: the window still shows the stopped run's Finished verdict until it reattaches; wait for the new run folder before asserting the result row.
  await expect.poll(async () => path.basename(((await page.locator("#run-folder").textContent()) ?? "").trim()), { timeout: 120_000, intervals: [1_000] }).not.toBe(runId);
  await expect(page.locator("#run-verdict")).toHaveText("Last run finished", { timeout: 240_000 });
  await expect(page.locator("#run-results tr").filter({ hasText: "E2E-3" }).last()).toContainText("finished", { timeout: 60_000 });
  expect(readTracker().tasks.find((t) => t.id === "E2E-3")?.status).toBe("in_progress");
  // The new run consumed the resume point of the stopped one: its resume.json names the run shown in the card.
  const newFolder = ((await page.locator("#run-folder").textContent()) ?? "").trim();
  expect(path.basename(newFolder)).not.toBe(runId);
  const point = JSON.parse(fs.readFileSync(path.join(path.dirname(newFolder), runId, "resume.json"), "utf8"));
  expect(point.resumedBy).toBe(path.basename(newFolder));
  await expect(resume).toBeHidden();
  await closeApp(app);
});

test("a refused power request asks Run anyway or Cancel: Cancel starts nothing, Run anyway runs the queue without the request", async () => {
  test.setTimeout(300_000);
  // E2E-3 is ready again for this scenario (the previous one left it in progress).
  const reset = spawnSync("pwsh", ["-NoProfile", "-File", path.join(fixture.brain, "scripts", "knowledge.ps1"), "-ConfigPath", fixture.config, "-CheckoutPath", fixture.checkout,
    "-UpdateTaskId", "E2E-3", "-Status", "todo", "-StateReason", "Ready again for the power scenario"], { encoding: "utf8", env: { ...process.env, SECONDBRAIN_HOME: fixture.brain } });
  expect(reset.status, reset.stderr).toBe(0);
  const app = await launch({ repo: fixture.checkout, powerFail: true });
  const { page } = app;
  await expect(page.locator("#q-tasks tr").filter({ hasText: "E2E-3" })).toHaveCount(1, { timeout: 60_000 });
  await page.locator("#q-wait").uncheck();
  await page.locator("#q-tasks tr").filter({ hasText: "E2E-3" }).locator('input[type="checkbox"]').check();
  const calls = watchCalls(page);
  const dialog = page.locator("#power-dialog");
  await page.locator("#q-start").click();
  await expect(dialog).toBeVisible({ timeout: 120_000 });
  await expect(dialog.locator("button")).toHaveText(["Run anyway", "Cancel"]);
  await expect(page.locator("#power-reason")).toContainText("simulated failure");
  expect(readTracker().tasks.find((t) => t.id === "E2E-3")?.status).toBe("todo");
  await dialog.locator('button[data-power="cancel"]').click();
  await expect(dialog).toBeHidden();
  await page.waitForTimeout(2_000);
  expect(calls("start_queue")).toBe(1);
  expect(readTracker().tasks.find((t) => t.id === "E2E-3")?.status).toBe("todo");

  await page.locator('.steps button[data-tab="queue"]').click();
  // The queue reloads after a run ends; select again on the refreshed list.
  await page.locator("#q-refresh").click();
  await expect(page.locator("#q-tasks tr").filter({ hasText: "E2E-3" })).toHaveCount(1, { timeout: 60_000 });
  await expect(page.locator("#q-count")).toContainText("0 selected", { timeout: 30_000 });
  await page.locator("#q-tasks tr").filter({ hasText: "E2E-3" }).locator('input[type="checkbox"]').check();
  await expect(page.locator("#q-count")).toContainText("1 selected");
  await page.locator("#q-start").click();
  await expect(dialog).toBeVisible({ timeout: 120_000 });
  await dialog.locator('button[data-power="run"]').click();
  await expect(page.locator("#run-verdict")).toHaveText("Last run finished", { timeout: 180_000 });
  expect(calls("start_queue")).toBe(3);
  await expect(page.locator("#run-results tr").filter({ hasText: "E2E-3" }).last()).toContainText("finished");
  expect(readTracker().tasks.find((t) => t.id === "E2E-3")?.status).toBe("in_progress");
  const folder = ((await page.locator("#run-folder").textContent()) ?? "").trim();
  const status = JSON.parse(fs.readFileSync(path.join(folder, "status.json"), "utf8"));
  expect(status.allowNoPowerRequest).toBe(true);
  expect(status.powerRequest.acquired).toBe(false);
  await closeApp(app);
});

test("run end: the Git preference and the next steps appear, and an action needs a preview and a confirmation (#664)", async () => {
  const app = await launch({ repo: fixture.checkout, agentSeconds: 3 });
  const { page } = app;
  await expect(page.locator("#q-tasks tr")).not.toHaveCount(0, { timeout: 60_000 });
  await page.locator("#q-tasks tr").first().locator('input[type="checkbox"]').check();
  await page.locator("#q-start").click();
  await expect(page.locator("#run-verdict")).toHaveText("Last run finished", { timeout: 180_000 });
  // The panel appears by itself when the run ends, with the preference and the proposals.
  await expect(page.locator("#run-end-box")).toBeVisible({ timeout: 90_000 });
  await expect(page.locator("#run-end-git")).toContainText("Git and GitHub update", { timeout: 60_000 });
  await expect(page.locator("#run-next-list li")).not.toHaveCount(0, { timeout: 90_000 });
  const withTask = page.locator("#run-next-list li").filter({ has: page.locator("button.next-preview") }).first();
  const before = fs.readFileSync(fixture.tracker, "utf8");
  // Nothing happens without the explicit steps: the confirm button is hidden until the preview, and the preview itself changes nothing.
  await expect(withTask.locator("button.primary")).toBeHidden();
  await withTask.locator("button.next-preview").click();
  await expect(withTask).toContainText("Nothing is started or written");
  await expect(page.locator('.steps button[data-tab="run"]')).toHaveAttribute("aria-selected", "true");
  await withTask.locator("button.primary").click();
  await expect(page.locator('.steps button[data-tab="queue"]')).toHaveAttribute("aria-selected", "true", { timeout: 30_000 });
  expect(fs.readFileSync(fixture.tracker, "utf8")).toBe(before);
  await closeApp(app);
});

test("run end: a follow-up task is created only after a preview and a confirmation, and a card opens without writing (#672)", async () => {
  // E2E-1 is ready again for this scenario (the earlier runs left every task in progress).
  const reset = spawnSync("pwsh", ["-NoProfile", "-File", path.join(fixture.brain, "scripts", "knowledge.ps1"), "-ConfigPath", fixture.config, "-CheckoutPath", fixture.checkout,
    "-UpdateTaskId", "E2E-1", "-Status", "todo", "-StateReason", "Ready again for the follow-up scenario"], { encoding: "utf8", env: { ...process.env, SECONDBRAIN_HOME: fixture.brain } });
  expect(reset.status, reset.stderr).toBe(0);
  const app = await launch({ repo: fixture.checkout, agentSeconds: 3 });
  const { page } = app;
  await expect(page.locator("#q-tasks tr")).not.toHaveCount(0, { timeout: 60_000 });
  await page.locator("#q-tasks tr").first().locator('input[type="checkbox"]').check();
  await page.locator("#q-start").click();
  await expect(page.locator("#run-verdict")).toHaveText("Last run finished", { timeout: 180_000 });
  await expect(page.locator("#run-end-box")).toBeVisible({ timeout: 90_000 });
  await expect(page.locator("#run-next-list li")).not.toHaveCount(0, { timeout: 90_000 });
  const before = fs.readFileSync(fixture.tracker, "utf8");
  const count = readTracker().tasks.length;
  const step = page.locator("#run-next-list li").filter({ has: page.locator("button.followup-preview-btn") }).first();
  await expect(step.locator("button.followup-confirm")).toBeHidden();
  await step.locator("button.followup-preview-btn").click();
  await expect(step.locator(".followup-preview")).toContainText("nothing written yet", { timeout: 60_000 });
  expect(fs.readFileSync(fixture.tracker, "utf8")).toBe(before);
  await step.locator("button.followup-confirm").click();
  await expect(step.locator(".followup-result")).toContainText("Task created", { timeout: 90_000 });
  await expect.poll(() => readTracker().tasks.length, { timeout: 60_000 }).toBe(count + 1);
  // The card opens read-only: the tracker does not change.
  const after = fs.readFileSync(fixture.tracker, "utf8");
  const card = page.locator("#run-next-list li").filter({ has: page.locator("button.card-open") }).first();
  if (await card.count()) {
    await card.locator("button.card-open").click();
    await expect(card.locator(".card-view")).toBeVisible({ timeout: 30_000 });
    expect(fs.readFileSync(fixture.tracker, "utf8")).toBe(after);
  }
  await closeApp(app);
});

test("tracker: the Git and GitHub preference is saved only after a preview and an explicit confirmation (#663)", async () => {
  const app = await launch({ repo: fixture.checkout });
  const { page } = app;
  const file = path.join(fixture.dossier, "repository.json");
  const before = fs.readFileSync(file, "utf8");
  await page.locator('.steps button[data-tab="tracker"]').click();
  await expect(page.locator("#trk-project option")).toHaveCount(1, { timeout: 60_000 });
  await expect(page.locator("#trk-git-box")).toBeVisible();
  await expect(page.locator("#trk-git-apply")).toBeDisabled();
  await page.locator("#trk-git-mode").selectOption("branch-pr");
  await page.locator("#trk-git-branch").fill("feature/e2e");
  await expect(page.locator("#trk-git-apply")).toBeDisabled();
  await page.locator("#trk-git-preview").click();
  await expect(page.locator("#trk-git-plan")).toContainText("branch-pr on feature/e2e", { timeout: 60_000 });
  await expect(page.locator("#trk-git-apply")).toBeEnabled();
  expect(fs.readFileSync(file, "utf8")).toBe(before);
  // Changing the values invalidates the preview.
  await page.locator("#trk-git-branch").fill("feature/other");
  await expect(page.locator("#trk-git-apply")).toBeDisabled();
  await page.locator("#trk-git-branch").fill("feature/e2e");
  await page.locator("#trk-git-preview").click();
  await expect(page.locator("#trk-git-apply")).toBeEnabled({ timeout: 60_000 });
  await page.locator("#trk-git-apply").click();
  await expect(page.locator("#trk-git-plan")).toContainText("Saved", { timeout: 60_000 });
  const record = JSON.parse(fs.readFileSync(file, "utf8"));
  expect(record.gitUpdate).toEqual({ mode: "branch-pr", branch: "feature/e2e" });
  await expect(page.locator("#trk-facts")).not.toContainText("not confirmed", { timeout: 60_000 });
  expect(readTracker().tasks.length).toBeGreaterThan(0);
  await closeApp(app);
});

test("workstation: status, IDEs and features load; every action shows its command, previews first and applies only after authorization (#577)", async () => {
  const app = await launch({ repo: fixture.checkout });
  const { page } = app;
  const launcher = path.join(fixture.checkout, ".secondbrain", "run-tasks.ps1");
  const hadLauncher = fs.existsSync(launcher);
  await page.locator('.steps button[data-tab="workstation"]').click();
  await expect(page.locator("#ws-summary")).toContainText(/Workstation (not )?activated/, { timeout: 60_000 });
  // Check: the exact command is shown first; it is read-only, so there is no Apply or authorization.
  await page.locator('#ws-upkeep button[data-upkeep="check"]').click();
  await expect(page.locator("#ws-command")).toHaveText("pwsh -NoProfile -File scripts/secondbrain.ps1 -Check");
  await expect(page.locator("#ws-apply")).toBeHidden();
  // Launcher: command first, Apply disabled until a preview ran and the exact command is authorized.
  await page.locator('#ws-upkeep button[data-upkeep="launcher"]').click();
  await expect(page.locator("#ws-command")).toContainText("scripts/install-task-launcher.ps1");
  await expect(page.locator("#ws-command")).not.toContainText("-Apply");
  await expect(page.locator("#ws-apply-command")).toContainText("-Apply");
  await expect(page.locator("#ws-apply")).toBeDisabled();
  await page.locator("#ws-authorize").check();
  await expect(page.locator("#ws-apply")).toBeDisabled();
  await page.locator("#ws-preview").click();
  await expect(page.locator("#ws-result")).toContainText("Preview, nothing written yet", { timeout: 60_000 });
  expect(fs.existsSync(launcher)).toBe(hadLauncher);
  await expect(page.locator("#ws-apply")).toBeEnabled();
  // Choosing another action drops the preview and the authorization.
  await page.locator('#ws-upkeep button[data-upkeep="sync"]').click();
  await expect(page.locator("#ws-apply")).toBeDisabled();
  await expect(page.locator("#ws-authorize")).not.toBeChecked();
  await expect(page.locator("#ws-command")).toHaveText("pwsh -NoProfile -File scripts/secondbrain.ps1 -Check");
  await expect(page.locator("#ws-apply-command")).toContainText("-Sync");
  // Apply is never clicked here: the scripts resolve the workstation's real configuration, so an apply would write outside the fixture.
  // The apply arguments are covered by the Rust test workstation_arguments.
  await page.locator('#ws-upkeep button[data-upkeep="launcher"]').click();
  await expect(page.locator("#ws-apply")).toBeDisabled();
  await expect(page.locator("#ws-result")).toBeHidden();
  expect(fs.existsSync(launcher)).toBe(hadLauncher);
  await closeApp(app);
});

test("tracker: the agent wizard validates each step, previews the definition and saves exactly that file (#623)", async () => {
  const app = await launch({ repo: fixture.checkout });
  const { page } = app;
  const file = path.join(fixture.dossier, "subagents", "e2e-reviewer.json");
  expect(fs.existsSync(file)).toBe(false);
  await page.locator('.steps button[data-tab="tracker"]').click();
  await expect(page.locator("#agw-box")).toBeVisible({ timeout: 60_000 });
  const next = page.locator("#agw-next");
  const error = page.locator("#agw-error");
  const stepVisible = (n: number) => expect(page.locator(`.agw-step[data-step="${n}"]`)).toBeVisible();
  // Step 1: an invalid name and an empty purpose keep the wizard on the step.
  await page.locator("#agw-template").selectOption("reviewer");
  await page.locator("#agw-name").fill("Bad Name");
  await next.click();
  await expect(error).toContainText("lowercase");
  await stepVisible(1);
  await page.locator("#agw-name").fill("e2e-reviewer");
  await next.click();
  await stepVisible(2);
  await next.click();
  // Step 3: a model needs a provider.
  await stepVisible(3);
  await page.locator("#agw-model").fill("opus");
  await next.click();
  await expect(error).toContainText("provider");
  await page.locator("#agw-provider").selectOption("claude");
  await next.click();
  // Step 4: a write tool without the write permission is refused.
  await stepVisible(4);
  await page.locator('#agw-tools input[value="submit_dossier_write"]').check();
  await next.click();
  await expect(error).toContainText("write permission");
  await page.locator('#agw-tools input[value="submit_dossier_write"]').uncheck();
  await next.click();
  await stepVisible(5);
  await page.locator("#agw-cards").fill("Not A Card");
  await next.click();
  await expect(error).toContainText("Cards");
  await page.locator("#agw-cards").fill("");
  await next.click();
  // Step 6: an object output needs a schema; the budget is required.
  await stepVisible(6);
  await page.locator("#agw-output").selectOption("object");
  await next.click();
  await expect(error).toContainText("schema");
  await page.locator("#agw-output").selectOption("report");
  await page.locator("#agw-turns").fill("0");
  await next.click();
  await expect(error).toContainText("Turns");
  await page.locator("#agw-turns").fill("12");
  await next.click();
  await stepVisible(7);
  await expect(page.locator("#agw-save")).toBeDisabled();
  await page.locator("#agw-preview").click();
  await expect(page.locator("#agw-plan")).toContainText("e2e-reviewer", { timeout: 60_000 });
  expect(fs.existsSync(file)).toBe(false);
  await expect(page.locator("#agw-save")).toBeEnabled();
  const shown = JSON.parse((await page.locator("#agw-plan").textContent())!.split("\n").slice(1).join("\n"));
  expect(shown.id).toMatch(/^agt-[0-9a-f]{8}$/);
  // Going back and changing a value invalidates the preview.
  await page.locator("#agw-back").click();
  await page.locator("#agw-turns").fill("13");
  await expect(page.locator("#agw-save")).toBeHidden();
  await next.click();
  await expect(page.locator("#agw-save")).toBeDisabled();
  await page.locator("#agw-preview").click();
  await expect(page.locator("#agw-save")).toBeEnabled({ timeout: 60_000 });
  const reviewed = JSON.parse((await page.locator("#agw-plan").textContent())!.split("\n").slice(1).join("\n"));
  expect(reviewed.bounds.budget.turns).toBe(13);
  await page.locator("#agw-save").click();
  await expect(page.locator("#agw-plan")).toContainText("Saved exactly as previewed", { timeout: 60_000 });
  // The saved file is the previewed definition.
  expect(JSON.parse(fs.readFileSync(file, "utf8"))).toEqual(reviewed);
  expect(reviewed.model).toEqual({ provider: "claude", name: "opus" });
  await closeApp(app);
});

// #598: one screenshot of every tab on the synthetic fixture, taken only when SB_E2E_SHOTS names an output folder. Everything that can show a
// local path (inputs, monospace values, definition lists, the recent list) is masked, so the images hold synthetic task data only.
test("prompts: the tab lists system prompts read-only, validates the RCTFE wizard, previews the composed prompt, saves and deletes a user prompt (#722)", async () => {
  const app = await launch({ repo: fixture.checkout });
  const { page } = app;
  const store = path.join(fixture.brain, ".runtime", "user-prompts");
  const files = () => (fs.existsSync(store) ? fs.readdirSync(store, { recursive: true }).filter((f) => String(f).endsWith(".json")) : []);
  expect(files().length).toBe(0);
  await page.locator('.steps button[data-tab="prompts"]').click();
  // System prompts are listed with View only; defaults can be viewed and duplicated.
  await expect(page.locator("#pr-system tr").first()).toBeVisible({ timeout: 60_000 });
  await expect(page.locator("#pr-system button", { hasText: /delete|duplicate/i })).toHaveCount(0);
  await expect(page.locator("#pr-mine-empty")).toBeVisible();
  // The wizard refuses an incomplete form without calling the script.
  await page.locator("#pr-new").click();
  await page.locator("#pr-title").fill("E2E review");
  await page.locator("#pr-preview-btn").click();
  await expect(page.locator("#pr-problems")).toContainText("Role is empty");
  await expect(page.locator("#pr-save")).toBeDisabled();
  await page.locator("#pr-role").fill("You are a careful reviewer.");
  await page.locator("#pr-context").fill("Use before a merge.");
  await page.locator("#pr-task").fill("1. Read the diff.");
  await page.locator("#pr-format").fill("A list of findings.");
  await page.locator("#pr-directive").fill("Keep it short.");
  await page.locator("#pr-preview-btn").click();
  await expect(page.locator("#pr-problems")).toContainText("two numbered steps");
  await page.locator("#pr-task").fill("1. Read the diff.\n2. Report findings.");
  await page.locator("#pr-preview-btn").click();
  await expect(page.locator("#pr-preview")).toContainText("Directive: Keep it short.");
  await expect(page.locator("#pr-budget")).toContainText("of 3500 characters");
  await expect(page.locator("#pr-save")).toBeEnabled();
  // An edit after the preview invalidates it.
  await page.locator("#pr-format").fill("A short list of findings.");
  await expect(page.locator("#pr-save")).toBeDisabled();
  await page.locator("#pr-preview-btn").click();
  await page.locator("#pr-save").click();
  await expect(page.locator("#pr-mine tr")).toHaveCount(1, { timeout: 60_000 });
  await expect(page.locator("#pr-mine")).toContainText("E2E review");
  expect(files().length).toBe(1);
  // Delete: confirmed, the file is gone.
  page.once("dialog", (d) => void d.accept());
  await page.locator("#pr-mine button", { hasText: "Delete" }).click();
  await expect(page.locator("#pr-mine tr")).toHaveCount(0, { timeout: 60_000 });
  expect(files().length).toBe(0);
  await closeApp(app);
});

test("screenshots of every tab with synthetic data (only with SB_E2E_SHOTS)", async () => {
  const out = process.env.SB_E2E_SHOTS;
  test.skip(!out, "SB_E2E_SHOTS not set");
  fs.mkdirSync(out!, { recursive: true });
  const app = await launch({ repo: fixture.checkout });
  const { page } = app;
  await page.setViewportSize({ width: 1180, height: 820 });
  await expect(page.locator('.steps button[data-tab="queue"]')).toBeEnabled({ timeout: 60_000 });
  await page.waitForTimeout(3_000);
  const masks = () => [page.locator("input"), page.locator(".mono"), page.locator("dd"), page.locator("#repo-info"), page.locator("#recent"), page.locator("code"), page.locator("#repo-tracker"), page.locator("#run-folder")];
  for (const tab of ["repo", "directives", "queue", "run", "registry", "tracker", "settings"]) {
    await page.locator(`.steps button[data-tab="${tab}"]`).click();
    if (tab === "registry") await expect(page.locator("#reg-rows tr").first()).toBeVisible({ timeout: 60_000 });
    if (tab === "tracker") await expect(page.locator("#trk-rows tr").first()).toBeVisible({ timeout: 60_000 });
    await page.waitForTimeout(500);
    await page.screenshot({ path: path.join(out!, `${tab}.png`), mask: masks(), maskColor: "#cfd4da" });
  }
  await closeApp(app);
});
