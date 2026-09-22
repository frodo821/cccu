import { HelperError, type Modifier } from "../../core/protocol.js";

/** W3C key 名 → Input.dispatchKeyEvent のパラメータ */
export interface KeyDesc { key: string; code: string; windowsVirtualKeyCode: number; text?: string }

const special: Record<string, KeyDesc> = {
  Enter: { key: "Enter", code: "Enter", windowsVirtualKeyCode: 13, text: "\r" },
  Tab: { key: "Tab", code: "Tab", windowsVirtualKeyCode: 9 },
  Escape: { key: "Escape", code: "Escape", windowsVirtualKeyCode: 27 },
  Backspace: { key: "Backspace", code: "Backspace", windowsVirtualKeyCode: 8 },
  Delete: { key: "Delete", code: "Delete", windowsVirtualKeyCode: 46 },
  ArrowLeft: { key: "ArrowLeft", code: "ArrowLeft", windowsVirtualKeyCode: 37 },
  ArrowUp: { key: "ArrowUp", code: "ArrowUp", windowsVirtualKeyCode: 38 },
  ArrowRight: { key: "ArrowRight", code: "ArrowRight", windowsVirtualKeyCode: 39 },
  ArrowDown: { key: "ArrowDown", code: "ArrowDown", windowsVirtualKeyCode: 40 },
  Home: { key: "Home", code: "Home", windowsVirtualKeyCode: 36 },
  End: { key: "End", code: "End", windowsVirtualKeyCode: 35 },
  PageUp: { key: "PageUp", code: "PageUp", windowsVirtualKeyCode: 33 },
  PageDown: { key: "PageDown", code: "PageDown", windowsVirtualKeyCode: 34 },
  " ": { key: " ", code: "Space", windowsVirtualKeyCode: 32, text: " " },
  Space: { key: " ", code: "Space", windowsVirtualKeyCode: 32, text: " " },
};
for (let i = 1; i <= 12; i++) special[`F${i}`] = { key: `F${i}`, code: `F${i}`, windowsVirtualKeyCode: 111 + i };

export function describeKey(key: string): KeyDesc {
  if (special[key]) return special[key];
  if (key.length === 1) {
    const upper = key.toUpperCase();
    if (/[A-Z]/.test(upper)) return { key, code: `Key${upper}`, windowsVirtualKeyCode: upper.charCodeAt(0), text: key };
    if (/[0-9]/.test(key)) return { key, code: `Digit${key}`, windowsVirtualKeyCode: key.charCodeAt(0), text: key };
    return { key, code: "", windowsVirtualKeyCode: 0, text: key };
  }
  throw new HelperError("INVALID_PARAMS", `unknown key ${key}`);
}

/** CDP の modifiers ビット: Alt=1, Ctrl=2, Meta=4, Shift=8 */
export function modifierBits(mods: Modifier[] = []): number {
  let m = 0;
  for (const x of mods) {
    if (x === "alt") m |= 1; else if (x === "ctrl") m |= 2; else if (x === "cmd") m |= 4; else if (x === "shift") m |= 8;
    else throw new HelperError("INVALID_PARAMS", `modifier ${x} not supported in browser`);
  }
  return m;
}

/**
 * macOS の Chrome は合成キーイベントの cmd+文字 を編集コマンドに変換しないので、
 * Input.dispatchKeyEvent の `commands` で明示する (Playwright と同じ手法)。
 */
const macEditingCommands: Record<string, string[]> = {
  "cmd+a": ["selectAll"], "cmd+c": ["copy"], "cmd+v": ["paste"], "cmd+x": ["cut"],
  "cmd+z": ["undo"], "cmd+shift+z": ["redo"], "cmd+Backspace": ["deleteToBeginningOfLine"],
  "cmd+ArrowLeft": ["moveToBeginningOfLine"], "cmd+ArrowRight": ["moveToEndOfLine"],
  "cmd+shift+ArrowLeft": ["moveToBeginningOfLineAndModifySelection"], "cmd+shift+ArrowRight": ["moveToEndOfLineAndModifySelection"],
  "cmd+ArrowUp": ["moveToBeginningOfDocument"], "cmd+ArrowDown": ["moveToEndOfDocument"],
  "alt+ArrowLeft": ["moveWordLeft"], "alt+ArrowRight": ["moveWordRight"], "alt+Backspace": ["deleteWordBackward"],
};
export function editingCommands(key: string, mods: Modifier[] = []): string[] | undefined {
  const order: Modifier[] = ["cmd", "ctrl", "alt", "shift"];
  const combo = [...order.filter((m) => mods.includes(m)), key.length === 1 ? key.toLowerCase() : key].join("+");
  return macEditingCommands[combo];
}
