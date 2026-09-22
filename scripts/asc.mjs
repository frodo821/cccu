// App Store Connect API の最小クライアント (ES256 JWT を Node の crypto で作る)
import { createPrivateKey, sign, randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
const KEY_ID = process.env.ASC_KEY_ID, ISSUER = process.env.ASC_ISSUER, KEY_PATH = process.env.ASC_KEY_PATH;
const b64u = (b) => Buffer.from(b).toString("base64url");
function jwt() {
  const now = Math.floor(Date.now() / 1000);
  const header = b64u(JSON.stringify({ alg: "ES256", kid: KEY_ID, typ: "JWT" }));
  const payload = b64u(JSON.stringify({ iss: ISSUER, iat: now, exp: now + 600, aud: "appstoreconnect-v1", jti: randomUUID() }));
  const sig = sign("sha256", Buffer.from(`${header}.${payload}`), { key: createPrivateKey(readFileSync(KEY_PATH)), dsaEncoding: "ieee-p1363" });
  return `${header}.${payload}.${b64u(sig)}`;
}
export async function api(method, path, body) {
  const r = await fetch(`https://api.appstoreconnect.apple.com${path}`, {
    method, headers: { authorization: `Bearer ${jwt()}`, "content-type": "application/json" }, body: body ? JSON.stringify(body) : undefined,
  });
  const text = await r.text();
  let json; try { json = JSON.parse(text); } catch { json = { raw: text }; }
  if (!r.ok) throw new Error(`${method} ${path} -> ${r.status}: ${JSON.stringify(json.errors ?? json).slice(0, 400)}`);
  return json;
}
const cmd = process.argv[2];
if (cmd === "list") {
  const j = await api("GET", "/v1/certificates?filter[certificateType]=DEVELOPER_ID_APPLICATION&limit=200");
  for (const c of j.data) console.log(`${c.id}\t${c.attributes.certificateType}\t${c.attributes.name}\texpires ${c.attributes.expirationDate}`);
  console.log(`(${j.data.length} Developer ID Application certificates)`);
} else if (cmd === "create") {
  const csr = readFileSync(process.argv[3], "utf8").replace(/-----(BEGIN|END) CERTIFICATE REQUEST-----|\n/g, "");
  const j = await api("POST", "/v1/certificates", { data: { type: "certificates", attributes: { certificateType: "DEVELOPER_ID_APPLICATION", csrContent: csr } } });
  console.log(JSON.stringify({ id: j.data.id, name: j.data.attributes.name, expires: j.data.attributes.expirationDate }));
  // DER (base64) を .cer に書く
  const { writeFileSync } = await import("node:fs");
  writeFileSync(process.argv[4], Buffer.from(j.data.attributes.certificateContent, "base64"));
}
