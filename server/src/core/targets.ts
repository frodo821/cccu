import { HelperError, type Scope } from "./protocol.js";

/**
 * target 文字列 → 種別。
 *   app:<pid>                     アプリ全体
 *   window:<pid>:<windowNumber>   特定ウィンドウ
 *   <bundleId>                    アプリ (未起動なら起動)
 *   tab:<id>                      ブラウザタブ (未実装)
 */
export type ParsedTarget =
  | { kind: "app"; pid: number }
  | { kind: "window"; pid: number; windowNumber: number }
  | { kind: "bundle"; bundleId: string }
  | { kind: "tab"; id: string };

export function parseTarget(t: string): ParsedTarget {
  let m: RegExpExecArray | null;
  if ((m = /^app:(\d+)$/.exec(t))) return { kind: "app", pid: Number(m[1]) };
  if ((m = /^window:(\d+):(\d+)$/.exec(t))) return { kind: "window", pid: Number(m[1]), windowNumber: Number(m[2]) };
  if ((m = /^tab:(.+)$/.exec(t))) return { kind: "tab", id: m[1] };
  if (/^[A-Za-z0-9.-]+\.[A-Za-z0-9.-]+$/.test(t)) return { kind: "bundle", bundleId: t };
  throw new HelperError("INVALID_PARAMS", `unknown target "${t}" (use app:<pid>, window:<pid>:<n>, or a bundle id)`);
}

export function scopeOf(t: ParsedTarget): Scope {
  switch (t.kind) {
    case "app": return { pid: t.pid };
    case "window": return { pid: t.pid, windowNumber: t.windowNumber };
    default: throw new HelperError("UNSUPPORTED", `target kind ${t.kind} has no desktop scope`);
  }
}
