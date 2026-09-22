import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { HelperClient } from "../backends/desktop/HelperClient.js";
import { HelperError, type SnapshotResult, type FindQuery } from "../core/protocol.js";
import { parseRef } from "../core/refs.js";
import { parseTarget, scopeOf, type ParsedTarget } from "../core/targets.js";

export interface ToolContext {
  getHelper(): Promise<HelperClient>;
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
const refArg = z.string().describe('Element ref from a snapshot, e.g. "s3/e12"');
const targetArg = z.string().describe('"app:<pid>", "window:<pid>:<n>", or a bundle id like com.apple.TextEdit');

/** MCP ツール層。Backend を薄く包むだけで、ロジックは持たない。 */
export function registerTools(server: McpServer, ctx: ToolContext) {
  const wrap = (fn: (h: HelperClient) => Promise<ToolResult>) => async () => {
    try { return await fn(await ctx.getHelper()); } catch (e) { return fail(e); }
  };
  // target を desktop scope に解決する (bundle id は起動・前面化してから pid に)
  async function resolveScope(h: HelperClient, target: string) {
    let t: ParsedTarget = parseTarget(target);
    if (t.kind === "bundle") t = { kind: "app", pid: (await h.call("app.activate", { bundleId: t.bundleId })).pid };
    return scopeOf(t);
  }

  server.registerTool("cu_status",
    { description: "Helper status: protocol version, Accessibility trust, capabilities.", inputSchema: {} },
    wrap(async (h) => text(JSON.stringify(h.info, null, 2))));

  server.registerTool("cu_targets",
    { description: "List controllable targets: running apps and their windows. Returns app:<pid> and window:<pid>:<n> ids.",
      inputSchema: { windows: z.boolean().optional().describe("Also list windows (default true)") } },
    async ({ windows }) => wrap(async (h) => {
      const { apps } = await h.call("app.list", {});
      const wins = windows === false ? [] : (await h.call("window.list", {})).windows;
      const lines: string[] = [];
      for (const a of apps) {
        lines.push(`app:${a.pid}\t${a.name}${a.bundleId ? ` (${a.bundleId})` : ""}${a.frontmost ? "\t[frontmost]" : ""}${a.hidden ? "\t[hidden]" : ""}`);
        for (const w of wins.filter((w) => w.pid === a.pid)) {
          lines.push(`  window:${w.pid}:${w.windowNumber}\t"${w.title}"${w.focused ? "\t[focused]" : ""}${w.minimized ? "\t[minimized]" : ""}`);
        }
      }
      return text(lines.join("\n") || "(no targets)");
    })());

  server.registerTool("cu_activate",
    { description: "Bring an app or window to the front (launches the app if a bundle id is given).", inputSchema: { target: targetArg } },
    async ({ target }) => wrap(async (h) => {
      const t = parseTarget(target);
      if (t.kind === "window") { await h.call("window.raise", { pid: t.pid, windowNumber: t.windowNumber }); return text(`raised ${target}`); }
      if (t.kind === "tab") throw new HelperError("UNSUPPORTED", "browser targets not implemented yet");
      const r = await h.call("app.activate", t.kind === "app" ? { pid: t.pid } : { bundleId: t.bundleId });
      return text(`activated app:${r.pid}`);
    })());

  server.registerTool("cu_snapshot",
    { description: "Accessibility-tree snapshot of a target. Actionable elements carry [ref=eN]; pass them to other tools as \"<snapshot>/<ref>\".",
      inputSchema: {
        target: targetArg,
        maxDepth: z.number().int().optional(),
        maxNodes: z.number().int().optional().describe("Default 800; large apps get truncated"),
        interestingOnly: z.boolean().optional().describe("Collapse unnamed groups (default true)"),
      } },
    async ({ target, ...opts }) => wrap(async (h) => snap(await h.call("ui.snapshot", { scope: await resolveScope(h, target), ...opts })))());

  server.registerTool("cu_find",
    { description: "Find elements by role and/or text within a target; returns only matches and their ancestors. Cheaper than a full snapshot.",
      inputSchema: {
        target: targetArg,
        role: z.string().optional().describe("e.g. button, textfield, textarea, checkbox, menuitem, sheet"),
        text: z.string().optional().describe("Substring of the title/label"),
        value: z.string().optional().describe("Substring of the value"),
        exact: z.boolean().optional(),
      } },
    async ({ target, role, text: title, value, exact }) => wrap(async (h) => {
      const query: FindQuery = { role, title, value, exact };
      return snap(await h.call("ui.find", { scope: await resolveScope(h, target), query }));
    })());

  server.registerTool("cu_click",
    { description: "Click an element (AXPress when possible, otherwise a real mouse click at its center).",
      inputSchema: { ref: refArg, button: z.enum(["left", "right"]).optional(), count: z.number().int().min(1).max(3).optional(), modifiers } },
    async ({ ref, ...opts }) => wrap(async (h) => text(`clicked ${ref} via ${(await h.call("ui.click", { ref: parseRef(ref), ...opts })).method}`))());

  server.registerTool("cu_type",
    { description: "Type text. With ref: focuses the element first and sets its value directly when possible. clear replaces existing text; submit presses Enter afterwards.",
      inputSchema: { ref: refArg.optional(), text: z.string(), clear: z.boolean().optional(), submit: z.boolean().optional() } },
    async ({ ref, ...opts }) => wrap(async (h) => { await h.call("input.type", { ref: ref ? parseRef(ref) : undefined, ...opts }); return text("ok"); })());

  server.registerTool("cu_key",
    { description: "Press a key with optional modifiers, e.g. key=\"n\" modifiers=[\"cmd\"]. Key names follow KeyboardEvent.key (Enter, Escape, ArrowDown, Tab, a, F5).",
      inputSchema: { target: targetArg.optional().describe("App to bring to front before pressing"), key: z.string(), modifiers } },
    async ({ target, key, modifiers: mods }) => wrap(async (h) => {
      const pid = target ? (scopeOf(await resolveScopeApp(h, target)) as { pid: number }).pid : undefined;
      await h.call("input.key", { key, modifiers: mods, pid });
      return text("ok");
    })());
  async function resolveScopeApp(h: HelperClient, target: string): Promise<ParsedTarget> {
    const t = parseTarget(target);
    return t.kind === "bundle" ? { kind: "app", pid: (await h.call("app.activate", { bundleId: t.bundleId })).pid } : t;
  }

  server.registerTool("cu_scroll",
    { description: "Scroll at an element (positive dy scrolls down).",
      inputSchema: { ref: refArg, dx: z.number().int().optional(), dy: z.number().int().optional() } },
    async ({ ref, dx = 0, dy = 0 }) => wrap(async (h) => { await h.call("input.scroll", { ref: parseRef(ref), dx, dy }); return text("ok"); })());

  server.registerTool("cu_set_value",
    { description: "Set an element's value directly (checkbox: true/false, slider: number, text field: string).",
      inputSchema: { ref: refArg, value: z.union([z.string(), z.number(), z.boolean()]) } },
    async ({ ref, value }) => wrap(async (h) => { await h.call("ui.setAttribute", { ref: parseRef(ref), name: "AXValue", value }); return text("ok"); })());

  server.registerTool("cu_focus",
    { description: "Give keyboard focus to an element.", inputSchema: { ref: refArg } },
    async ({ ref }) => wrap(async (h) => { await h.call("ui.focus", { ref: parseRef(ref) }); return text("ok"); })());

  server.registerTool("cu_attributes",
    { description: "Raw accessibility attributes and actions of an element (debugging / advanced).",
      inputSchema: { ref: refArg, names: z.array(z.string()).optional() } },
    async ({ ref, names }) => wrap(async (h) => text(JSON.stringify((await h.call("ui.attributes", { ref: parseRef(ref), names })).attributes, null, 2)))());

  server.registerTool("cu_action",
    { description: "Perform a raw accessibility action on an element, e.g. AXPress, AXShowMenu, AXIncrement, AXConfirm, AXCancel.",
      inputSchema: { ref: refArg, action: z.string() } },
    async ({ ref, action }) => wrap(async (h) => { await h.call("ui.performAction", { ref: parseRef(ref), action }); return text("ok"); })());

  server.registerTool("cu_wait",
    { description: "Wait until an element appears/disappears or the UI settles, then return a snapshot.",
      inputSchema: {
        target: targetArg,
        exists: z.object({ role: z.string().optional(), text: z.string().optional(), value: z.string().optional() }).optional(),
        gone: z.object({ role: z.string().optional(), text: z.string().optional(), value: z.string().optional() }).optional(),
        stableMs: z.number().int().optional().describe("Wait until the tree is unchanged for this long"),
        timeoutMs: z.number().int().optional().describe("Default 5000"),
      } },
    async ({ target, exists, gone, stableMs, timeoutMs = 5000 }) => wrap(async (h) => {
      const q = (o: { role?: string; text?: string; value?: string }): FindQuery => ({ role: o.role, title: o.text, value: o.value });
      const condition = exists ? { exists: q(exists) } : gone ? { gone: q(gone) } : { stable: stableMs ?? 500 };
      return snap(await h.call("ui.waitFor", { scope: await resolveScope(h, target), condition, timeoutMs }));
    })());
}
