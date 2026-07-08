import { $getNodeByKey } from "lexical";
import { useLexicalEditor } from "~/thread/lexical/LexicalEditorProvider";
import { $isMdxComponentNode } from "~/thread/nodes";
import { autoResize } from "./textareaAutoResize";
import type { MdxComponentProps } from "./types";

export function Reasoning(props: MdxComponentProps) {
  const editor = useLexicalEditor();

  const handleInput = (e: InputEvent) => {
    const value = (e.target as HTMLTextAreaElement).value;
    editor.update(() => {
      const node = $getNodeByKey(props.nodeKey);
      if ($isMdxComponentNode(node)) node.setBody(value);
    });
  };

  return (
    <section class="thread-component thread-reasoning">
      <textarea use:autoResize class="edit-reasoning-textarea" value={props.body} onInput={handleInput} spellcheck={false} />
    </section>
  );
}

export default Reasoning;
