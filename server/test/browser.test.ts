// Chrome を専用プロファイルで起動し、BrowserBackend をフィクスチャページに対して検証する。
// Chrome が無ければスキップ。CCCU_TEST_CDP_URL を指定すると既存インスタンスを使う。
import { test, expect, beforeAll, afterAll, describe } from "bun:test";
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { BrowserBackend } from "../src/backends/browser/BrowserBackend.js";
import { parseRef } from "../src/core/refs.js";

const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const PORT = 9333;
const fixture = "file://" + resolve(import.meta.dir, "fixtures/form.html");

let chrome: ChildProcess | null = null;
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
});

afterAll(async () => {
  await backend?.dispose();
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
    await backend.click(refOf(s, 'button "Far away button"'), {});
    const attrs = await backend.attributes(refOf(s, 'button "Far away button"'));
    const rect = attrs.rect as { y: number };
    expect(rect.y).toBeLessThan(1000);
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

  test("unknown snapshot id", async () => {
    await expect(backend.click({ snapshot: "b999", ref: "e1" }, {})).rejects.toMatchObject({ kind: "STALE_REF" });
  });
});
