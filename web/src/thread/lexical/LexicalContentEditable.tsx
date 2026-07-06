import { $canShowPlaceholder } from "@lexical/text";
import { Show, createSignal, onCleanup, onMount, type JSX } from "solid-js";
import { useLexicalEditor } from "./LexicalEditorProvider";

export function LexicalContentEditable(props: {
  class?: string;
  id?: string;
  ariaLabel?: string;
  spellcheck?: boolean;
  placeholder?: JSX.Element;
  showPlaceholder?: boolean;
}) {
  const editor = useLexicalEditor();
  const [editable, setEditable] = createSignal(editor.isEditable());
  const [canShowPlaceholder, setCanShowPlaceholder] = createSignal(false);
  let root: HTMLDivElement | undefined;
  let unregisterRoot = () => {};
  let unregisterEditable = () => {};
  let unregisterUpdate = () => {};

  onMount(() => {
    if (!root) return;
    editor.setRootElement(root);
    syncPlaceholder(editor.isComposing());

    unregisterEditable = editor.registerEditableListener((nextEditable) => {
      setEditable(nextEditable);
      syncPlaceholder(editor.isComposing());
    });
    unregisterUpdate = editor.registerUpdateListener(({ editorState }) => {
      editorState.read(() => {
        setCanShowPlaceholder($canShowPlaceholder(editor.isComposing()));
      });
    });
    unregisterRoot = () => {
      if (editor.getRootElement() === root) editor.setRootElement(null);
    };
  });

  onCleanup(() => {
    unregisterUpdate();
    unregisterEditable();
    unregisterRoot();
  });

  function syncPlaceholder(isComposing: boolean) {
    editor.getEditorState().read(() => {
      setCanShowPlaceholder($canShowPlaceholder(isComposing));
    });
  }

  return (
    <div style={{ position: "relative", width: "100%", display: "flex", "flex-direction": "column" }}>
      <div
        ref={root}
        id={props.id}
        class={props.class}
        contentEditable={editable()}
        role="textbox"
        aria-label={props.ariaLabel}
        aria-multiline="true"
        spellcheck={props.spellcheck ?? false}
        data-lexical-editor="true"
      />
      <Show when={(props.showPlaceholder ?? true) && canShowPlaceholder()}>{props.placeholder}</Show>
    </div>
  );
}
