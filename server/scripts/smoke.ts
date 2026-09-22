// ヘルパーとの往復確認: sys.hello → app.list → 未知メソッド → sys.shutdown
import { HelperClient } from "../src/backends/desktop/HelperClient.js";

const c = new HelperClient();
const hello = await c.start();
console.log("hello:", hello);
const { apps } = await c.call("app.list", {});
console.log("apps:", apps.map((a) => `${a.pid} ${a.name}${a.frontmost ? " *" : ""}`));
try {
  await (c as any).call("nope.nothing", {});
} catch (e) {
  console.log("expected error:", String(e), (e as any).kind);
}
await c.stop();
console.log("stopped");
