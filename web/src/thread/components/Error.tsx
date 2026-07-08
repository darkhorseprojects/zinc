import { Show } from "solid-js";
import { $getNodeByKey } from "lexical";
import { useLexicalEditor } from "~/thread/lexical/LexicalEditorProvider";
import { $isMdxComponentNode } from "~/thread/nodes";
import { autoResize } from "./textareaAutoResize";
import { stringProp, type MdxComponentProps } from "./types";

export function ErrorBlock(props: MdxComponentProps) {
  const editor = useLexicalEditor();

  const handleBodyInput = (e: InputEvent) => {
    const value = (e.target as HTMLTextAreaElement).value;
    editor.update(() => {
      const node = $getNodeByKey(props.nodeKey);
      if ($isMdxComponentNode(node)) node.setBody(value);
    });
  };

  const label = () => stringProp(props.props, "label") || "error";
  const stage = () => stringProp(props.props, "stage");

  return (
    <section class="thread-component thread-transcript-block" data-status="error">
      <div class="thread-transcript-heading">
        <span class="thread-transcript-label">{label()}</span>
        <span class="thread-transcript-status">error</span>
      </div>
      <Show when={stage()}>
        <div class="thread-transcript-meta">{stage()}</div>
      </Show>
      <textarea use:autoResize class="edit-body-textarea error-body" value={props.body} onInput={handleBodyInput} spellcheck={false} />
    </section>
  );
}

export default ErrorBlock;
