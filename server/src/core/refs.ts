import { HelperError, type Ref } from "./protocol.js";

/** MCP ツール引数の ref 文字列 "s7/e12" ⇄ Ref オブジェクト */
export function parseRef(s: string): Ref {
  const m = /^(s\d+)\/(e\d+)$/.exec(s.trim());
  if (!m) throw new HelperError("INVALID_PARAMS", `ref must look like "s7/e12", got "${s}"`);
  return { snapshot: m[1], ref: m[2] };
}

export function formatRef(r: Ref): string {
  return `${r.snapshot}/${r.ref}`;
}
