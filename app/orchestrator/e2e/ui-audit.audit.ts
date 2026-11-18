// Visual UI/UX audit (G01): drives the real orchestrator binary on the synthetic fixture and saves screenshots of six situations:
// first run, normal operation, waiting decisions, errors, long queues and historical runs. Also records layout facts in findings.json.
// Only synthetic data; the fixture lives in a neutral folder so no personal path appears in the images.
import { test, chromium, type Browser, type Page } from "@playwright/test";
import { spawn, type ChildProcess } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import * as net from "node:net";

interface Fixture { brain: string; checkout: string; identity: string; tracker: string; dossier: string; bin: string; configDir: string; binary: string; webviewData: string }
const fixture: Fixture = JSON.parse(fs.readFileSync(process.env.SB_E2E_FIXTURE ?? "", "utf8"));
const out = process.env.SB_AUDIT_OUT ?? "audit-out";
fs.mkdirSync(out, { recursive: true });
const facts: Record<string, unknown> = {};

interface App { proc: ChildProcess; browser: Browser; page: Page; exited: Promise<number | null> }

async function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.listen(0, "127.0.0.1", () => { const p = (srv.address() as net.AddressInfo).port; srv.close(() => resolve(p)); });
    srv.on("error", reject);
  });
}
function isolatedPath(): string {
  const names = ["claude.exe", "claude.cmd", "claude", "codex.exe", "codex.cmd", "codex", "gemini.exe", "gemini.cmd", "gemini"];
  const dirs = (process.env.PATH ?? "").split(path.delimiter).filter((d) => d && !names.some((n) => fs.existsSync(path.join(d, n))));
  return [fixture.bin, ...dirs].join(path.delimiter);
}
async function launch(opts: { repo?: string; agentSeconds?: number } = {}): Promise<App> {
  const port = await freePort();
  const proc = spawn(fixture.binary, opts.repo ? ["--repo", opts.repo] : [], {
    cwd: fixture.brain,
    env: {
      ...process.env, PATH: isolatedPath(), SECONDBRAIN_HOME: fixture.brain, SECONDBRAIN_BRAIN_ROOT: fixture.brain, SECONDBRAIN_ORCHESTRATOR_CONFIG_DIR: fixture.configDir,
      SECONDBRAIN_AGENT_SEARCH_ONLY: "1", SECONDBRAIN_AGENT_SEARCH_PATH: fixture.bin, SB_E2E_BRAIN: fixture.brain,
      SB_E2E_AGENT_SECONDS: String(opts.agentSeconds ?? 2), WEBVIEW2_USER_DATA_FOLDER: fixture.webviewData,
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
  if (!browser) { proc.kill(); throw new Error("DevTools endpoint not reachable"); }
  let page: Page | undefined;
  while (!page && Date.now() < deadline) {
    page = browser.contexts().flatMap((c) => c.pages()).find((p) => !p.url().startsWith("devtools:"));
    if (!page) await new Promise((r) => setTimeout(r, 300));
  }
  if (!page) throw new Error("page not found");
  page.on("dialog", (d) => d.accept());
  await page.waitForSelector("#repo-path", { state: "attached" });
  return { proc, browser, page, exited };
}
async function closeApp(app: App) {
  await app.page.evaluate(() => (window as unknown as { sbOrchestrator: { requestQuit: () => void } }).sbOrchestrator.requestQuit()).catch(() => {});
  const code = await Promise.race([app.exited, new Promise<"timeout">((r) => setTimeout(() => r("timeout"), 15_000))]);
  if (code === "timeout") app.proc.kill();
  await app.browser.close().catch(() => {});
}
async function shot(page: Page, name: string) {
  await page.waitForTimeout(500);
  await page.screenshot({ path: path.join(out, name + ".png") });
  // Layout facts of this view: viewport, horizontal overflow, focusable elements without an accessible name, small click targets.
  facts[name] = await page.evaluate(() => {
    const vis = (e: Element) => { const r = (e as HTMLElement).getBoundingClientRect(); return r.width > 0 && r.height > 0; };
    const ctrls = Array.from(document.querySelectorAll("button,input,select,textarea,a[href]")).filter(vis) as HTMLElement[];
    const noName = ctrls.filter((e) => !(e.getAttribute("aria-label") || e.textContent?.trim() || (e as HTMLInputElement).labels?.length || e.getAttribute("title"))).length;
    const small = ctrls.filter((e) => { const r = e.getBoundingClientRect(); return r.height < 24 || r.width < 24; }).length;
    return { viewport: [innerWidth, innerHeight], hScroll: document.documentElement.scrollWidth > innerWidth, vScrollPx: document.documentElement.scrollHeight - innerHeight,
      visibleControls: ctrls.length, controlsWithoutName: noName, targetsUnder24px: small, tabs: Array.from(document.querySelectorAll(".steps button")).map((b) => (b as HTMLButtonElement).textContent!.trim() + (b.hasAttribute("disabled") ? " (disabled)" : "")) };
  });
}
async function tab(page: Page, name: string) { await page.locator(`.steps button[data-tab="${name}"]`).click(); }

test.afterAll(() => { fs.writeFileSync(path.join(out, "findings.json"), JSON.stringify(facts, null, 2)); });

test("1 first run: no repository, no recent entries", async () => {
  fs.mkdirSync(fixture.configDir, { recursive: true });
  fs.writeFileSync(path.join(fixture.configDir, "settings.json"), JSON.stringify({ secondbrainHome: "", pwshPath: "", recentRepos: [] }));
  const app = await launch();
  await shot(app.page, "01-first-run-repository");
  await tab(app.page, "settings");
  await shot(app.page, "01-first-run-settings");
  await tab(app.page, "tracker");
  await shot(app.page, "01-first-run-tracker-no-repo");
  await app.page.setViewportSize({ width: 1024, height: 768 });
  await tab(app.page, "repo");
  await shot(app.page, "01-first-run-repository-1024x768");
  await closeApp(app);
});

test("2 normal operation: queue, directives, registry, tracker", async () => {
  const app = await launch({ repo: fixture.checkout });
  const { page } = app;
  await page.waitForTimeout(20_000); console.log("DBG", await page.locator("#repo-label").textContent(), await page.locator("#repo-info").textContent(), await page.locator("#status-line, #repo-error, .error").allTextContents());
  await page.locator("#q-tasks tr").first().waitFor({ timeout: 240_000 });
  await page.locator("#q-agents label.agent").nth(2).waitFor({ timeout: 240_000 });
  await shot(page, "02-normal-queue");
  await tab(page, "directives");
  await page.waitForTimeout(10_000);
  await shot(page, "02-normal-directives");
  await tab(page, "registry");
  await page.locator("#reg-rows tr.reg-row").first().waitFor({ timeout: 60_000 });
  await shot(page, "02-normal-registry");
  await tab(page, "tracker");
  await page.locator("#trk-rows tr").first().waitFor({ timeout: 60_000 });
  await shot(page, "02-normal-tracker");
  await tab(page, "queue");
  await page.setViewportSize({ width: 1024, height: 768 });
  await shot(page, "02-normal-queue-1024x768");
  // 200% zoom equivalent at 1024x768: a 512x384 CSS viewport.
  await page.setViewportSize({ width: 512, height: 384 });
  await shot(page, "02-normal-queue-200pct-zoom");
  await closeApp(app);
});

test("3 waiting decisions: question from the analysis, pending acceptance, run in progress", async () => {
  const app = await launch({ repo: fixture.checkout, agentSeconds: 12 });
  const { page } = app;
  const row = page.locator("#q-skipped tr").filter({ hasText: "E2E-4" });
  await row.waitFor({ timeout: 60_000 });
  await shot(page, "03-waiting-skipped-task-in-queue");
  await row.locator("button", { hasText: "Analyze" }).click();
  await page.locator("#an-dialog").waitFor({ state: "visible", timeout: 120_000 });
  await shot(page, "03-waiting-decision-question");
  await page.locator("#an-dialog label.choice").first().locator("input").check();
  await shot(page, "03-waiting-decision-answered");
  await page.locator("#an-close").click();
  // A run in progress with the agent still working: what the owner sees while waiting.
  await page.locator("#q-tasks tr").filter({ hasText: "E2E-1" }).locator('input[type="checkbox"]').check();
  await page.locator("#q-start").click();
  await page.locator("#run-steps").filter({ hasText: "Read: README.md" }).waitFor({ timeout: 60_000 });
  await shot(page, "03-waiting-run-in-progress");
  await page.locator("#run-verdict").filter({ hasText: "Finished" }).waitFor({ timeout: 120_000 });
  await shot(page, "03-waiting-run-finished-acceptance-open");
  await closeApp(app);
});

test("4 errors: unknown repository, unreadable folder", async () => {
  const app = await launch();
  const { page } = app;
  await page.locator("#repo-path").fill(path.join(path.dirname(fixture.checkout), "does-not-exist"));
  await page.locator("#repo-load").click();
  await page.waitForTimeout(4000);
  await shot(page, "04-error-missing-path");
  await page.locator("#repo-path").fill(fixture.brain);
  await page.locator("#repo-load").click();
  await page.waitForTimeout(4000);
  await shot(page, "04-error-not-a-checkout");
  await closeApp(app);
});

test("5 long queue: 60 ready tasks", async () => {
  const tracker = JSON.parse(fs.readFileSync(fixture.tracker, "utf8"));
  const base = tracker.tasks.find((t: { id: string }) => t.id === "E2E-1");
  const have = tracker.tasks.some((t: { id: string }) => t.id === "E2E-L1");
  let seq = tracker.extensions.lastSeq;
  for (let i = 0; i < (have ? 0 : 57); i++) {
    seq++;
    const t = JSON.parse(JSON.stringify(base));
    t.id = `E2E-L${i + 1}`; t.seq = seq; t.priority = ["P1", "P2", "P3"][i % 3]; t.status = "todo";
    t.title = `#${String(seq).padStart(3, "0")} — Synthetic task with a deliberately long title to test wrapping in the queue table, item ${i + 1}`;
    tracker.tasks.push(t);
  }
  tracker.extensions.lastSeq = seq;
  fs.writeFileSync(fixture.tracker, JSON.stringify(tracker, null, 2));
  const app = await launch({ repo: fixture.checkout });
  const { page } = app;
  const t0 = Date.now();
  await page.locator("#q-tasks tr").first().waitFor({ timeout: 280_000 });
  facts["queue-first-row-seconds"] = Math.round((Date.now() - t0) / 1000);
  await page.waitForTimeout(3000);
  facts["queue-rows"] = await page.locator("#q-tasks tr").count();
  await shot(page, "05-long-queue-top");
  await page.locator("#q-start").scrollIntoViewIfNeeded();
  await shot(page, "05-long-queue-start-button");
  await tab(page, "registry");
  await page.locator("#reg-rows tr.reg-row").nth(40).waitFor({ timeout: 90_000 });
  await shot(page, "05-long-registry");
  await tab(page, "tracker");
  await page.locator("#trk-rows tr").nth(40).waitFor({ timeout: 90_000 });
  await shot(page, "05-long-tracker");
  await closeApp(app);
});

test("6 historical runs: registry run history", async () => {
  const app = await launch({ repo: fixture.checkout });
  const { page } = app;
  await tab(page, "registry");
  await page.locator("#reg-rows tr.reg-row").first().waitFor({ timeout: 60_000 });
  await page.locator('[data-reg-view="runs"]').click();
  await page.locator("#reg-run-rows tr").first().waitFor({ timeout: 60_000 });
  await shot(page, "06-history-runs");
  await page.locator("#reg-run-rows tr").first().click();
  await shot(page, "06-history-run-selected");
  await page.locator('[data-reg-view="tasks"]').click().catch(() => {});
  await page.locator("#reg-rows tr.reg-row").first().click();
  await shot(page, "06-history-task-runs");
  await closeApp(app);
});
