// Usability and accessibility audit (G10, WCAG 2.2): keyboard-only path through every panel, visible focus, status labels and
// layouts at 1024x768 and 200% zoom (a 512x384 CSS viewport). Same fixture and launch as ui-audit.audit.ts; synthetic data only.
// Run: SB_E2E_FIXTURE=<fixture.json> SB_AUDIT_OUT=<folder> npx --no-install playwright test -c e2e/playwright.audit.config.ts a11y
import { test, expect, chromium, type Browser, type Page } from "@playwright/test";
import { spawn, type ChildProcess } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import * as net from "node:net";

interface Fixture { brain: string; checkout: string; bin: string; configDir: string; binary: string; webviewData: string }
const fixture: Fixture = JSON.parse(fs.readFileSync(process.env.SB_E2E_FIXTURE ?? "", "utf8"));
const out = path.join(process.env.SB_AUDIT_OUT ?? "audit-out", "a11y");
fs.mkdirSync(out, { recursive: true });
const facts: Record<string, unknown> = {};
const SECTIONS = ["home", "repo", "workstation", "directives", "queue", "run", "registry", "tracker", "settings"];

async function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.listen(0, "127.0.0.1", () => { const p = (srv.address() as net.AddressInfo).port; srv.close(() => resolve(p)); });
    srv.on("error", reject);
  });
}
async function launch(): Promise<{ proc: ChildProcess; browser: Browser; page: Page }> {
  const port = await freePort();
  const proc = spawn(fixture.binary, ["--repo", fixture.checkout], {
    cwd: fixture.brain,
    env: { ...process.env, PATH: [fixture.bin, process.env.PATH ?? ""].join(path.delimiter), SECONDBRAIN_HOME: fixture.brain, SECONDBRAIN_BRAIN_ROOT: fixture.brain,
      SECONDBRAIN_ORCHESTRATOR_CONFIG_DIR: fixture.configDir, SECONDBRAIN_AGENT_SEARCH_ONLY: "1", SECONDBRAIN_AGENT_SEARCH_PATH: fixture.bin,
      WEBVIEW2_USER_DATA_FOLDER: fixture.webviewData, WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS: `--remote-debugging-port=${port}` },
    stdio: "ignore",
  });
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
  await page.waitForSelector("#repo-path", { state: "attached" });
  return { proc, browser, page };
}

test.afterAll(() => { fs.writeFileSync(path.join(out, "findings.json"), JSON.stringify(facts, null, 2)); });

test("keyboard-only path, visible focus, status labels, layouts", async () => {
  const { proc, browser, page } = await launch();
  try {
    await page.setViewportSize({ width: 1024, height: 768 });
    // Keyboard only: the tab list takes one Tab stop; arrow keys move between sections; Tab enters the panel.
    await page.locator("#tabbtn-home").focus();
    for (let i = 0; i < SECTIONS.length; i++) {
      const name = SECTIONS[i];
      await expect(page.locator(`#tab-${name}`)).toBeVisible();
      await expect(page.locator(`#tabbtn-${name}`)).toBeFocused();
      const focusStyle = await page.evaluate(() => { const s = getComputedStyle(document.activeElement!); return { outlineWidth: s.outlineWidth, outlineStyle: s.outlineStyle }; });
      expect(focusStyle.outlineStyle).not.toBe("none");
      // Every panel: Tab reaches a control inside the panel, then Shift+Tab returns to the tab list.
      await page.keyboard.press("Tab");
      const inside = await page.evaluate((n) => document.getElementById("tab-" + n)!.contains(document.activeElement), name);
      const reachable = await page.evaluate((n) => document.getElementById("tab-" + n)!.querySelectorAll("button:not([disabled]),input,select,textarea,summary,[tabindex='0']").length, name);
      facts[`${name}-keyboard`] = { tabEntersPanel: inside, focusableControls: reachable, hScroll: await page.evaluate(() => document.documentElement.scrollWidth > innerWidth) };
      if (reachable > 0) expect(inside).toBe(true);
      await page.keyboard.press("Shift+Tab");
      await expect(page.locator(`#tabbtn-${name}`)).toBeFocused();
      await page.screenshot({ path: path.join(out, `${String(i + 1).padStart(2, "0")}-${name}-1024x768.png`) });
      await page.keyboard.press("ArrowRight");
    }
    await page.keyboard.press("Home");
    await expect(page.locator("#tab-home")).toBeVisible();
    await page.keyboard.press("End");
    await expect(page.locator("#tab-settings")).toBeVisible();
    // Status labels: the run badge is a named status region with visible text.
    const badge = await page.locator("#run-badge").evaluate((e) => ({ role: e.getAttribute("role"), label: e.getAttribute("aria-label"), text: e.textContent?.trim() }));
    facts["run-badge"] = badge;
    expect(badge.role).toBe("status");
    expect(badge.text).toBeTruthy();
    // 200% zoom equivalent: a 512x384 CSS viewport; no horizontal page scroll in any section.
    await page.setViewportSize({ width: 512, height: 384 });
    for (let i = 0; i < SECTIONS.length; i++) {
      await page.locator(`#tabbtn-${SECTIONS[i]}`).click();
      await page.waitForTimeout(300);
      const hScroll = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth);
      facts[`${SECTIONS[i]}-200pct-hScroll`] = hScroll;
      expect(hScroll).toBe(false);
      await page.screenshot({ path: path.join(out, `${String(i + 1).padStart(2, "0")}-${SECTIONS[i]}-200pct-zoom.png`) });
    }
  } finally {
    proc.kill();
    await browser.close().catch(() => {});
  }
});
