import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerTools } from "./tools/index.js";
import { HelperClient } from "./backends/desktop/HelperClient.js";

const server = new McpServer({ name: "cccu", version: "0.1.0" });

// ヘルパーは最初のツール呼び出し時に遅延起動する (権限ダイアログを不用意に出さないため)
let helper: HelperClient | null = null;
async function getHelper(): Promise<HelperClient> {
  if (!helper) {
    helper = new HelperClient();
    await helper.start();
  }
  return helper;
}

registerTools(server, { getHelper });

const transport = new StdioServerTransport();
await server.connect(transport);

const shutdown = async () => { await helper?.stop(); process.exit(0); };
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
process.stdin.on("end", shutdown);   // クライアントが stdin を閉じたらヘルパーごと終了する
