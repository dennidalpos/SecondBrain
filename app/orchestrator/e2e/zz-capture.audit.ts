// Temporary capture helper (removed after use).
import { test, chromium, type Browser, type Page } from "@playwright/test";
import { spawn, type ChildProcess } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import * as net from "node:net";

interface Fixture { brain: string; checkout: string; identity: string; tracker: string; dossier: string; bin: string; configDir: string; binary: string; webviewData: string }
const fixture: Fixture = JSON.parse(fs.readFileSync(process.env.SB_E2E_FIXTURE ?? "", "utf8"));
const out = process.env.SB_AUDIT_OUT ?? "audit-out";
fs.mkdirSync(out, { recursive: true });
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
async function launch(repo: string): Promise<App> {
  const port = await freePort();
  const proc = spawn(fixture.binary, ["--repo", repo], {
    cwd: fixture.brain,
    env: {
      ...process.env, PATH: isolatedPath(), SECONDBRAIN_HOME: fixture.brain, SECONDBRAIN_ORCHESTRATOR_CONFIG_DIR: fixture.configDir,
      SECONDBRAIN_AGENT_SEARCH_ONLY: "1", SECONDBRAIN_AGENT_SEARCH_PATH: fixture.bin, SB_E2E_BRAIN: fixture.brain,
      SB_E2E_AGENT_SECONDS: "3", WEBVIEW2_USER_DATA_FOLDER: fixture.webviewData,
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
async function tab(page: Page, name: string) { await page.locator(`.steps button[data-tab="${name}"]`).click(); }

test("capture queue and tracker", async () => {
  fs.mkdirSync(fixture.configDir, { recursive: true });
  fs.writeFileSync(path.join(fixture.configDir, "settings.json"), JSON.stringify({ secondbrainHome: "", pwshPath: "", recentRepos: [] }));
  const app = await launch(fixture.checkout);
  const { page } = app;
  await page.waitForTimeout(15_000);
  console.log("LABEL", await page.locator("#repo-label").textContent());
  console.log("TAB", await page.locator('.steps button[aria-selected="true"]').textContent());
  await page.locator('.steps button[data-tab="repo"]').click();
  console.log("BODY", (await page.locator("#tab-repo").innerText()).slice(0, 1500));
  await tab(page, "queue");
  await page.locator("#q-tasks tr").first().waitFor({ timeout: 120_000 });
  await page.locator("#q-agents label.agent").nth(2).waitFor({ timeout: 120_000 });
  await page.waitForTimeout(500);
  await page.screenshot({ path: path.join(out, "02-normal-queue.png") });
  await tab(page, "tracker");
  await page.locator("#trk-rows tr").first().waitFor({ timeout: 60_000 });
  await page.waitForTimeout(500);
  await page.screenshot({ path: path.join(out, "02-normal-tracker.png") });
  app.proc.kill();
});
