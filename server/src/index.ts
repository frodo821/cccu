import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerTools } from "./tools/index.js";
import { DesktopBackend } from "./backends/desktop/DesktopBackend.js";
import { BrowserBackend } from "./backends/browser/BrowserBackend.js";

const server = new McpServer({ name: "cccu", version: "0.1.0" });

const desktop = new DesktopBackend();
const browser = new BrowserBackend({
  // タブを前面に出すとき Chrome 自体も前面へ (デスクトップ側が使えない環境では無視)
  activateApp: () => desktop.activate("com.google.Chrome").then(() => {}, () => {}),
});
registerTools(server, { backends: [desktop, browser], browser });

const transport = new StdioServerTransport();
await server.connect(transport);

const shutdown = async () => { await Promise.allSettled([desktop.dispose(), browser.dispose()]); process.exit(0); };
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
process.stdin.on("end", shutdown);   // クライアントが stdin を閉じたらヘルパーごと終了する
