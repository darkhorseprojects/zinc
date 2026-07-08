import { createEmptyHistoryState, registerHistory } from "@lexical/history";
import { ListItemNode, ListNode, registerList } from "@lexical/list";
import { registerMarkdownShortcuts } from "@lexical/markdown";
import { registerRichText } from "@lexical/rich-text";
import { $createParagraphNode, $getRoot, COMMAND_PRIORITY_BEFORE_EDITOR, HISTORY_MERGE_TAG, KEY_ENTER_COMMAND, type EditorState, type LexicalEditor } from "lexical";
import { createEffect, onCleanup, onMount, type JSX } from "solid-js";
import { exportLexicalToMdx, ZINC_MARKDOWN_TRANSFORMERS } from "~/thread/mdx";
import type { ZincEditorHandle } from "~/thread/ZincEditor";
import { useLexicalEditor } from "./LexicalEditorProvider";

export function RichTextPlugin(props: { contentEditable: JSX.Element; decorators?: JSX.Element }) {
  const editor = useLexicalEditor();
  let unregister = () => {};
  onMount(() => { unregister = registerRichText(editor); });
  onCleanup(() => unregister());
  return <>{props.contentEditable}{props.decorators}</>;
}

export function HistoryPlugin(props: { delay?: number }) {
  const editor = useLexicalEditor();
  const historyState = createEmptyHistoryState();
  let unregister = () => {};
  onMount(() => { unregister = registerHistory(editor, historyState, props.delay ?? 300); });
  onCleanup(() => unregister());
  return null;
}

export function ListPlugin() {
  const editor = useLexicalEditor();
  let unregister = () => {};
  onMount(() => {
    if (!editor.hasNodes([ListNode, ListItemNode])) throw new Error("ListPlugin requires ListNode and ListItemNode to be registered.");
    unregister = registerList(editor);
  });
  onCleanup(() => unregister());
  return null;
}

export function MarkdownShortcutPlugin() {
  const editor = useLexicalEditor();
  let unregister = () => {};
  onMount(() => { unregister = registerMarkdownShortcuts(editor, ZINC_MARKDOWN_TRANSFORMERS); });
  onCleanup(() => unregister());
  return null;
}

export function OnChangePlugin(props: {
  enabled?: boolean;
  ignoreHistoryMergeTagChange?: boolean;
  ignoreSelectionChange?: boolean;
  onChange: (editorState: EditorState, editor: LexicalEditor, tags: Set<string>) => void;
}) {
  const editor = useLexicalEditor();
  let unregister = () => {};
  onMount(() => {
    unregister = editor.registerUpdateListener(({ editorState, dirtyElements, dirtyLeaves, prevEditorState, tags }) => {
      if (props.enabled === false) return;
      if ((props.ignoreSelectionChange ?? true) && dirtyElements.size === 0 && dirtyLeaves.size === 0) return;
      if ((props.ignoreHistoryMergeTagChange ?? true) && tags.has(HISTORY_MERGE_TAG)) return;
      if (prevEditorState.isEmpty()) return;
      props.onChange(editorState, editor, tags);
    });
  });
  onCleanup(() => unregister());
  return null;
}

export function ThreadHandlePlugin(props: { enabled: boolean; handle: ZincEditorHandle; bind?: (handle: ZincEditorHandle | null) => void }) {
  let bound = false;
  createEffect(() => {
    if (props.enabled && !bound) {
      props.bind?.(props.handle);
      bound = true;
    } else if (!props.enabled && bound) {
      props.bind?.(null);
      bound = false;
    }
  });
  onCleanup(() => { if (bound) props.bind?.(null); });
  return null;
}

export function ImportMdxPlugin(props: {
  mode: "thread" | "prompt";
  mdx: string;
  baseRevision: string;
  dirty: boolean;
  lastImportedMdx: string;
  importClean: (mdx: string, baseRevision: string) => void;
  onAppendTextConsumed?: () => void;
}) {
  let initialized = false;
  createEffect(() => {
    const mode = props.mode;
    const mdx = props.mdx ?? "";
    const baseRevision = props.baseRevision ?? "";

    if (!initialized) {
      initialized = true;
      props.importClean(mdx, baseRevision);
      return;
    }
    if (mode === "thread") {
      if (mdx !== props.lastImportedMdx && !props.dirty) props.importClean(mdx, baseRevision);
      return;
    }
    if (mdx) {
      props.importClean(mdx, "");
      props.onAppendTextConsumed?.();
    }
  });
  return null;
}

export function PromptSubmitPlugin(props: { enabled: boolean; editable: boolean; onSubmit?: (text: string) => Promise<void> | void }) {
  const editor = useLexicalEditor();
  let unregister = () => {};
  let submitting = false;

  onMount(() => {
    unregister = editor.registerCommand(
      KEY_ENTER_COMMAND,
      (event) => {
        if (!props.enabled || event?.shiftKey) return false;
        event?.preventDefault();
        void submit();
        return true;
      },
      COMMAND_PRIORITY_BEFORE_EDITOR,
    );
  });
  onCleanup(() => unregister());

  async function submit() {
    if (submitting || !props.editable) return;
    const text = exportLexicalToMdx(editor);
    if (!text.trim()) return;

    submitting = true;
    editor.update(() => {
      const root = $getRoot();
      root.clear();
      const paragraph = $createParagraphNode();
      root.append(paragraph);
      paragraph.select();
    });

    try {
      await props.onSubmit?.(text);
    } finally {
      submitting = false;
    }
  }

  return null;
}
