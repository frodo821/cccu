// Chrome を専用プロファイルで起動し、BrowserBackend をフィクスチャページに対して検証する。
// Chrome が無ければスキップ。CCCU_TEST_CDP_URL を指定すると既存インスタンスを使う。
import { test, expect, beforeAll, afterAll, describe } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { BrowserBackend, DEFAULT_BROWSER_NOTIFICATIONS } from "../src/backends/browser/BrowserBackend.js";
import { readFileSync } from "node:fs";
import { parseRef } from "../src/core/refs.js";

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const PORT = 9333;
const fixture = "file://" + resolve(import.meta.dir, "fixtures/form.html");

let chrome: ChildProcess | null = null;
let httpServer: ReturnType<typeof Bun.serve> | null = null;
let httpPort = 0;
let profile = "";
let backend: BrowserBackend;
let tab = "";
const haveChrome = existsSync(CHROME) || !!process.env.CCCU_TEST_CDP_URL;

const refOf = (r: { snapshot: string; text: string }, needle: string) => {
  const line = r.text.split("\n").find((l) => l.includes(needle) && l.includes("[ref="));
  if (!line) throw new Error(`no line with ${needle} in:\n${r.text}`);
  return parseRef(`${r.snapshot}/${line.split("[ref=")[1].split("]")[0]}`);
};

beforeAll(async () => {
  if (!haveChrome) return;
  let cdpUrl = process.env.CCCU_TEST_CDP_URL;
  if (!cdpUrl) {
    profile = mkdtempSync(join(tmpdir(), "cccu-chrome-"));
    chrome = spawn(CHROME, [`--remote-debugging-port=${PORT}`, `--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check", "--headless=new", "about:blank"], { stdio: "ignore" });
    cdpUrl = `http://127.0.0.1:${PORT}`;
    for (let i = 0; i < 50; i++) {
      try { await fetch(`${cdpUrl}/json/version`); break; } catch { await new Promise((r) => setTimeout(r, 100)); }
    }
  }
  backend = new BrowserBackend({ cdpUrl });
  const line = await backend.navigate("new", fixture);
  tab = line.split("\t")[0];

  // iframe フィクスチャ用: localhost で配信し、__CROSS__ は 127.0.0.1 (別サイト → OOPIF) にする
  httpServer = Bun.serve({
    port: 0,
    fetch(req) {
      const path = new URL(req.url).pathname;
      const file = resolve(import.meta.dir, "fixtures" + (path === "/" ? "/frames.html" : path));
      try {
        const body = readFileSync(file, "utf8").replace("__CROSS__", `http://127.0.0.1:${httpPort}`);
        return new Response(body, { headers: { "content-type": "text/html; charset=utf-8" } });
      } catch { return new Response("not found", { status: 404 }); }
    },
  });
  httpPort = httpServer.port!;
});

afterAll(async () => {
  await backend?.dispose();
  httpServer?.stop(true);
  chrome?.kill();
  if (profile) rmSync(profile, { recursive: true, force: true });
});

describe.skipIf(!haveChrome)("BrowserBackend", () => {
  test("lists the tab", async () => {
    const targets = await backend.listTargets();
    expect(targets.some((t) => t.id === tab && t.title === "cccu fixture")).toBe(true);
  });

  test("snapshot has refs for form controls and text for static content", async () => {
    const s = await backend.snapshot(tab);
    expect(s.snapshot).toMatch(/^b\d+$/);
    expect(s.text).toContain('heading[h1] "Sign up"');
    expect(s.text).toMatch(/textbox "Name" \[ref=e\d+\]/);
    expect(s.text).toMatch(/combobox "Plan" \[ref=e\d+\]/);
    expect(s.text).toMatch(/checkbox "I agree" \[ref=e\d+\] \[unchecked\]/);
    expect(s.text).toMatch(/button "Create account" \[ref=e\d+\]/);
    expect(s.text).not.toContain("generic");
    expect(s.text).not.toContain("Panel content");   // hidden
  });

  test("find prunes to matches with ancestors", async () => {
    const f = await backend.find(tab, { role: "button", title: "toggle" });
    expect(f.text.split("\n").filter((l) => l.includes("button")).length).toBe(1);   // 祖先 (webarea) の ref は残る
    expect(f.text).toContain('button "Toggle panel"');
    expect(f.text).not.toContain("Create account");
    expect(f.text).not.toContain("ignored");
    const links = await backend.find(tab, { role: "link" });
    expect(links.text).toBe("");   // dialog is hidden → no links
    await backend.click(refOf(await backend.snapshot(tab), 'button "Toggle panel"'), {});
    const shown = await backend.find(tab, { role: "link" });
    expect(shown.text.split("\n").filter((l) => l.includes("Top link")).length).toBe(1);   // 冗長な text 子は出ない
    await backend.click(refOf(await backend.snapshot(tab), 'button "Toggle panel"'), {});
  });

  test("type, setValue, click submit, read result", async () => {
    const s = await backend.snapshot(tab);
    expect(await backend.type(refOf(s, 'textbox "Name"'), "Ada", { clear: true })).toBe("insertText");
    await backend.setValue(refOf(s, 'combobox "Plan"'), "pro");
    await backend.setValue(refOf(s, 'checkbox "I agree"'), true);
    await backend.click(refOf(s, 'button "Create account"'), {});
    const r = await backend.waitFor(tab, { exists: { title: "submitted:" } }, 3000);
    expect(r.text).toContain("submitted:Ada:pro:true");
    const attrs = await backend.attributes(refOf(s, 'checkbox "I agree"'));
    expect(attrs.checked).toBe(true);
    expect(attrs.tag).toBe("input");
  });

  test("click reveals dialog, wait gone after second click", async () => {
    const s = await backend.snapshot(tab);
    await backend.click(refOf(s, 'button "Toggle panel"'), {});
    const shown = await backend.waitFor(tab, { exists: { role: "dialog" } }, 3000);
    expect(shown.text).toContain('dialog "Details"');
    expect(shown.text).toContain('link "Top link"');
    await backend.click(refOf(s, 'button "Toggle panel"'), {});
    await backend.waitFor(tab, { gone: { role: "dialog" } }, 3000);
  });

  test("clicking an off-screen element scrolls it into view", async () => {
    const s = await backend.snapshot(tab);
    const far = refOf(s, 'button "Far away button"');
    await backend.click(far, {});
    const attrs = await backend.attributes(far);
    expect((attrs.rect as { y: number }).y).toBeLessThan(1000);
    expect(attrs.text).toBe("Far away clicked");   // スクロール後の座標でクリックが当たっている
  });

  test("key events reach the page", async () => {
    const s = await backend.snapshot(tab);
    const name = refOf(s, 'textbox "Name"');
    await backend.type(name, "abc", { clear: true });
    await backend.key(tab, "Backspace");
    await backend.key(tab, "a", ["cmd"]);
    await backend.key(tab, "Backspace");
    await backend.type(name, "z", {});
    expect((await backend.attributes(name)).value).toBe("z");
  });

  test("stale refs after navigation", async () => {
    const s = await backend.snapshot(tab);
    const btn = refOf(s, 'button "Toggle panel"');
    await backend.navigate(tab, "about:blank");
    await expect(backend.click(btn, {})).rejects.toMatchObject({ kind: "STALE_REF" });
    await backend.navigate(tab, "back");
    expect((await backend.snapshot(tab)).text).toContain("Sign up");
  });

  test("screenshot returns a PNG", async () => {
    const r = await backend.screenshot(tab);
    expect(Buffer.from(r.pngBase64, "base64").subarray(0, 4)).toEqual(Buffer.from([0x89, 0x50, 0x4e, 0x47]));
  });

  test("iframes: same-origin and cross-site frames are part of the snapshot and clickable", async () => {
    const line = await backend.navigate("new", `http://localhost:${httpPort}/frames.html`);
    const t2 = line.split("\t")[0];
    await backend.waitFor(t2, { exists: { title: "Inner cross" } }, 5000);   // OOPIF のアタッチを待つ
    const s = await backend.snapshot(t2);
    expect(s.text).toContain('iframe "Same-origin frame"');
    expect(s.text).toContain('iframe "Cross-site frame"');
    expect(s.text).toContain('heading[h2] "Inner same"');
    expect(s.text).toContain('heading[h2] "Inner cross"');

    // 同一オリジン: フィールドに入力 → ボタンをクリック → 親に postMessage が届く (座標が正しい証拠)
    const sameBlock = s.text.slice(s.text.indexOf('iframe "Same-origin frame"'), s.text.indexOf('iframe "Cross-site frame"'));
    const sameField = refOf({ snapshot: s.snapshot, text: sameBlock }, 'textbox "Inner field"');
    const sameBtn = refOf({ snapshot: s.snapshot, text: sameBlock }, 'button "Inner button"');
    await backend.type(sameField, "hello", { clear: true });
    await backend.click(sameBtn, {});
    const r1 = await backend.waitFor(t2, { exists: { title: "outer:same:hello" } }, 3000);
    expect(r1.text).toContain("outer:same:hello");
    expect((await backend.attributes(sameField)).frame).toBe("iframe");

    // クロスサイト (OOPIF): 座標はフレームの位置を足して変換される
    const crossBlock = s.text.slice(s.text.indexOf('iframe "Cross-site frame"'));
    const crossField = refOf({ snapshot: s.snapshot, text: crossBlock }, 'textbox "Inner field"');
    const crossBtn = refOf({ snapshot: s.snapshot, text: crossBlock }, 'button "Inner button"');
    await backend.type(crossField, "world", { clear: true });
    await backend.click(crossBtn, {});
    const r2 = await backend.waitFor(t2, { exists: { title: "outer:cross:world" } }, 3000);
    expect(r2.text).toContain("outer:cross:world");
    expect((await backend.attributes(crossField)).frame).toBe("oopif");

    // find もフレームを跨ぐ
    const f = await backend.find(t2, { role: "button", title: "Inner button" });
    expect(f.text.split("\n").filter((l) => l.includes('button "Inner button"')).length).toBe(2);
  });

  test("events: navigation, load, console, exception, dialogs, tabs; unobserve stops them", async () => {
    const line = await backend.navigate("new", "about:blank");
    const t3 = line.split("\t")[0];
    const { subscription, notifications } = await backend.observe(t3, [...DEFAULT_BROWSER_NOTIFICATIONS, "console"]);
    expect(subscription).toMatch(/^w\d+$/);
    expect(notifications).toContain("navigated");
    await expect(backend.observe(t3, ["nope"])).rejects.toMatchObject({ kind: "INVALID_PARAMS" });

    await backend.navigate(t3, fixture);
    const names = () => backend.events().map((e) => [e.notification, e.element.title] as const);
    const afterNav = names();
    expect(afterNav.some(([n, t]) => n === "navigated" && t === fixture)).toBe(true);
    expect(afterNav.some(([n]) => n === "loaded")).toBe(true);

    const s = await (backend as any).session(t3.slice(4));
    await (backend as any).send(s, "Runtime.evaluate", { expression: "console.error('bad thing'); console.log('plain'); setTimeout(() => { throw new Error('boom') }, 0)" });
    await new Promise((r) => setTimeout(r, 200));
    const afterConsole = names();
    expect(afterConsole.some(([n, t]) => n === "consoleError" && t === "bad thing")).toBe(true);
    expect(afterConsole.some(([n, t]) => n === "console" && t === "plain")).toBe(true);
    expect(afterConsole.some(([n, t]) => n === "exception" && t?.includes("boom"))).toBe(true);

    // alert はページをブロックするので evaluate を待たずにダイアログを処理する
    const pending = (backend as any).send(s, "Runtime.evaluate", { expression: "alert('hello dialog'); 42", returnByValue: true });
    for (let i = 0; i < 30 && !backend.dialog(t3); i++) await new Promise((r) => setTimeout(r, 50));
    expect(backend.dialog(t3)).toMatchObject({ type: "alert", message: "hello dialog" });
    expect(names().some(([n, t]) => n === "dialogOpened" && t === "hello dialog")).toBe(true);
    expect(await backend.handleDialog(t3, true)).toContain("accepted alert");
    expect((await pending).result.value).toBe(42);
    expect(names().some(([n]) => n === "dialogClosed")).toBe(true);
    await expect(backend.handleDialog(t3, true)).rejects.toMatchObject({ kind: "NOT_FOUND" });

    const extra = (await backend.navigate("new", "about:blank")).split("\t")[0];
    await backend.navigate(extra, "close");
    await new Promise((r) => setTimeout(r, 200));
    const tabEvents = names();
    expect(tabEvents.some(([n]) => n === "tabCreated")).toBe(true);
    expect(tabEvents.some(([n]) => n === "tabDestroyed")).toBe(true);

    await backend.unobserve(subscription);
    await expect(backend.unobserve(subscription)).rejects.toMatchObject({ kind: "NOT_FOUND" });
    await backend.navigate(t3, "about:blank");
    expect(backend.events()).toEqual([]);
    await backend.navigate(t3, "close");
  });

  test("unknown snapshot id", async () => {
    await expect(backend.click({ snapshot: "b999", ref: "e1" }, {})).rejects.toMatchObject({ kind: "STALE_REF" });
  });
});
