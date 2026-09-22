import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { registerTools } from "./tools/index.js";
import { DesktopBackend } from "./backends/desktop/DesktopBackend.js";
import { BrowserBackend } from "./backends/browser/BrowserBackend.js";
import { assertSupported, detectPlatform } from "./core/platform.js";

// macOS 以外は今は起動時に明確に拒否する (起動スクリプトも同じ判定をするが、直接起動された場合の保険)
try { assertSupported(); } catch (e) {
  process.stderr.write(`[cccu] ${(e as Error).message}\n`);
  process.exit(78);
}
process.stderr.write(`[cccu] platform: ${detectPlatform()}\n`);

const server = new McpServer({ name: "cccu", version: "0.1.0" });

const desktop = new DesktopBackend();
const browser = new BrowserBackend({
  // タブを前面に出すとき Chrome 自体も前面へ (デスクトップ側が使えない環境では無視)
  activateApp: () => desktop.activate("com.google.Chrome").then(() => {}, () => {}),
  // 通常の Chrome がポート無しで動いているかの判定 (状態表示のヒント用)
  isChromeRunning: () => desktop.listTargets().then((ts) => ts.some((t) => t.bundleId === "com.google.Chrome"), () => false),
});
registerTools(server, { backends: [desktop, browser], browser });

const transport = new StdioServerTransport();
await server.connect(transport);

const shutdown = async () => { await Promise.allSettled([desktop.dispose(), browser.dispose()]); process.exit(0); };
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
process.stdin.on("end", shutdown);   // クライアントが stdin を閉じたらヘルパーごと終了する
