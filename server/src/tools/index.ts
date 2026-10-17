import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { Backend, TargetInfo } from "../core/backend.js";
import type { BrowserBackend } from "../backends/browser/BrowserBackend.js";
import { HelperError, type FindQuery, type SnapshotResult, type Ref } from "../core/protocol.js";
import { parseRef } from "../core/refs.js";

export interface ToolContext {
  backends: Backend[];
  browser: BrowserBackend;
}

type ToolResult = { content: { type: "text"; text: string }[]; isError?: boolean };
const text = (s: string): ToolResult => ({ content: [{ type: "text", text: s }] });
const fail = (e: unknown): ToolResult => {
  let msg = String(e);
  if (e instanceof HelperError) {
    // タイムアウト時にヘルパーが添える最後のスナップショットは、JSON ではなくそのまま読める形で出す
    const { lastSnapshot, ...rest } = e.data as { lastSnapshot?: string };
    msg = `${e.kind}: ${e.message}${Object.keys(rest).length ? "\n" + JSON.stringify(rest) : ""}`;
    if (typeof lastSnapshot === "string") msg += `\nlast snapshot (no refs):\n${lastSnapshot.replace(/ \[ref=e\d+\]/g, "")}`;
  }
  return { content: [{ type: "text", text: msg }], isError: true };
};
const snap = (r: SnapshotResult, isFind = false): ToolResult => {
  let note = "";
  if (r.truncated) {
    note = r.truncatedBy === "depth" ? " (subtrees cut at maxDepth: raise maxDepth or narrow the scope with within)"
      : isFind ? " (search stopped at the maxNodes budget before covering the whole tree: raise maxNodes or narrow the scope with within)"
      : " (truncated at the maxNodes budget: raise maxNodes, narrow the scope with within, or use cu_find)";
  }
  const body = r.text.trim() === "" && isFind ? "(no matches)" : r.text;
  return text(`snapshot=${r.snapshot} refs=${r.refCount}${r.matches !== undefined ? ` matches=${r.matches}` : ""}${note}\n${body}`);
};

const modifiers = z.array(z.enum(["cmd", "shift", "alt", "ctrl", "fn"])).optional();
const refArg = z.string().describe('Element ref from a snapshot, e.g. "s3/e12" (desktop) or "b2/e5" (browser)');
const targetArg = z.string().describe('"app:<pid>", "window:<pid>:<n>", a bundle id like com.apple.TextEdit, or "tab:<id>" for a Chrome tab');
const findShape = { role: z.string().optional(), text: z.string().optional(), value: z.string().optional(), enabled: z.boolean().optional().describe("Only enabled (true) or only disabled (false) elements") };
const foregroundArg = z.boolean().optional().describe("Desktop: retry an action that had no effect by briefly bringing the app to the front, acting, then returning focus to the previous app. Default: act in the background");
const textLimitArg = z.number().int().optional().describe("Max characters per text/value before truncation (default 80). Raise it to read passages");
const reportArg = z.enum(["none", "diff", "full"]).optional().describe('Desktop: after the action, report what changed on the page: "diff" (default for clicks/typing/values/actions) lists added and removed lines with fresh refs, or the whole new tree when the change is large; "full" always returns the new tree; "none" skips it (use when batching many actions)');
const reportWaitArg = z.number().int().min(200).max(15000).optional().describe("Desktop: how long to wait for the page to change after the action before reporting (default 1200 ms; raise it for steps that change a few seconds later, e.g. 3500 for audio-gated cards)");
const pointerArg = z.enum(["human", "warp"]).optional().describe("Desktop: how the cursor travels for a real click/scroll. Default human (Fitts's-law motion); warp jumps instantly");
const withinArg = z.string().optional().describe('Limit to the subtree of this snapshot ref (e.g. "s3/e5"), not a target id. Browser apps are scoped to the page by default; to see tabs or the address bar use target "window:<pid>:<n>" or scope "app" instead');
const scopeArg = z.enum(["page", "app"]).optional().describe('Desktop browsers only: "page" (default) limits to the web content; "app" shows the application UI (menu bar, windows, tab strip, address bar) without the page content');

/** MCP ツール層。target / ref から backend を選ぶだけで、ロジックは持たない。 */
export function registerTools(server: McpServer, ctx: ToolContext) {
  const byTarget = (t: string): Backend => {
    const b = ctx.backends.find((b) => b.ownsTarget(t));
    if (!b) throw new HelperError("INVALID_PARAMS", `no backend for target ${t}`);
    return b;
  };
  const byRef = (s: string): [Backend, Ref] => {
    const ref = parseRef(s);
    const b = ctx.backends.find((b) => b.ownsSnapshot(ref.snapshot));
    if (!b) throw new HelperError("INVALID_PARAMS", `no backend for snapshot ${ref.snapshot}`);
    return [b, ref];
  };
  const run = (fn: () => Promise<ToolResult>) => fn().catch(fail);
  const toQuery = (o: { role?: string; text?: string; value?: string; exact?: boolean; enabled?: boolean }): FindQuery =>
    ({ role: o.role, title: o.text, value: o.value, exact: o.exact, enabled: o.enabled });
  const fmtTarget = (t: TargetInfo) =>
    `${t.kind === "window" ? "  " : ""}${t.id}\t"${t.title}"${t.bundleId ? ` (${t.bundleId})` : ""}${t.url ? `\t${t.url}` : ""}${t.focused ? "\t[focused]" : ""}${(t.extra ?? []).map((e) => `\t[${e}]`).join("")}`;

  server.registerTool("cu_targets",
    { description: "List controllable targets: running apps, their windows, and Chrome tabs (if Chrome exposes DevTools on port 9222).",
      inputSchema: { kind: z.enum(["all", "desktop", "browser"]).optional() } },
    ({ kind = "all" }) => run(async () => {
      const lines: string[] = [];
      if (kind !== "desktop") lines.push(await ctx.browser.statusLine());
      for (const b of ctx.backends) {
        if (kind !== "all" && b.kind !== kind) continue;
        try { lines.push(...(await b.listTargets()).map(fmtTarget)); }
        catch (e) { if (b.kind !== "browser") lines.push(`(${b.kind}: ${e instanceof HelperError ? `${e.message}. ${e.data.hint ?? ""}` : String(e)})`); }
      }
      return text(lines.join("\n") || "(no targets)");
    }));

  server.registerTool("cu_browser",
    { description: "Browser connection: \"status\" reports whether Chrome is reachable over DevTools and what to do if not; \"launch\" starts a separate Chrome (dedicated profile, logins not shared) with the DevTools port and connects to it.",
      inputSchema: { action: z.enum(["status", "launch"]), url: z.string().optional().describe("launch: URL to open (default about:blank)") } },
    ({ action, url }) => run(async () => {
      if (action === "launch") {
        const st = await ctx.browser.launch({ url });
        return text(`launched and connected: ${st.browser} at ${st.endpoint}, profile ${st.profile}, ${st.tabs} tab(s)`);
      }
      const st = await ctx.browser.status();
      return text(JSON.stringify(st, null, 2));
    }));

  server.registerTool("cu_activate",
    { description: "Bring an app, window, or tab to the front (launches the app if a bundle id is given).", inputSchema: { target: targetArg } },
    ({ target }) => run(async () => text(await byTarget(target).activate(target))));

  server.registerTool("cu_snapshot",
    { description: "Accessibility-tree snapshot of a target. Actionable elements carry [ref=eN]; pass them to other tools as \"<snapshot>/<ref>\".",
      inputSchema: { target: targetArg, within: withinArg, scope: scopeArg, maxDepth: z.number().int().optional(), maxNodes: z.number().int().optional().describe("Default 800"), interestingOnly: z.boolean().optional(), textLimit: textLimitArg } },
    ({ target, within, ...opts }) => run(async () => snap(await byTarget(target).snapshot(target, { ...opts, within: within ? parseRef(within) : undefined }))));

  server.registerTool("cu_find",
    { description: "Find elements by role and/or text within a target; returns matches (with their contents) and ancestors. Cheaper than a full snapshot.",
      inputSchema: { target: targetArg, within: withinArg, scope: scopeArg, ...findShape, exact: z.boolean().optional(), textLimit: textLimitArg, maxNodes: z.number().int().optional().describe("Search budget in nodes (default 5000)") } },
    ({ target, within, scope, textLimit, maxNodes, ...q }) => run(async () => snap(await byTarget(target).find(target, toQuery(q), { within: within ? parseRef(within) : undefined, scope, textLimit, maxNodes }), true)));

  server.registerTool("cu_query",
    { description: 'Desktop: query the accessibility tree with a CSS-like selector and return the matches (with contents and ancestors), like cu_find but structural. Syntax: role or * or "text"; [name=…] [name*=…] [name^=…] [name$=…] [value…] [text…] (text = name or the concatenated child text); :enabled :disabled :focused :selected :checked :unchecked :expanded :collapsed :has(sel) :not(compound); combinators: space or >> (descendant), > (child), + (next sibling), ~ (later sibling); "," for alternatives. Examples: `button[name*=確認]:enabled`, `group:has("正解は") button`, `heading[name^=Q3] ~ group button`, `link[name$=スタート]`. Prefer descendant combinators: the raw tree has anonymous group wrappers.',
      inputSchema: { target: targetArg, selector: z.string(), within: withinArg, scope: scopeArg, textLimit: textLimitArg, maxNodes: z.number().int().optional().describe("Search budget in nodes (default 5000)") } },
    ({ target, selector, within, scope, textLimit, maxNodes }) => run(async () => {
      const b = byTarget(target);
      if (!b.query) throw new HelperError("UNSUPPORTED", "cu_query is only available for desktop targets");
      return snap(await b.query(target, selector, { within: within ? parseRef(within) : undefined, scope, textLimit, maxNodes }), true);
    }));

  server.registerTool("cu_wait",
    { description: "Wait until an element appears (exists) / disappears (gone) or the UI settles (stableMs), then return a snapshot.",
      inputSchema: { target: targetArg, within: withinArg, scope: scopeArg, exists: z.object(findShape).optional(), count: z.number().int().optional().describe("With exists: wait until at least this many matches exist (e.g. the N-th feedback block)"), gone: z.object(findShape).optional(), stableMs: z.number().int().optional(), timeoutMs: z.number().int().optional().describe("Default 5000"), textLimit: textLimitArg } },
    ({ target, within, scope, exists, count, gone, stableMs, timeoutMs = 5000, textLimit }) => run(async () => {
      const cond = exists ? { exists: toQuery(exists), count } : gone ? { gone: toQuery(gone) } : { stable: stableMs ?? 500 };
      return snap(await byTarget(target).waitFor(target, cond, timeoutMs, within ? parseRef(within) : undefined, textLimit, scope));
    }));

  server.registerTool("cu_click",
    { description: "Click an element (accessibility press when possible, otherwise a real click at its center). Runs in the background by default; if the UI did not change, retry with foreground: true. A real click fails with OBSTRUCTED when something else (a modal, a scrim) covers the point: act on that element instead, or pass force: true.",
      inputSchema: { ref: refArg.optional().describe('Element ref from a snapshot, e.g. "s3/e12" (desktop) or "b2/e5" (browser). Omit it and pass x,y to click a screen point (desktop fallback, e.g. read from a cu_screenshot with grid)'), x: z.number().optional(), y: z.number().optional().describe("Desktop: screen coordinates to click when no ref is usable"), button: z.enum(["left", "right"]).optional(), count: z.number().int().min(1).max(3).optional(), modifiers, foreground: foregroundArg, pointer: pointerArg, force: z.boolean().optional().describe("Desktop: click even if the point is covered by another element (an OBSTRUCTED error told you what covers it)"), report: reportArg, textLimit: textLimitArg, reportWaitMs: reportWaitArg } },
    ({ ref, x, y, report = "diff", ...opts }) => run(async () => {
      if (!ref) {
        if (x === undefined || y === undefined) throw new HelperError("INVALID_PARAMS", "cu_click needs ref, or x and y");
        const b = ctx.backends.find((b) => b.kind === "desktop" && b.clickAt);
        if (!b?.clickAt) throw new HelperError("UNSUPPORTED", "point clicks need the desktop backend");
        const { foreground: _f, force: _force, textLimit: _t, reportWaitMs: _w, ...rest } = opts;
        return text(`clicked ${x},${y} via ${await b.clickAt(x, y, rest)}`);
      }
      const [b, r] = byRef(ref); return text(`clicked ${ref} via ${await b.click(r, { ...opts, report: b.kind === "desktop" ? report : undefined })}`);
    }));

  server.registerTool("cu_type",
    { description: "Type text into an element (focuses it first). Without ref, types into whatever has focus. clear replaces existing text; submit presses Enter afterwards.",
      inputSchema: { ref: refArg.optional(), text: z.string(), clear: z.boolean().optional(), submit: z.boolean().optional(), foreground: foregroundArg, report: reportArg, textLimit: textLimitArg, reportWaitMs: reportWaitArg } },
    ({ ref, text: t, report = "diff", ...opts }) => run(async () => {
      const [b, r] = ref ? byRef(ref) : [ctx.backends[0], undefined];
      return text(`typed via ${await b.type(r, t, { ...opts, report: b.kind === "desktop" ? report : undefined })}`);
    }));

  server.registerTool("cu_key",
    { description: "Press a key with optional modifiers, e.g. key=\"n\" modifiers=[\"cmd\"]. Key names follow KeyboardEvent.key (Enter, Escape, ArrowDown, Tab, a, F5). target picks the app/tab. Desktop shortcuts run through the app's menu without bringing it to the front when possible.",
      inputSchema: { target: targetArg.optional(), key: z.string(), modifiers, foreground: foregroundArg, report: reportArg.describe('Desktop: report what changed on the page afterwards ("diff" / "full"); default "none" for keys'), textLimit: textLimitArg, reportWaitMs: reportWaitArg } },
    ({ target, key, modifiers: m, foreground, report, textLimit, reportWaitMs }) => run(async () => { const b = target ? byTarget(target) : ctx.backends[0]; return text(`ok via ${await b.key(target, key, m, { foreground, report: b.kind === "desktop" ? report : undefined, textLimit, reportWaitMs })}`); }));

  server.registerTool("cu_scroll",
    { description: "Scroll at an element (positive dy scrolls down).", inputSchema: { ref: refArg, dx: z.number().int().optional(), dy: z.number().int().optional(), foreground: foregroundArg, pointer: pointerArg } },
    ({ ref, dx = 0, dy = 0, foreground, pointer }) => run(async () => { const [b, r] = byRef(ref); return text(`ok via ${await b.scroll(r, dx, dy, { foreground, pointer })}`); }));

  server.registerTool("cu_set_value",
    { description: "Set an element's value directly (checkbox: true/false, slider: number, text field / select: string).",
      inputSchema: { ref: refArg, value: z.union([z.string(), z.number(), z.boolean()]), report: reportArg, textLimit: textLimitArg, reportWaitMs: reportWaitArg } },
    ({ ref, value, report = "diff", textLimit, reportWaitMs }) => run(async () => { const [b, r] = byRef(ref); const out = await b.setValue(r, value, b.kind === "desktop" ? { report, textLimit, reportWaitMs } : {}); return text(out ?? "ok"); }));

  server.registerTool("cu_focus",
    { description: "Give keyboard focus to an element.", inputSchema: { ref: refArg } },
    ({ ref }) => run(async () => { const [b, r] = byRef(ref); await b.focus(r); return text("ok"); }));

  server.registerTool("cu_attributes",
    { description: "Raw attributes of an element: AX attributes/actions on desktop, DOM attributes + ARIA on the web (debugging / advanced).",
      inputSchema: { ref: refArg, names: z.array(z.string()).optional() } },
    ({ ref, names }) => run(async () => { const [b, r] = byRef(ref); return text(JSON.stringify(await b.attributes(r, names), null, 2)); }));

  server.registerTool("cu_action",
    { description: "Perform a raw action: desktop AX actions (AXPress, AXShowMenu, AXIncrement, AXConfirm, AXCancel) or browser actions (click, hover, contextmenu, submit, scrollIntoView).",
      inputSchema: { ref: refArg, action: z.string(), report: reportArg, textLimit: textLimitArg, reportWaitMs: reportWaitArg } },
    ({ ref, action, report = "diff", textLimit, reportWaitMs }) => run(async () => { const [b, r] = byRef(ref); const out = await b.action(r, action, b.kind === "desktop" ? { report, textLimit, reportWaitMs } : {}); return text(out ?? "ok"); }));

  server.registerTool("cu_navigate",
    { description: "Open a URL, go \"back\" / \"forward\", or \"close\" the tab. CDP Chrome: target \"tab:<id>\" (omitted or \"new\" creates a tab; launches Chrome if not connected). The user's own Chrome: target its bundle id (com.google.Chrome) or app:<pid>; the URL goes through the address bar of the current tab (url \"new\" opens a tab first).",
      inputSchema: { target: z.string().optional().describe('"tab:<id>", "new", or a desktop browser target (com.google.Chrome / app:<pid>)'), url: z.string().describe('URL, or "back" / "forward" / "close" / "new"') } },
    ({ target, url }) => run(async () => {
      const b = target && !ctx.browser.ownsTarget(target) && target !== "new" ? byTarget(target) : ctx.browser;
      if (!b.navigate) throw new HelperError("UNSUPPORTED", `cannot navigate ${target}`);
      return text(await b.navigate(target, url));
    }));

  server.registerTool("cu_session",
    { description: "Desktop: declare the start and end of a run of actions on one app. begin keeps the app in front and blocks the user's keyboard and mouse (synthetic input still works) so your actions and the user's cannot interleave; end returns focus to the previous app and unblocks. begin requires maxSeconds (1..3600): the session ends by itself after that, or when the user presses Escape three times quickly. Use it for multi-step work on one app; extend it when you need more time; always end it when done.",
      inputSchema: { action: z.enum(["begin", "extend", "end", "status"]), target: targetArg.optional().describe("begin: the app to work in (app:<pid> or bundle id)"), maxSeconds: z.number().int().min(1).max(3600).optional().describe("begin (required) / extend: how long the session may last"), blockInput: z.boolean().optional().describe("begin: block the user's input (default true)") } },
    ({ action, target, maxSeconds, blockInput }) => run(async () => {
      const b = target ? byTarget(target) : ctx.backends[0];
      if (!b.inputSession) throw new HelperError("UNSUPPORTED", "sessions are only available for desktop apps");
      return text(await b.inputSession(action, target, { maxSeconds, blockInput }));
    }));

  server.registerTool("cu_screenshot",
    { description: "Screenshot of a target (window, app's main window, or tab) as an image. Supplementary: prefer cu_snapshot for reading UI; use this to check visual state. Desktop capture needs Screen Recording permission.",
      inputSchema: { target: targetArg.optional().describe("Omit for the main display (desktop)"), maxWidth: z.number().int().optional().describe("Downscale to this width (default 1600, desktop only)"), grid: z.number().int().min(20).optional().describe("Desktop: overlay a coordinate grid every N screen px with labels, so you can read screen coordinates off the image and click them with cu_click x,y when the accessibility tree is unusable (100 is a good default)") } },
    ({ target, maxWidth, grid }) => run(async () => {
      const b = target ? byTarget(target) : ctx.backends[0];
      const r = await b.screenshot(target ?? "", { maxWidth, grid });
      const geo = r.frame
        ? ` | captured area at screen ${Math.round(r.frame.x)},${Math.round(r.frame.y)} ${Math.round(r.frame.w)}x${Math.round(r.frame.h)}; image px = (screen - origin) * ${(r.scale ?? 1).toFixed(3)}. Element [at x,y] hints in snapshots use screen coordinates`
        : "";
      return { content: [{ type: "image", data: r.pngBase64, mimeType: "image/png" } as any, { type: "text", text: `${r.width ?? "?"}x${r.height ?? "?"} png${geo}` }] };
    }));

  server.registerTool("cu_observe",
    { description: "Subscribe to events of an app (AX notifications: window created, focus changed, sheet opened...) or a Chrome tab (navigated, loaded, dialogOpened, dialogClosed, consoleError, exception, tabCreated, tabDestroyed; also domContentLoaded, console, tabInfoChanged). Events accumulate; read them with cu_events.",
      inputSchema: { target: targetArg, notifications: z.array(z.string()).optional().describe("Desktop: AX notification names (AXWindowCreated, AXValueChanged...). Browser: names listed above. Default is a sensible set") } },
    ({ target, notifications }) => run(async () => {
      const r = await byTarget(target).observe(target, notifications);
      return text(`subscription=${r.subscription}\nnotifications: ${r.notifications.join(", ")}`);
    }));

  server.registerTool("cu_events",
    { description: "Return and clear UI events received since the last call (from cu_observe subscriptions).", inputSchema: {} },
    () => run(async () => {
      const evs = ctx.backends.flatMap((b) => b.events()).sort((a, b) => a.time - b.time);
      if (!evs.length) return text("(no events)");
      return text(evs.map((e) => {
        const el = [e.element.role, e.element.title !== undefined ? `"${e.element.title}"` : null, e.element.value !== undefined ? `: ${JSON.stringify(e.element.value)}` : null].filter(Boolean).join(" ");
        return `${new Date(e.time * 1000).toISOString().slice(11, 23)}\t${e.target}\t${e.notification}\t${el}`;
      }).join("\n"));
    }));

  server.registerTool("cu_unobserve",
    { description: "Cancel a cu_observe subscription.", inputSchema: { subscription: z.string() } },
    ({ subscription }) => run(async () => {
      // 購読 id の先頭文字で振り分け: o = desktop (helper), w = browser
      const b = ctx.backends.find((b) => (subscription.startsWith("w") ? b.kind === "browser" : b.kind === "desktop")) ?? ctx.backends[0];
      await b.unobserve(subscription); return text("ok");
    }));

  server.registerTool("cu_dialog",
    { description: "Browser only: accept or dismiss the JavaScript dialog (alert/confirm/prompt/beforeunload) currently open on a tab. While a dialog is open, other page actions block.",
      inputSchema: { target: targetArg, accept: z.boolean().optional().describe("Default true"), promptText: z.string().optional().describe("Text to enter for prompt()") } },
    ({ target, accept = true, promptText }) => run(async () => text(await ctx.browser.handleDialog(target, accept, promptText))));

  server.registerTool("cu_status",
    { description: "Backend status: helper protocol version and Accessibility trust, Chrome DevTools reachability.", inputSchema: {} },
    () => run(async () => {
      const out: Record<string, unknown> = {};
      for (const b of ctx.backends) {
        if (b.kind === "browser") { out.browser = await ctx.browser.status(); continue; }
        try {
          const perms = await (b as any).permissions?.();
          out.desktop = {
            ...perms,
            hint: perms?.accessibility ? undefined : 'Grant Accessibility to "cccu-helper" in System Settings > Privacy & Security (no terminal restart needed)',
            screenRecordingHint: perms?.screenRecording ? undefined : 'Screenshots need Screen Recording for "cccu-helper" (System Settings > Privacy & Security > Screen Recording)',
          };
        } catch (e) { out[b.kind] = e instanceof HelperError ? { error: e.message, ...e.data } : String(e); }
      }
      return text(JSON.stringify(out, null, 2));
    }));
}
