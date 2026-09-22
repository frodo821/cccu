import { HelperError } from "./protocol.js";

export type Platform = "macos" | "linux" | "windows" | "unknown";

/** 実行プラットフォーム。ヘルパーの選択 (ax_helpers/<platform>) と未対応環境の拒否に使う */
export function detectPlatform(p: NodeJS.Platform = process.platform): Platform {
  switch (p) {
    case "darwin": return "macos";
    case "linux": return "linux";
    case "win32": return "windows";
    default: return "unknown";
  }
}

export const SUPPORTED: readonly Platform[] = ["macos"];

export function assertSupported(platform = detectPlatform()): void {
  if (!SUPPORTED.includes(platform)) {
    throw new HelperError("UNSUPPORTED", `cccu supports macOS only for now (detected: ${platform})`, {
      hint: "Linux (AT-SPI) and Windows (UIA) helpers are planned; the JSON-RPC protocol in docs/PROTOCOL.md is platform-neutral.",
    });
  }
}

/** プラットフォームごとのヘルパー実行ファイルの相対パス (リポジトリ / プラグインルート基準) */
export function helperRelativePath(platform = detectPlatform()): string {
  switch (platform) {
    case "macos": return "ax_helpers/macos/.build/release/cccu-helper.app/Contents/MacOS/cccu-helper";
    case "linux": return "ax_helpers/linux/build/cccu-helper";
    case "windows": return "ax_helpers/windows/build/cccu-helper.exe";
    default: return "ax_helpers/unknown/cccu-helper";
  }
}
