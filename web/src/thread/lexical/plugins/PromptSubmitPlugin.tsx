import { $createParagraphNode, $getRoot, COMMAND_PRIORITY_BEFORE_EDITOR, KEY_ENTER_COMMAND } from "lexical";
import { onCleanup, onMount } from "solid-js";
import { exportLexicalToMdx } from "~/thread/mdx";
import { useLexicalEditor } from "../LexicalEditorProvider";

export function PromptSubmitPlugin(props: {
  enabled: boolean;
  editable: boolean;
  onSubmit?: (text: string) => Promise<void> | void;
}) {
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
