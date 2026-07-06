import { onCleanup, onMount, type JSX } from "solid-js";
import { registerRichText } from "@lexical/rich-text";
import { useLexicalEditor } from "../LexicalEditorProvider";

export function RichTextPlugin(props: {
  contentEditable: JSX.Element;
  decorators?: JSX.Element;
}) {
  const editor = useLexicalEditor();
  let unregister = () => {};

  onMount(() => {
    unregister = registerRichText(editor);
  });

  onCleanup(() => unregister());

  return (
    <>
      {props.contentEditable}
      {props.decorators}
    </>
  );
}
