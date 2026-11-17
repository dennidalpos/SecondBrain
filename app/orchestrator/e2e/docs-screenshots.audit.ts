// Documentation screenshots of Run, Settings and the waiting-decision dialog (#687) on the synthetic fixture.
// The run folder shows the workstation ID (hosts/ws-...), which on a real machine derives from its name and SID. Before each capture every
// ws-<16 hex> in the page (text and input values) is replaced by a fixture host ID, so no real ID reaches an image.
// Run: SB_E2E_FIXTURE=<fixture.json> SB_AUDIT_OUT=<folder> npx --no-install playwright test -c e2e/playwright.audit.config.ts docs-screenshots
import { test, chromium, type Browser, type Page } from "@playwright/test";
import { spawn, type ChildProcess } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import * as net from "node:net";

interface Fixture { brain: string; checkout: string; identity: string; tracker: string; dossier: string; bin: string; configDir: string; binary: string; webviewData: string }
const fixture: Fixture = JSON.parse(fs.readFileSync(process.env.SB_E2E_FIXTURE ?? "", "utf8"));
const out = process.env.SB_AUDIT_OUT ?? "audit-out";
fs.mkdirSync(out, { recursive: true });
const FIXTURE_HOST_ID = "ws-0123456789abcdef";

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
async function launch(agentSeconds: number): Promise<App> {
  const port = await freePort();
  const proc = spawn(fixture.binary, ["--repo", fixture.checkout], {
    cwd: fixture.brain,
    env: {
      ...process.env, PATH: isolatedPath(), SECONDBRAIN_HOME: fixture.brain, SECONDBRAIN_BRAIN_ROOT: fixture.brain, SECONDBRAIN_ORCHESTRATOR_CONFIG_DIR: fixture.configDir,
      SECONDBRAIN_AGENT_SEARCH_ONLY: "1", SECONDBRAIN_AGENT_SEARCH_PATH: fixture.bin, SB_E2E_BRAIN: fixture.brain,
      SB_E2E_AGENT_SECONDS: String(agentSeconds), WEBVIEW2_USER_DATA_FOLDER: fixture.webviewData,
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
  await app.page.evaluate(() => (window as unknown as { sbOrchestrator: { requestClose: () => void } }).sbOrchestrator.requestClose()).catch(() => {});
  const code = await Promise.race([app.exited, new Promise<"timeout">((r) => setTimeout(() => r("timeout"), 15_000))]);
  if (code === "timeout") app.proc.kill();
  await app.browser.close().catch(() => {});
}
// Replace every workstation ID in the rendered page, then check none is left, and take the screenshot.
async function shot(page: Page, name: string) {
  await page.waitForTimeout(500);
  const left = await page.evaluate((fake) => {
    const re = /ws-[0-9a-f]{16}/g;
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) n.nodeValue = (n.nodeValue ?? "").replace(re, fake);
    document.querySelectorAll("input,textarea").forEach((e) => { const i = e as HTMLInputElement; i.value = i.value.replace(re, fake); });
    return (document.body.innerText + Array.from(document.querySelectorAll("input,textarea")).map((e) => (e as HTMLInputElement).value).join(" ")).match(re)?.filter((m) => m !== fake).length ?? 0;
  }, FIXTURE_HOST_ID);
  if (left) throw new Error(`workstation ID still visible in ${name}`);
  await page.screenshot({ path: path.join(out, name + ".png") });
}
async function tab(page: Page, name: string) { await page.locator(`.steps button[data-tab="${name}"]`).click(); }

test("Run, Settings and waiting decision", async () => {
  fs.mkdirSync(fixture.configDir, { recursive: true });
  fs.writeFileSync(path.join(fixture.configDir, "settings.json"), JSON.stringify({ secondbrainHome: "", pwshPath: "", recentRepos: [] }));
  const app = await launch(4);
  const { page } = app;
  const row = page.locator("#q-skipped tr").filter({ hasText: "E2E-4" });
  await page.locator("#repo-label").filter({ hasText: "orchestrator-e2e" }).waitFor({ timeout: 90_000 }).catch(async () => {
    await tab(page, "repo");
    throw new Error("repository not loaded: " + (await page.locator("#tab-repo").innerText()).slice(0, 800));
  });
  await tab(page, "queue");
  await row.waitFor({ timeout: 120_000 });
  await page.locator("#q-agents label.agent").nth(2).waitFor({ timeout: 120_000 });
  // Waiting decision: the question from the analysis of the task that cannot run alone.
  await row.locator("button", { hasText: "Analyze" }).click();
  await page.locator("#an-dialog").waitFor({ state: "visible", timeout: 120_000 });
  await shot(page, "orchestrator-decision");
  await page.locator("#an-close").click();
  // Run: start one task and capture the finished run.
  await page.locator("#q-tasks tr").filter({ hasText: "E2E-1" }).locator('input[type="checkbox"]').check();
  await page.locator("#q-start").click();
  await page.locator("#run-verdict").filter({ hasText: "Finished" }).waitFor({ timeout: 180_000 });
  await shot(page, "orchestrator-run");
  // Settings: show only generic values, never the workstation's own paths.
  await tab(page, "settings");
  await page.locator("#s-home").fill("C:\\SecondBrain");
  await page.locator("#s-pwsh").fill("C:\\Program Files\\PowerShell\\7\\pwsh.exe");
  await shot(page, "orchestrator-settings");
  await closeApp(app);
});
