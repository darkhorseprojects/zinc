import { createEffect, createSignal } from "solid-js";
import {
  createSolidLexicalEditor,
  HistoryPlugin,
  ImportMdxPlugin,
  LexicalComposer,
  LexicalContentEditable,
  LexicalDecorators,
  ListPlugin,
  MarkdownShortcutPlugin,
  OnChangePlugin,
  PromptBackspaceResetPlugin,
  PromptSubmitPlugin,
  RichTextPlugin,
  ThreadHandlePlugin,
  ZincDecoratorView,
  type ZincDecorator,
} from "~/thread/lexical";
import { exportLexicalToMdx, importMdxToLexical, zincLexicalNodes } from "~/thread/mdx";

export type ZincEditorHandle = {
  snapshotMdx: () => Promise<string>;
  replaceMdx: (mdx: string, baseRevision: string) => void;
  acknowledgeSave: (nextBaseRevision: string, savedMdx: string) => void;
  isDirty: () => boolean;
  baseRevision: () => string;
};

export type ZincEditorProps = {
  mdx: string;
  baseRevision?: string;
  editable: boolean;
  busy?: boolean;
  mode?: "thread" | "prompt";
  placeholder?: string;
  onDirtyChange?: (dirty: boolean) => void;
  onSubmit?: (text: string) => Promise<void> | void;
  onAppendTextConsumed?: () => void;
  bind?: (handle: ZincEditorHandle | null) => void;
};

export function ZincEditor(props: ZincEditorProps) {
  const editor = createSolidLexicalEditor({
    namespace: props.mode === "prompt" ? "zinc-prompt" : "zinc-thread",
    nodes: zincLexicalNodes,
    editable: props.editable,
    onError(error) {
      throw error;
    },
  });

  const mode = () => props.mode ?? "thread";
  const [dirty, setDirty] = createSignal(false);
  const [ready, setReady] = createSignal(false);
  const [baseRevision, setBaseRevision] = createSignal(props.baseRevision ?? "");
  const [lastImportedMdx, setLastImportedMdx] = createSignal("");
  let suppressDirty = false;

  const handle: ZincEditorHandle = {
    snapshotMdx: async () => exportLexicalToMdx(editor),
    replaceMdx: (mdx, nextBaseRevision) => importClean(mdx, nextBaseRevision),
    acknowledgeSave: (nextBaseRevision, savedMdx) => {
      suppressDirty = true;
      try {
        const currentMdx = exportLexicalToMdx(editor);
        setLastImportedMdx(savedMdx);
        setBaseRevision(nextBaseRevision);
        setDirtyState(currentMdx !== savedMdx);
      } finally {
        queueMicrotask(() => { suppressDirty = false; });
      }
    },
    isDirty: dirty,
    baseRevision,
  };

  createEffect(() => {
    editor.setEditable(props.editable);
  });

  function importClean(mdx: string, nextBaseRevision: string) {
    suppressDirty = true;
    try {
      importMdxToLexical(editor, mdx);
      setLastImportedMdx(mdx);
      setBaseRevision(nextBaseRevision);
      setReady(true);
      setDirtyState(false);
    } finally {
      queueMicrotask(() => { suppressDirty = false; });
    }
  }

  function setDirtyState(nextDirty: boolean) {
    setDirty(nextDirty);
    props.onDirtyChange?.(nextDirty);
  }

  return (
    <LexicalComposer editor={editor}>
      <div
        class={mode() === "prompt" ? "prompt-editor-container" : "thread-editor thread-lexical"}
        data-ready={mode() === "prompt" || ready() ? "true" : "false"}
        data-busy={props.busy ? "true" : "false"}
      >
        <RichTextPlugin
          contentEditable={
            <LexicalContentEditable
              class={mode() === "prompt" ? "prompt-input" : "thread-lexical-root"}
              ariaLabel={mode() === "prompt" ? "Draft MDX" : "MDX thread"}
              spellcheck={false}
              showPlaceholder={mode() === "prompt" || ready()}
              placeholder={<div class="zinc-editor-placeholder">{props.placeholder ?? "Write…"}</div>}
            />
          }
          decorators={<LexicalDecorators<ZincDecorator> render={(decorator) => <ZincDecoratorView decorator={decorator} />} />}
        />
        <HistoryPlugin delay={300} />
        <ListPlugin />
        <MarkdownShortcutPlugin />
        <ImportMdxPlugin
          mode={mode()}
          mdx={props.mdx ?? ""}
          baseRevision={props.baseRevision ?? ""}
          dirty={dirty()}
          lastImportedMdx={lastImportedMdx()}
          importClean={importClean}
          onAppendTextConsumed={props.onAppendTextConsumed}
        />
        <OnChangePlugin
          enabled={mode() !== "prompt"}
          onChange={() => {
            if (suppressDirty) return;
            setDirtyState(true);
          }}
        />
        <PromptBackspaceResetPlugin enabled={mode() === "prompt"} />
        <PromptSubmitPlugin enabled={mode() === "prompt"} editable={props.editable} onSubmit={props.onSubmit} />
        <ThreadHandlePlugin enabled={mode() !== "prompt"} handle={handle} bind={props.bind} />
      </div>
    </LexicalComposer>
  );
}

export default ZincEditor;
