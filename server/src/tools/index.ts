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
  const msg = e instanceof HelperError
    ? `${e.kind}: ${e.message}${Object.keys(e.data).length ? "\n" + JSON.stringify(e.data) : ""}`
    : String(e);
  return { content: [{ type: "text", text: msg }], isError: true };
};
const snap = (r: SnapshotResult): ToolResult =>
  text(`snapshot=${r.snapshot} refs=${r.refCount}${r.truncated ? " (truncated: narrow the scope or use cu_find)" : ""}\n${r.text}`);

const modifiers = z.array(z.enum(["cmd", "shift", "alt", "ctrl", "fn"])).optional();
const refArg = z.string().describe('Element ref from a snapshot, e.g. "s3/e12" (desktop) or "b2/e5" (browser)');
const targetArg = z.string().describe('"app:<pid>", "window:<pid>:<n>", a bundle id like com.apple.TextEdit, or "tab:<id>" for a Chrome tab');
const findShape = { role: z.string().optional(), text: z.string().optional(), value: z.string().optional() };
const withinArg = z.string().optional().describe('Limit to the subtree of this ref (e.g. the "webarea" of a Chrome window to skip the browser chrome)');

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
  const toQuery = (o: { role?: string; text?: string; value?: string; exact?: boolean }): FindQuery =>
    ({ role: o.role, title: o.text, value: o.value, exact: o.exact });
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
      inputSchema: { target: targetArg, within: withinArg, maxDepth: z.number().int().optional(), maxNodes: z.number().int().optional().describe("Default 800"), interestingOnly: z.boolean().optional() } },
    ({ target, within, ...opts }) => run(async () => snap(await byTarget(target).snapshot(target, { ...opts, within: within ? parseRef(within) : undefined }))));

  server.registerTool("cu_find",
    { description: "Find elements by role and/or text within a target; returns matches (with their contents) and ancestors. Cheaper than a full snapshot.",
      inputSchema: { target: targetArg, within: withinArg, ...findShape, exact: z.boolean().optional() } },
    ({ target, within, ...q }) => run(async () => snap(await byTarget(target).find(target, toQuery(q), { within: within ? parseRef(within) : undefined }))));

  server.registerTool("cu_wait",
    { description: "Wait until an element appears (exists) / disappears (gone) or the UI settles (stableMs), then return a snapshot.",
      inputSchema: { target: targetArg, within: withinArg, exists: z.object(findShape).optional(), gone: z.object(findShape).optional(), stableMs: z.number().int().optional(), timeoutMs: z.number().int().optional().describe("Default 5000") } },
    ({ target, within, exists, gone, stableMs, timeoutMs = 5000 }) => run(async () => {
      const cond = exists ? { exists: toQuery(exists) } : gone ? { gone: toQuery(gone) } : { stable: stableMs ?? 500 };
      return snap(await byTarget(target).waitFor(target, cond, timeoutMs, within ? parseRef(within) : undefined));
    }));

  server.registerTool("cu_click",
    { description: "Click an element (accessibility press when possible, otherwise a real click at its center).",
      inputSchema: { ref: refArg, button: z.enum(["left", "right"]).optional(), count: z.number().int().min(1).max(3).optional(), modifiers } },
    ({ ref, ...opts }) => run(async () => { const [b, r] = byRef(ref); return text(`clicked ${ref} via ${await b.click(r, opts)}`); }));

  server.registerTool("cu_type",
    { description: "Type text into an element (focuses it first). Without ref, types into whatever has focus. clear replaces existing text; submit presses Enter afterwards.",
      inputSchema: { ref: refArg.optional(), text: z.string(), clear: z.boolean().optional(), submit: z.boolean().optional() } },
    ({ ref, text: t, ...opts }) => run(async () => {
      const [b, r] = ref ? byRef(ref) : [ctx.backends[0], undefined];
      return text(`typed via ${await b.type(r, t, opts)}`);
    }));

  server.registerTool("cu_key",
    { description: "Press a key with optional modifiers, e.g. key=\"n\" modifiers=[\"cmd\"]. Key names follow KeyboardEvent.key (Enter, Escape, ArrowDown, Tab, a, F5). target picks the app/tab.",
      inputSchema: { target: targetArg.optional(), key: z.string(), modifiers } },
    ({ target, key, modifiers: m }) => run(async () => { await (target ? byTarget(target) : ctx.backends[0]).key(target, key, m); return text("ok"); }));

  server.registerTool("cu_scroll",
    { description: "Scroll at an element (positive dy scrolls down).", inputSchema: { ref: refArg, dx: z.number().int().optional(), dy: z.number().int().optional() } },
    ({ ref, dx = 0, dy = 0 }) => run(async () => { const [b, r] = byRef(ref); await b.scroll(r, dx, dy); return text("ok"); }));

  server.registerTool("cu_set_value",
    { description: "Set an element's value directly (checkbox: true/false, slider: number, text field / select: string).",
      inputSchema: { ref: refArg, value: z.union([z.string(), z.number(), z.boolean()]) } },
    ({ ref, value }) => run(async () => { const [b, r] = byRef(ref); await b.setValue(r, value); return text("ok"); }));

  server.registerTool("cu_focus",
    { description: "Give keyboard focus to an element.", inputSchema: { ref: refArg } },
    ({ ref }) => run(async () => { const [b, r] = byRef(ref); await b.focus(r); return text("ok"); }));

  server.registerTool("cu_attributes",
    { description: "Raw attributes of an element: AX attributes/actions on desktop, DOM attributes + ARIA on the web (debugging / advanced).",
      inputSchema: { ref: refArg, names: z.array(z.string()).optional() } },
    ({ ref, names }) => run(async () => { const [b, r] = byRef(ref); return text(JSON.stringify(await b.attributes(r, names), null, 2)); }));

  server.registerTool("cu_action",
    { description: "Perform a raw action: desktop AX actions (AXPress, AXShowMenu, AXIncrement, AXConfirm, AXCancel) or browser actions (click, hover, contextmenu, submit, scrollIntoView).",
      inputSchema: { ref: refArg, action: z.string() } },
    ({ ref, action }) => run(async () => { const [b, r] = byRef(ref); await b.action(r, action); return text("ok"); }));

  server.registerTool("cu_navigate",
    { description: "Browser only: open a URL in a tab (target omitted or \"new\" creates a tab; launches Chrome automatically if not connected), go \"back\" / \"forward\", or \"close\" the tab.",
      inputSchema: { target: z.string().optional().describe('"tab:<id>" or "new"'), url: z.string().describe('URL, or "back" / "forward" / "close"') } },
    ({ target, url }) => run(async () => text(await ctx.browser.navigate(target, url))));

  server.registerTool("cu_screenshot",
    { description: "Screenshot of a target (window, app's main window, or tab) as an image. Supplementary: prefer cu_snapshot for reading UI; use this to check visual state. Desktop capture needs Screen Recording permission.",
      inputSchema: { target: targetArg.optional().describe("Omit for the main display (desktop)"), maxWidth: z.number().int().optional().describe("Downscale to this width (default 1600, desktop only)") } },
    ({ target, maxWidth }) => run(async () => {
      const b = target ? byTarget(target) : ctx.backends[0];
      const r = await b.screenshot(target ?? "", { maxWidth });
      return { content: [{ type: "image", data: r.pngBase64, mimeType: "image/png" } as any, { type: "text", text: `${r.width ?? "?"}x${r.height ?? "?"} png` }] };
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
