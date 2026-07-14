import { $createParagraphNode, $getRoot, COMMAND_PRIORITY_HIGH, KEY_ENTER_COMMAND } from "lexical";
import { createEffect, onCleanup, onMount } from "solid-js";
import { markdownToNodes } from "../markdown";
import { documentFromNodes, encodeBlock, type SerializedDocument } from "./codec";
import { createZincEditor, registerCore } from "./core";
import { EquationPlugin } from "./EquationPlugin";
import { LexicalComposer, LexicalContentEditable, useLexicalEditor } from "./lexical";
import { MarkdownPlugin } from "./MarkdownPlugin";

export function PromptEditor(props: { editable: boolean; appendText?: string; onAppendConsumed?(): void; onSubmit(markdown: string): Promise<void> | void }) {
  const editor = createZincEditor("zinc-prompt", props.editable); let appended = "";
  editor.setEditorState(editor.parseEditorState(documentFromNodes([]) as never), { tag: "zinc-prompt-open" });
  createEffect(() => editor.setEditable(props.editable));
  createEffect(() => { const value = props.appendText ?? ""; if (!value || value === appended) return; appended = value; importMarkdown(editor, value); props.onAppendConsumed?.(); });
  const source = () => { const bytes = encodeBlock("markdown", editor.getEditorState().toJSON() as unknown as SerializedDocument); return JSON.parse(new TextDecoder().decode(bytes)).text as string; };
  const clear = () => editor.update(() => { const root = $getRoot(); root.clear(); root.append($createParagraphNode()); root.selectEnd(); }, { tag: "zinc-prompt-clear" });
  return <LexicalComposer editor={editor}><div class="prompt-editor-container"><LexicalContentEditable class="prompt-input" ariaLabel="Draft" spellcheck={false} placeholder={<div class="zinc-editor-placeholder">Write…</div>} /><PromptPlugins editable={props.editable} source={source} clear={clear} submit={props.onSubmit} /><MarkdownPlugin enabled /><EquationPlugin editable={props.editable} /></div></LexicalComposer>;
}
function PromptPlugins(props: { editable: boolean; source(): string; clear(): void; submit(value: string): Promise<void> | void }) {
  const editor = useLexicalEditor(); let unregister = () => {}, submitting = false;
  onMount(() => { const core = registerCore(editor, true), command = editor.registerCommand(KEY_ENTER_COMMAND, (event) => { if (event?.shiftKey) return false; event?.preventDefault(); const value = props.source(); if (!props.editable || submitting || !value.trim()) return true; submitting = true; props.clear(); void Promise.resolve(props.submit(value)).finally(() => { submitting = false; }); return true; }, COMMAND_PRIORITY_HIGH); unregister = () => { command(); core(); }; });
  onCleanup(() => unregister()); return null;
}
function importMarkdown(editor: ReturnType<typeof createZincEditor>, markdown: string) { const current = editor.getEditorState().toJSON() as unknown as SerializedDocument, source = JSON.parse(new TextDecoder().decode(encodeBlock("markdown", current))).text as string, combined = [source, markdown].filter(Boolean).join("\n\n"); editor.setEditorState(editor.parseEditorState(documentFromNodes(markdownToNodes(combined)) as never), { tag: "zinc-prompt-append" }); editor.focus(() => $getRoot().selectEnd()); }
