import type { FindQuery } from "../../core/protocol.js";

/** CDP Accessibility.getFullAXTree のノード (必要な部分だけ) */
export interface CDPAXNode {
  nodeId: string;
  ignored: boolean;
  role?: { value: string };
  name?: { value: string };
  value?: { value: unknown };
  properties?: { name: string; value: { value: unknown } }[];
  childIds?: string[];
  parentId?: string;
  backendDOMNodeId?: number;
}

export interface AXNode {
  role: string;
  title?: string;
  value?: string | number | boolean;
  states: string[];
  actionable: boolean;
  backendNodeId?: number;
  children: AXNode[];
  matched: boolean;
  /** このノードが属するフレーム (BrowserBackend が付ける)。ref 解決に使う */
  frame?: unknown;
}

/** ref を付けるロール */
const refRoles = new Set([
  "button", "link", "textbox", "searchbox", "combobox", "checkbox", "radio", "switch", "slider", "spinbutton",
  "menuitem", "menuitemcheckbox", "menuitemradio", "tab", "option", "listbox", "menu", "menubar", "textarea",
  "webarea", "dialog", "alertdialog", "tree", "treeitem", "grid", "gridcell", "row", "cell", "columnheader", "rowheader",
  "scrollbar", "progressbar", "img", "image", "heading", "region", "navigation", "main", "form", "banner", "contentinfo",
  "search", "article", "list", "listitem", "table", "video", "audio", "canvas", "iframe",
]);
const collapseRoles = new Set(["generic", "none", "presentation", "group", "paragraph", "section", "inlinetextbox", "ignored", "labeltext", "menulistpopup", "listmarker"]);
const stateProps: Record<string, (v: unknown) => string | null> = {
  focused: (v) => (v ? "focused" : null),
  disabled: (v) => (v ? "disabled" : null),
  checked: (v) => (v === true || v === "true" ? "checked" : v === "mixed" ? "mixed" : v === false || v === "false" ? "unchecked" : null),
  pressed: (v) => (v === true || v === "true" ? "pressed" : null),
  expanded: (v) => (v ? "expanded" : "collapsed"),
  selected: (v) => (v ? "selected" : null),
  required: (v) => (v ? "required" : null),
  readonly: (v) => (v ? "readonly" : null),
  invalid: (v) => (v && v !== "false" ? "invalid" : null),
};

export function normalizeRole(raw: string): string {
  const r = raw.toLowerCase();
  if (r === "rootwebarea") return "webarea";
  if (r === "statictext") return "text";
  return r;
}

/** フラットな CDP ノード配列からツリーを作る */
export function buildTree(nodes: CDPAXNode[], frame?: unknown): AXNode | null {
  const byId = new Map(nodes.map((n) => [n.nodeId, n]));
  const root = nodes.find((n) => !n.parentId) ?? nodes[0];
  if (!root) return null;

  function convert(n: CDPAXNode): AXNode | null {
    const role = n.ignored ? "ignored" : normalizeRole(n.role?.value ?? "generic");
    if (role === "inlinetextbox") return null;
    const props = n.properties ?? [];
    const states: string[] = [];
    let level: unknown;
    for (const p of props) {
      if (p.name === "level") level = p.value.value;
      const f = stateProps[p.name];
      if (f) { const s = f(p.value.value); if (s) states.push(s); }
    }
    let title = n.name?.value?.trim() || undefined;
    let value: AXNode["value"];
    const v = n.value?.value;
    if (role === "text") { if (!title && typeof v === "string") title = v; }
    else if (v !== undefined && v !== null && v !== "") value = v as AXNode["value"];
    const roleLabel = role === "heading" && level ? `heading[h${level}]` : role;
    const actionable = refRoles.has(role) && !(role === "img" && !title);
    const node: AXNode = { role: roleLabel, title, value, states, actionable, backendNodeId: n.backendDOMNodeId, children: [], matched: false, frame };
    for (const cid of n.childIds ?? []) {
      const c = byId.get(cid);
      if (c) { const cn = convert(c); if (cn) node.children.push(cn); }
    }
    return node;
  }
  return convert(root);
}

const isBoring = (n: AXNode) => collapseRoles.has(n.role) && !n.title && n.value === undefined && !n.matched;

/** 子を整理する: 畳み込み + 親と同じ静的テキストの除去 (button "OK" > text "OK") */
function tidyChildren(node: AXNode) {
  node.children = node.children.flatMap(collapse);
  if (node.title) node.children = node.children.filter((c) => !(c.role === "text" && c.title === node.title && !c.matched && c.children.length === 0));
}

/** interestingOnly: 無名の generic 等は子を親に繰り上げる */
export function collapse(node: AXNode): AXNode[] {
  tidyChildren(node);
  return isBoring(node) ? node.children : [node];
}

export function matcher(q: FindQuery): (n: AXNode) => boolean {
  const role = q.role?.toLowerCase();
  const cmp = (s: string | undefined, needle: string) =>
    s !== undefined && (q.exact ? s === needle : s.toLowerCase().includes(needle.toLowerCase()));
  return (n) => {
    if (role && n.role !== role && !n.role.startsWith(role + "[")) return false;
    if (q.title !== undefined && !cmp(n.title, q.title)) return false;
    if (q.value !== undefined && !cmp(n.value === undefined ? undefined : String(n.value), q.value)) return false;
    return true;
  };
}

/** ui.find: 一致ノード (子孫含む) とそこへ至る祖先だけ残す。無名ラッパーの祖先は畳む */
export function prune(node: AXNode): AXNode[] {
  if (node.matched) { tidyChildren(node); return [node]; }
  node.children = node.children.flatMap(prune);
  if (!node.children.length) return [];
  return isBoring(node) ? node.children : [node];
}

export function markMatches(node: AXNode, match: (n: AXNode) => boolean): number {
  node.matched = match(node);
  let count = node.matched ? 1 : 0;
  for (const c of node.children) count += markMatches(c, match);
  return count;
}

export interface RefTarget { backendNodeId: number; frame?: unknown }
export interface Rendered { text: string; refs: Map<string, RefTarget>; truncated: boolean }

/** PROTOCOL.md §6 の記法に整形。ref → backendDOMNodeId */
export function render(root: AXNode, opts: { maxDepth: number; maxNodes: number; valueLimit?: number }): Rendered {
  const limit = opts.valueLimit ?? 80;
  const lines: string[] = [];
  const refs = new Map<string, RefTarget>();
  let count = 0, truncated = false;
  const q = (s: string) => {
    let t = s.replace(/\n/g, "⏎");
    if (t.length > limit) t = t.slice(0, limit) + "…";
    return `"${t.replace(/"/g, '\\"')}"`;
  };
  function walk(n: AXNode, depth: number) {
    if (count >= opts.maxNodes) { truncated = true; return; }
    count++;
    let line = "  ".repeat(depth) + "- " + n.role;
    if (n.title) line += " " + q(n.title);
    if ((n.actionable || n.matched) && n.backendNodeId !== undefined) {
      const ref = `e${refs.size + 1}`;
      refs.set(ref, { backendNodeId: n.backendNodeId, frame: n.frame });
      line += ` [ref=${ref}]`;
    }
    for (const s of n.states) line += ` [${s}]`;
    if (n.value !== undefined) line += ": " + (typeof n.value === "string" ? q(n.value) : String(n.value));
    lines.push(line);
    if (depth >= opts.maxDepth) { if (n.children.length) truncated = true; return; }
    for (const c of n.children) walk(c, depth + 1);
  }
  walk(root, 0);
  return { text: lines.join("\n"), refs, truncated };
}
