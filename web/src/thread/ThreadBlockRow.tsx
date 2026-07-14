import { Show } from "solid-js";
import type { ZincClient } from "../client";
import { BlockEditor } from "../editor/BlockEditor";
import { SourceTags } from "./AlternativePreview";
import { BlockGutter } from "./BlockGutter";
import type { ThreadSession } from "./session";
import type { BlockDescriptor } from "./types";

export function ThreadBlockRow(props: { client: ZincClient; session: ThreadSession; block: BlockDescriptor; divider: boolean; onThread(id: string): void; onFork(id: string): void }) {
  const payload = () => props.session.payloads().get(props.block.id);
  return <article class="thread-block-row" data-block-id={props.block.id} data-role={props.block.role} data-divider={props.divider || undefined}>
    <BlockGutter session={props.session} block={props.block.id} onThread={props.onThread} onFork={props.onFork} />
    <Show when={payload()} fallback={<div class="block-loading" aria-label="Loading block"><span /><span /></div>} keyed>{(value) => <>
      <BlockEditor id={props.block.id} bytes={value.bytes} editable={!props.session.output().active && !props.session.conflicted()} bind={(handle) => props.session.bind(props.block.id, handle)} onFocusChange={(focused) => props.session.setFocus(props.block.id, focused)} onChange={(bytes) => props.session.mark(props.block.id, bytes)} onSplit={(before, after) => props.session.split(props.block.id, before, after)} onMerge={(direction) => props.session.merge(props.block.id, direction)} onNavigate={(direction) => props.session.navigate(props.block.id, direction)} />
      <Show when={value.sources.length}><SourceTags client={props.client} session={props.session} block={props.block.id} sources={value.sources} /></Show>
    </>}</Show>
  </article>;
}
