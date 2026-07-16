import { diffWordsWithSpace } from "diff";
import { animate, utils, type JSAnimation } from "animejs";
import { $getRoot, type LexicalEditor } from "lexical";
import { createEffect, createSignal, onCleanup, onMount } from "solid-js";
import { duration, ease, motion } from "../styles/motion";
import { BlockBoundaryPlugin } from "./BlockBoundaryPlugin";
import { decodeBlock, encodeBlock, type BlockFormat, type SerializedDocument } from "./codec";
import { registerCore, createZincEditor } from "./core";
import { EquationPlugin } from "./EquationPlugin";
import { LexicalComposer, LexicalContentEditable, useLexicalEditor } from "./lexical";
import { MARKDOWN_NORMALIZE_TAG, MarkdownPlugin } from "./MarkdownPlugin";
import { TsxPlugin } from "./TsxPlugin";

export type BlockEditorHandle = {
  capture(): Uint8Array;
  replace(bytes: Uint8Array): void;
  preview(bytes: Uint8Array | null): void;
  focus(edge?: "start" | "end"): void;
  source(): string;
  editor: LexicalEditor;
};
export type BlockEditorProps = {
  id: string;
  bytes: Uint8Array;
  editable: boolean;
  onChange?(bytes: Uint8Array): void;
  onFocusChange?(focused: boolean): void;
  onSplit?(before: string, after: string): void;
  onMerge?(direction: "previous" | "next"): void;
  onNavigate?(direction: "previous" | "next"): void;
  bind?(handle: BlockEditorHandle | null): void;
};

type Presentation = { stable: HTMLElement[]; added: HTMLElement[]; removed: HTMLElement[]; insert(): void; cleanup(): void };

export function BlockEditor(props: BlockEditorProps) {
  let decoded = decodeBlock(props.bytes), suppress = true, queued = false, preview: Presentation | null = null, previewRoot: HTMLElement | null = null, previewToken = 0;
  const [format, setFormat] = createSignal<BlockFormat>(decoded.format), previewAnimations: JSAnimation[] = [];
  const editor = createZincEditor(`zinc-block-${props.id}`, props.editable && decoded.editable);
  editor.setEditorState(editor.parseEditorState(decoded.document as never), { tag: "zinc-block-open" }); suppress = false;

  const capture = () => encodeBlock(format(), editor.getEditorState().toJSON() as unknown as SerializedDocument);
  const source = () => { try { const value = JSON.parse(new TextDecoder().decode(capture())); return typeof value.text === "string" ? value.text : ""; } catch { return ""; } };
  const cancelAnimations = () => { while (previewAnimations.length) previewAnimations.pop()!.cancel(); };
  const restorePreview = () => {
    previewToken++; cancelAnimations();
    preview?.cleanup(); preview = null;
    previewRoot?.removeAttribute("data-diff-preview"); previewRoot = null;
    editor.setEditable(props.editable && decoded.editable); suppress = false;
  };
  const handle: BlockEditorHandle = {
    capture,
    source,
    editor,
    replace(bytes) { restorePreview(); decoded = decodeBlock(bytes); setFormat(decoded.format); suppress = true; editor.setEditorState(editor.parseEditorState(decoded.document as never), { tag: "zinc-block-replace" }); editor.setEditable(props.editable && decoded.editable); queueMicrotask(() => { suppress = false; }); },
    preview(bytes) { if (!bytes) leavePreview(); else enterPreview(bytes); },
    focus(edge = "end") { restorePreview(); editor.focus(() => { const root = $getRoot(), node = edge === "start" ? root.getFirstDescendant() : root.getLastDescendant(); if (node) edge === "start" ? node.selectStart() : node.selectEnd(); }); },
  };

  function enterPreview(bytes: Uint8Array) {
    const alternative = plainBlock(bytes), canonical = plainBlock(capture()); if (canonical === alternative) return leavePreview();
    restorePreview(); const root = editor.getRootElement(); if (!root) return;
    const next = createPresentation(root, canonical, alternative); if (!next) return;
    const token = ++previewToken; suppress = true; editor.setEditable(false); preview = next; previewRoot = root; root.dataset.diffPreview = "true";
    const first = positions(next.stable); next.insert();
    for (const span of next.stable) { const before = first.get(span), after = span.getBoundingClientRect(); if (before) utils.set(span, { translateX: before.left - after.left, translateY: before.top - after.top }); }
    utils.set(next.added, { opacity: 0, scaleX: .72, transformOrigin: "left center" });
    if (token !== previewToken) return;
    if (next.stable.length) previewAnimations.push(animate(next.stable, { translateX: 0, translateY: 0, duration: duration(motion.normal), ease: ease.spatial }));
    if (next.added.length) previewAnimations.push(animate(next.added, { opacity: 1, scaleX: 1, duration: duration(motion.normal), ease: ease.spatial }));
    if (next.removed.length) previewAnimations.push(animate(next.removed, { color: "var(--z-negative)", backgroundColor: "rgb(var(--z-negative-rgb) / 0.14)", duration: duration(motion.fast), ease: ease.standard }));
  }

  function leavePreview() {
    const current = preview, root = previewRoot; if (!current || !root) return;
    const token = ++previewToken; cancelAnimations();
    const collapse = () => {
      if (token !== previewToken || current !== preview) return;
      const first = positions(current.stable); current.added.forEach((node) => node.remove());
      for (const node of current.stable) { const before = first.get(node), after = node.getBoundingClientRect(); if (before) utils.set(node, { translateX: before.left - after.left, translateY: before.top - after.top }); }
      if (!current.stable.length) return restorePreview();
      previewAnimations.push(animate(current.stable, { translateX: 0, translateY: 0, color: "", backgroundColor: "", duration: duration(motion.normal), ease: ease.spatial, onComplete: () => { if (token === previewToken) restorePreview(); } }));
    };
    if (current.added.length) previewAnimations.push(animate(current.added, { opacity: 0, scaleX: .72, duration: duration(motion.reveal), ease: ease.standard, onComplete: collapse })); else collapse();
  }

  createEffect(() => editor.setEditable(props.editable && decoded.editable && !previewRoot));
  createEffect(() => { const bytes = props.bytes; if (!sameBytes(bytes, capture())) handle.replace(bytes); });
  onMount(() => {
    props.bind?.(handle);
    const root = editor.getRootElement();
    const cancel = () => restorePreview();
    root?.addEventListener("beforeinput", cancel, true); root?.addEventListener("compositionstart", cancel, true); root?.addEventListener("pointerdown", cancel, true);
    const unregister = editor.registerUpdateListener(() => { if (previewRoot) restorePreview(); });
    onCleanup(() => { root?.removeEventListener("beforeinput", cancel, true); root?.removeEventListener("compositionstart", cancel, true); root?.removeEventListener("pointerdown", cancel, true); unregister(); });
  });
  onCleanup(() => { restorePreview(); props.bind?.(null); });

  return <LexicalComposer editor={editor}>
    <div class="block-editor" data-format={format()} onFocusIn={() => props.onFocusChange?.(true)} onFocusOut={() => queueMicrotask(() => props.onFocusChange?.(Boolean(editor.getRootElement()?.contains(document.activeElement))))}>
      <LexicalContentEditable class="block-editor-root" ariaLabel="Thread block" spellcheck={false} />
      <CorePlugin editable={props.editable && decoded.editable} onChange={() => { if (suppress || queued || !props.onChange) return; queued = true; queueMicrotask(() => { queued = false; if (!suppress) props.onChange?.(capture()); }); }} />
      <MarkdownPlugin enabled={format() === "markdown" || format() === "reasoning"} />
      <EquationPlugin editable={props.editable && decoded.editable} />
      <TsxPlugin enabled={format() === "tsx"} />
      <BlockBoundaryPlugin enabled={props.editable && decoded.editable && format() === "markdown"} source={source} onSplit={props.onSplit} onMerge={props.onMerge} onNavigate={props.onNavigate} />
    </div>
  </LexicalComposer>;
}

function createPresentation(root: HTMLElement, canonical: string, alternative: string): Presentation | null {
  const textNodes: Text[] = [], walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  while (walker.nextNode()) textNodes.push(walker.currentNode as Text);
  const rendered = textNodes.map((node) => node.data).join("");
  const current = rendered === canonical ? canonical : rendered;
  if (current === alternative) return null;
  const changes = diffWordsWithSpace(current, alternative), segments: Array<{ from: number; to: number; removed: boolean }> = [], additions: Array<{ at: number; value: string }> = [];
  let at = 0;
  for (const change of changes) {
    if (change.added) additions.push({ at, value: change.value });
    else { segments.push({ from: at, to: at + change.value.length, removed: Boolean(change.removed) }); at += change.value.length; }
  }
  const stable: HTMLElement[] = [], removed: HTMLElement[] = [], added: HTMLElement[] = [], markers: Comment[] = [], parents = new Set<Node>();
  let base = 0;
  for (let nodeIndex = 0; nodeIndex < textNodes.length; nodeIndex++) {
    const text = textNodes[nodeIndex], start = base, end = start + text.data.length; base = end;
    if (!text.parentNode || !text.data.length) continue;
    const fragment = document.createDocumentFragment(), cuts = new Set([start, end]);
    for (const segment of segments) { if (segment.from > start && segment.from < end) cuts.add(segment.from); if (segment.to > start && segment.to < end) cuts.add(segment.to); }
    const localAdditions = additions.filter((addition) => addition.at >= start && (addition.at < end || nodeIndex === textNodes.length - 1));
    for (const addition of localAdditions) cuts.add(addition.at);
    const points = [...cuts].sort((left, right) => left - right);
    for (let index = 0; index < points.length; index++) {
      const point = points[index];
      for (const addition of localAdditions.filter((value) => value.at === point)) { const marker = document.createComment("zinc-diff"); (marker as Comment & { value?: string }).value = addition.value; markers.push(marker); fragment.append(marker); }
      const next = points[index + 1]; if (next === undefined || next === point) continue;
      const segment = segments.find((value) => point >= value.from && point < value.to), span = document.createElement("span");
      span.dataset.diffFragment = "true"; span.className = segment?.removed ? "diff-removed" : "diff-same"; span.textContent = text.data.slice(point - start, next - start); stable.push(span); if (segment?.removed) removed.push(span); fragment.append(span);
    }
    parents.add(text.parentNode); text.replaceWith(fragment);
  }
  const insert = () => { for (const marker of markers) { const span = document.createElement("span"); span.dataset.diffFragment = "true"; span.className = "diff-added"; span.textContent = (marker as Comment & { value?: string }).value ?? ""; added.push(span); marker.replaceWith(span); } };
  const cleanup = () => { for (const node of added) node.remove(); for (const node of stable) if (node.isConnected) node.replaceWith(document.createTextNode(node.textContent ?? "")); for (const marker of markers) marker.remove(); for (const parent of parents) parent.normalize(); };
  return { stable, added, removed, insert, cleanup };
}

function positions(elements: HTMLElement[]) { return new Map(elements.map((element) => [element, element.getBoundingClientRect()])); }
function plainBlock(bytes: Uint8Array) { try { const value = JSON.parse(new TextDecoder().decode(bytes)); return typeof value.text === "string" ? value.text : JSON.stringify(value, null, 2); } catch { return new TextDecoder().decode(bytes); } }
function sameBytes(left: Uint8Array, right: Uint8Array) { return left.byteLength === right.byteLength && left.every((value, index) => value === right[index]); }

function CorePlugin(props: { editable: boolean; onChange(): void }) {
  const editor = useLexicalEditor(); let unregister = () => {};
  onMount(() => { unregister = registerCore(editor, props.editable); });
  const listener = editor.registerUpdateListener(({ dirtyElements, dirtyLeaves, tags }) => {
    if (dirtyElements.size === 0 && dirtyLeaves.size === 0 || tags.has("zinc-block-open") || tags.has("zinc-block-replace") || tags.has("zinc-tsx-toggle") || tags.has(MARKDOWN_NORMALIZE_TAG)) return;
    props.onChange();
  });
  onCleanup(() => { listener(); unregister(); }); return null;
}
