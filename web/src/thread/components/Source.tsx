import { $getNodeByKey } from "lexical";
import { useLexicalEditor } from "~/thread/lexical/LexicalEditorProvider";
import { $isMdxComponentNode } from "~/thread/nodes";
import { autoResize } from "./textareaAutoResize";
import { stringProp, type MdxComponentProps } from "./types";

export function Source(props: MdxComponentProps) {
  const editor = useLexicalEditor();

  const handleBodyInput = (e: InputEvent) => {
    const value = (e.target as HTMLTextAreaElement).value;
    editor.update(() => {
      const node = $getNodeByKey(props.nodeKey);
      if ($isMdxComponentNode(node)) node.setBody(value);
    });
  };

  const status = () => stringProp(props.props, "status") || "ok";
  const label = () => stringProp(props.props, "label") || "source";

  return (
    <section class="thread-component thread-transcript-block" data-status={status()}>
      <div class="thread-transcript-heading">
        <span class="thread-transcript-label">{label()}</span>
        <span class="thread-transcript-status">{status()}</span>
      </div>
      <textarea use:autoResize class="edit-body-textarea source-body" value={props.body} onInput={handleBodyInput} spellcheck={false} />
    </section>
  );
}

export default Source;
