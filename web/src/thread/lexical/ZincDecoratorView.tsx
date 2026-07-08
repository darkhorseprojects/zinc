import { Match, Show, Switch, onMount, createEffect } from "solid-js";
import { $getNodeByKey, type NodeKey } from "lexical";
import { useLexicalEditor } from "./LexicalEditorProvider";
import {
  $isReasoningNode,
  $isCommandNode,
  $isErrorNode,
  $isSourceNode,
  type MdxSourceDecorator,
  type ThreadComponentDecorator,
  type ReasoningDecorator,
  type CommandDecorator,
  type ErrorDecorator,
  type SourceDecorator,
} from "~/thread/nodes";

export type ZincDecorator = ThreadComponentDecorator | MdxSourceDecorator;

export function ZincDecoratorView(props: { decorator: ZincDecorator }) {
  return (
    <Switch>
      <Match when={props.decorator.kind === "Reasoning" ? props.decorator : null}>
        {(decorator) => <ReasoningView decorator={decorator()} />}
      </Match>
      <Match when={props.decorator.kind === "Command" ? props.decorator : null}>
        {(decorator) => <CommandView decorator={decorator()} />}
      </Match>
      <Match when={props.decorator.kind === "Error" ? props.decorator : null}>
        {(decorator) => <ErrorView decorator={decorator()} />}
      </Match>
      <Match when={props.decorator.kind === "Source" ? props.decorator : null}>
        {(decorator) => <SourceView decorator={decorator()} />}
      </Match>
      <Match when={props.decorator.kind === "MdxSource" ? props.decorator : null}>
        {(decorator) => (
          <section class="thread-component thread-mdx-fragment">
            <pre>{decorator().source}</pre>
          </section>
        )}
      </Match>
    </Switch>
  );
}

function autoResize(el: HTMLTextAreaElement) {
  const resize = () => {
    el.style.height = "auto";
    el.style.height = `${el.scrollHeight}px`;
  };
  el.addEventListener("input", resize);
  // Auto-resize when value changes reactively
  onMount(() => {
    setTimeout(resize, 0);
  });
}

// Solid-JS directive registration for TypeScript
declare module "solid-js" {
  namespace JSX {
    interface Directives {
      autoResize: true;
    }
  }
}

function ReasoningView(props: { decorator: ReasoningDecorator }) {
  const editor = useLexicalEditor();
  let textareaRef: HTMLTextAreaElement | undefined;

  const handleInput = (e: InputEvent) => {
    const val = (e.target as HTMLTextAreaElement).value;
    editor.update(() => {
      const node = $getNodeByKey(props.decorator.nodeKey);
      if ($isReasoningNode(node)) node.setText(val);
    });
  };

  return (
    <section class="thread-component thread-reasoning">
      <textarea
        ref={textareaRef}
        use:autoResize
        class="edit-reasoning-textarea"
        value={props.decorator.text}
        onInput={handleInput}
        spellcheck={false}
      />
    </section>
  );
}

function CommandView(props: { decorator: CommandDecorator }) {
  const editor = useLexicalEditor();
  let bodyRef: HTMLTextAreaElement | undefined;

  const handleCmdInput = (e: InputEvent) => {
    const val = (e.target as HTMLInputElement).value;
    editor.update(() => {
      const node = $getNodeByKey(props.decorator.nodeKey);
      if ($isCommandNode(node)) node.setCmd(val);
    });
  };

  const handleBodyInput = (e: InputEvent) => {
    const val = (e.target as HTMLTextAreaElement).value;
    editor.update(() => {
      const node = $getNodeByKey(props.decorator.nodeKey);
      if ($isCommandNode(node)) node.setBody(val);
    });
  };

  const title = () => props.decorator.label || "command";
  const meta = () => [props.decorator.exit !== null ? `exit ${props.decorator.exit}` : ""].filter(Boolean).join(" · ");

  return (
    <section class="thread-component thread-transcript-block" data-status={props.decorator.status}>
      <div class="thread-transcript-heading">
        <span class="thread-transcript-label">{title()}</span>
        <input
          class="edit-cmd-input"
          value={props.decorator.cmd}
          onInput={handleCmdInput}
          spellcheck={false}
        />
        <span class="thread-transcript-status">{props.decorator.status}</span>
      </div>
      <Show when={meta()}>
        <div class="thread-transcript-meta">{meta()}</div>
      </Show>
      <textarea
        ref={bodyRef}
        use:autoResize
        class="edit-body-textarea"
        onInput={handleBodyInput}
        spellcheck={false}
        value={props.decorator.body}
      />
    </section>
  );
}

function ErrorView(props: { decorator: ErrorDecorator }) {
  const editor = useLexicalEditor();
  let bodyRef: HTMLTextAreaElement | undefined;

  const handleBodyInput = (e: InputEvent) => {
    const val = (e.target as HTMLTextAreaElement).value;
    editor.update(() => {
      const node = $getNodeByKey(props.decorator.nodeKey);
      if ($isErrorNode(node)) node.setBody(val);
    });
  };

  const title = () => props.decorator.label || "error";
  const meta = () => props.decorator.stage;

  return (
    <section class="thread-component thread-transcript-block" data-status="error">
      <div class="thread-transcript-heading">
        <span class="thread-transcript-label">{title()}</span>
        <span class="thread-transcript-status">{props.decorator.status}</span>
      </div>
      <Show when={meta()}>
        <div class="thread-transcript-meta">{meta()}</div>
      </Show>
      <textarea
        ref={bodyRef}
        use:autoResize
        class="edit-body-textarea error-body"
        onInput={handleBodyInput}
        spellcheck={false}
        value={props.decorator.body}
      />
    </section>
  );
}

function SourceView(props: { decorator: SourceDecorator }) {
  const editor = useLexicalEditor();
  let bodyRef: HTMLTextAreaElement | undefined;

  const handleBodyInput = (e: InputEvent) => {
    const val = (e.target as HTMLTextAreaElement).value;
    editor.update(() => {
      const node = $getNodeByKey(props.decorator.nodeKey);
      if ($isSourceNode(node)) node.setBody(val);
    });
  };

  const title = () => props.decorator.label || "source";

  return (
    <section class="thread-component thread-transcript-block" data-status={props.decorator.status}>
      <div class="thread-transcript-heading">
        <span class="thread-transcript-label">{title()}</span>
        <span class="thread-transcript-status">{props.decorator.status}</span>
      </div>
      <textarea
        ref={bodyRef}
        use:autoResize
        class="edit-body-textarea source-body"
        onInput={handleBodyInput}
        spellcheck={false}
        value={props.decorator.body}
      />
    </section>
  );
}
