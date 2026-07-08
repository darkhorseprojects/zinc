import { $getNodeByKey } from "lexical";
import { useLexicalEditor } from "~/thread/lexical/LexicalEditorProvider";
import { $isMdxComponentNode } from "~/thread/nodes";
import type { MdxComponentProps } from "./types";

/** Any component tag not in the registry. Shown as its raw MDX source, still editable, still round-trips exactly. */
export function RawBlock(props: MdxComponentProps) {
  const editor = useLexicalEditor();

  const handleInput = (e: InputEvent) => {
    const value = (e.target as HTMLTextAreaElement).value;
    editor.update(() => {
      const node = $getNodeByKey(props.nodeKey);
      if ($isMdxComponentNode(node)) node.setBody(value);
    });
  };

  return (
    <section class="thread-component thread-mdx-fragment">
      <div class="thread-transcript-heading">
        <span class="thread-transcript-label">{props.tag}</span>
      </div>
      <textarea class="edit-body-textarea raw-body" value={props.body} onInput={handleInput} spellcheck={false} />
    </section>
  );
}

export default RawBlock;
