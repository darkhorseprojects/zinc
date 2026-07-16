import { Show } from "solid-js";
import type { ZincClient } from "../client";
import { BlockEditor } from "../editor/BlockEditor";
import { BlockForks } from "./BlockForks";
import type { ThreadSession } from "./session";
import { SourceTags } from "./SourceTags";
import type { BlockDescriptor } from "./types";

export function ThreadBlockRow(props: { client: ZincClient; session: ThreadSession; block: BlockDescriptor; divider: boolean; onThread(id: string): void; onActive(id: string): void }) {
  const payload = () => props.session.payloads().get(props.block.id);
  const activate = () => props.onActive(props.block.id);
  return <article class="thread-block-row" data-block-id={props.block.id} data-role={props.block.role} onPointerEnter={activate} onFocusIn={activate}>
    <Show when={props.divider}><div class="thread-role-divider" aria-hidden="true" /></Show>
    <div class="thread-block-body" data-gutter-anchor>
      <BlockForks client={props.client} session={props.session} block={props.block.id} onThread={props.onThread} onPreview={(bytes) => props.session.preview(props.block.id, bytes)} />
      <Show when={payload()} fallback={<Show when={props.session.loadErrors().has(props.block.id)} fallback={<div class="block-loading" aria-label="Loading block"><span /><span /></div>}><RetryButton onClick={() => props.session.request([props.block.id], true)} /></Show>}>
        <div class="block-content">
          <BlockEditor id={props.block.id} bytes={payload()!.bytes} editable={!props.session.locked()} bind={(handle) => props.session.bind(props.block.id, handle)} onFocusChange={(focused) => props.session.setFocus(props.block.id, focused)} onChange={(bytes) => props.session.mark(props.block.id, bytes)} onSplit={(before, after) => props.session.split(props.block.id, before, after)} onMerge={(direction) => void props.session.merge(props.block.id, direction)} onNavigate={(direction) => props.session.navigate(props.block.id, direction)} />
        </div>
        <Show when={payload()!.sources.length}><SourceTags session={props.session} block={props.block.id} sources={payload()!.sources} /></Show>
      </Show>
    </div>
  </article>;
}
function RetryButton(props: { onClick(): void }) { return <button class="block-load-retry" type="button" onClick={props.onClick}>Retry block</button>; }
