import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import type { HelperClient } from "../backends/desktop/HelperClient.js";
import { HelperError } from "../core/protocol.js";

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

/** MCP ツール層。Backend を薄く包むだけで、ロジックは持たない。 */
export function registerTools(server: McpServer, ctx: ToolContext) {
  server.registerTool(
    "cu_targets",
    {
      description: "List controllable targets: running macOS apps (and later browser tabs).",
      inputSchema: { kind: z.enum(["all", "app", "browser"]).optional() },
    },
    async ({ kind }) => {
      try {
        const h = await ctx.getHelper();
        const lines: string[] = [];
        if (kind !== "browser") {
          const { apps } = await h.call("app.list", {});
          for (const a of apps) {
            lines.push(`app:${a.pid}\t${a.name}${a.bundleId ? ` (${a.bundleId})` : ""}${a.frontmost ? "\t[frontmost]" : ""}${a.hidden ? "\t[hidden]" : ""}`);
          }
        }
        if (kind === "browser" || kind === "all") lines.push("(browser targets: not implemented yet)");
        return text(lines.join("\n") || "(no targets)");
      } catch (e) { return fail(e); }
    },
  );

  server.registerTool(
    "cu_activate",
    {
      description: "Bring an app to the front. target is 'app:<pid>' or a bundle id like 'com.apple.TextEdit' (launches it if needed).",
      inputSchema: { target: z.string() },
    },
    async ({ target }) => {
      try {
        const h = await ctx.getHelper();
        const m = /^app:(\d+)$/.exec(target);
        const r = await h.call("app.activate", m ? { pid: Number(m[1]) } : { bundleId: target });
        return text(`activated app:${r.pid}`);
      } catch (e) { return fail(e); }
    },
  );

  server.registerTool(
    "cu_status",
    {
      description: "Report helper status: protocol version, Accessibility trust, capabilities.",
      inputSchema: {},
    },
    async () => {
      try {
        const h = await ctx.getHelper();
        return text(JSON.stringify(h.info, null, 2));
      } catch (e) { return fail(e); }
    },
  );
}
