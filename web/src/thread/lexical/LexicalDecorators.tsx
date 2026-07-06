import { createSignal, For, onCleanup, onMount, type JSX } from "solid-js";
import { Portal } from "solid-js/web";
import type { NodeKey } from "lexical";
import { useLexicalEditor } from "./LexicalEditorProvider";

export type DecoratorRenderer<T> = (decorator: T, key: NodeKey) => JSX.Element;

export function LexicalDecorators<T>(props: {
  render: DecoratorRenderer<T>;
}) {
  const editor = useLexicalEditor();
  const [decorators, setDecorators] = createSignal<Record<NodeKey, T>>({ ...editor.getDecorators<T>() });
  let unregister: (() => void) | undefined;

  onMount(() => {
    setDecorators({ ...editor.getDecorators<T>() });
    unregister = editor.registerDecoratorListener<T>((next) => {
      setDecorators({ ...next });
    });
  });

  onCleanup(() => unregister?.());

  return (
    <For each={Object.entries(decorators()) as [NodeKey, T][]}> 
      {([key, decorator]) => {
        const mount = editor.getElementByKey(key);
        return mount ? <Portal mount={mount}>{props.render(decorator, key)}</Portal> : null;
      }}
    </For>
  );
}
