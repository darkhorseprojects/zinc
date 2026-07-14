import { $getRoot, $isElementNode, createEditor, type LexicalEditor } from "lexical";
import { createEffect, onCleanup, onMount } from "solid-js";
import { BlockBoundaryPlugin } from "./BlockBoundaryPlugin";
import { decodeBlock, documentNodes, encodeBlock, type BlockFormat, type SerializedDocument } from "./codec";
import { registerCore, createZincEditor } from "./core";
import { EquationPlugin } from "./EquationPlugin";
import { LexicalComposer, LexicalContentEditable, useLexicalEditor } from "./lexical";
import { MarkdownPlugin } from "./MarkdownPlugin";
import { TsxPlugin } from "./TsxPlugin";

export type BlockEditorHandle = {
  capture(): Uint8Array;
  replace(bytes: Uint8Array): void;
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

export function BlockEditor(props: BlockEditorProps) {
  let decoded = decodeBlock(props.bytes), format: BlockFormat = decoded.format, suppress = true, queued = false;
  const editor = createZincEditor(`zinc-block-${props.id}`, props.editable && decoded.editable);
  editor.setEditorState(editor.parseEditorState(decoded.document as never), { tag: "zinc-block-open" }); suppress = false;

  const capture = () => encodeBlock(format, editor.getEditorState().toJSON() as unknown as SerializedDocument);
  const source = () => { try { const value = JSON.parse(new TextDecoder().decode(capture())); return typeof value.text === "string" ? value.text : ""; } catch { return ""; } };
  const handle: BlockEditorHandle = {
    capture,
    source,
    editor,
    replace(bytes) { decoded = decodeBlock(bytes); format = decoded.format; suppress = true; editor.setEditorState(editor.parseEditorState(decoded.document as never), { tag: "zinc-block-replace" }); queueMicrotask(() => { suppress = false; }); },
    focus(edge = "end") { editor.focus(() => { const root = $getRoot(), node = edge === "start" ? root.getFirstDescendant() : root.getLastDescendant(); if (node) edge === "start" ? node.selectStart() : node.selectEnd(); }); },
  };

  createEffect(() => editor.setEditable(props.editable && decoded.editable));
  onMount(() => props.bind?.(handle)); onCleanup(() => props.bind?.(null));

  return (
    <LexicalComposer editor={editor}>
      <div class="block-editor" data-format={format} onFocusIn={() => props.onFocusChange?.(true)} onFocusOut={() => queueMicrotask(() => props.onFocusChange?.(Boolean(editor.getRootElement()?.contains(document.activeElement))))}>
        <LexicalContentEditable class="block-editor-root" ariaLabel="Thread block" spellcheck={false} />
        <CorePlugin editable={props.editable && decoded.editable} onChange={() => {
          if (suppress || queued || !props.onChange) return; queued = true; queueMicrotask(() => { queued = false; if (!suppress) props.onChange?.(capture()); });
        }} />
        <MarkdownPlugin enabled={format === "markdown" || format === "reasoning"} />
        <EquationPlugin editable={props.editable && decoded.editable} />
        <TsxPlugin enabled={format === "tsx"} />
        <BlockBoundaryPlugin enabled={props.editable && decoded.editable} source={source} onSplit={props.onSplit} onMerge={props.onMerge} onNavigate={props.onNavigate} />
      </div>
    </LexicalComposer>
  );
}

function CorePlugin(props: { editable: boolean; onChange(): void }) {
  const editor = useLexicalEditor(); let unregister = () => {};
  onMount(() => { unregister = registerCore(editor, props.editable); });
  const listener = editor.registerUpdateListener(({ dirtyElements, dirtyLeaves, tags }) => { if (dirtyElements.size === 0 && dirtyLeaves.size === 0 || tags.has("zinc-block-open") || tags.has("zinc-block-replace") || tags.has("zinc-tsx-toggle")) return; props.onChange(); });
  onCleanup(() => { listener(); unregister(); }); return null;
}
