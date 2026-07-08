import { Show } from "solid-js";
import { $getNodeByKey } from "lexical";
import { useLexicalEditor } from "~/thread/lexical/LexicalEditorProvider";
import { $isMdxComponentNode } from "~/thread/nodes";
import { autoResize } from "./textareaAutoResize";
import { stringProp, type MdxComponentProps } from "./types";

export function Shell(props: MdxComponentProps) {
  const editor = useLexicalEditor();

  const handleCmdInput = (e: InputEvent) => {
    const value = (e.target as HTMLInputElement).value;
    editor.update(() => {
      const node = $getNodeByKey(props.nodeKey);
      if ($isMdxComponentNode(node)) node.setProp("cmd", value);
    });
  };

  const handleBodyInput = (e: InputEvent) => {
    const value = (e.target as HTMLTextAreaElement).value;
    editor.update(() => {
      const node = $getNodeByKey(props.nodeKey);
      if ($isMdxComponentNode(node)) node.setBody(value);
    });
  };

  const status = () => stringProp(props.props, "status") || "pending";
  const label = () => stringProp(props.props, "label") || "shell";
  const exit = () => props.props.exit;
  const meta = () => (typeof exit() === "number" ? `exit ${exit()}` : "");

  return (
    <section class="thread-component thread-transcript-block" data-status={status()}>
      <div class="thread-transcript-heading">
        <span class="thread-transcript-label">{label()}</span>
        <input class="edit-cmd-input" value={stringProp(props.props, "cmd")} onInput={handleCmdInput} spellcheck={false} />
        <span class="thread-transcript-status">{status()}</span>
      </div>
      <Show when={meta()}>
        <div class="thread-transcript-meta">{meta()}</div>
      </Show>
      <textarea use:autoResize class="edit-body-textarea" value={props.body} onInput={handleBodyInput} spellcheck={false} />
    </section>
  );
}

export default Shell;
