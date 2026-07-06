import { Match, Show, Switch } from "solid-js";
import type { MdxSourceDecorator, ThreadComponentDecorator, TranscriptBlockDecorator } from "~/thread/nodes";

export type ZincDecorator = ThreadComponentDecorator | MdxSourceDecorator;

export function ZincDecoratorView(props: { decorator: ZincDecorator }) {
  return (
    <Switch>
      <Match when={props.decorator.kind === "Reasoning" ? props.decorator : null}>
        {(decorator) => <Reasoning text={decorator().text} />}
      </Match>
      <Match when={props.decorator.kind === "TranscriptBlock" ? props.decorator : null}>
        {(decorator) => <TranscriptBlock block={decorator()} />}
      </Match>
      <Match when={props.decorator.kind === "MdxSource" ? props.decorator : null}>
        {(decorator) => <section class="thread-component thread-mdx-fragment"><pre>{decorator().source}</pre></section>}
      </Match>
    </Switch>
  );
}

function Reasoning(props: { text: string }) {
  return <section class="thread-component thread-reasoning">{props.text}</section>;
}

function TranscriptBlock(props: { block: TranscriptBlockDecorator }) {
  const block = () => props.block;
  const title = () => block().label || block().blockKind;
  const meta = () => [block().stage, block().command, block().exit !== null ? `exit ${block().exit}` : ""].filter(Boolean).join(" · ");

  return (
    <section class="thread-component thread-transcript-block" data-kind={block().blockKind} data-status={block().status}>
      <div class="thread-transcript-heading">
        <span class="thread-transcript-label">{title()}</span>
        <span class="thread-transcript-status">{block().status}</span>
      </div>
      <Show when={meta()}>
        <div class="thread-transcript-meta">{meta()}</div>
      </Show>
      <pre class="thread-transcript-body">{block().body || (block().status === "pending" ? "running…" : "")}</pre>
    </section>
  );
}
