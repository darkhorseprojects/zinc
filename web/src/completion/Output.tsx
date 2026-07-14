import circleDashedSvg from "@phosphor-icons/core/assets/regular/circle-dashed.svg?raw";
import { animate, type JSAnimation } from "animejs";
import { createEffect, onCleanup, Show } from "solid-js";
import { BlockEditor, type BlockEditorHandle } from "../editor/BlockEditor";
import { textPacket } from "../editor/codec";
import { Icon } from "../shell/Icon";

export function Output(props: { reasoning: string; response: string; active: boolean }) {
  let cursor!: HTMLSpanElement; let animation: JSAnimation | null = null;
  createEffect(() => { if (!props.active) { animation?.cancel(); animation = null; return; } if (!animation && cursor) animation = animate(cursor, { rotate: "1turn", duration: 1200, loop: true, ease: "linear" }); }); onCleanup(() => animation?.cancel());
  return <Show when={props.active || props.reasoning || props.response}><div class="continuation-output" aria-live="polite" aria-atomic="false">
    <Show when={props.reasoning}><Transient id="reasoning" format="reasoning" text={props.reasoning} /></Show>
    <Show when={props.response}><Transient id="response" format="markdown" text={props.response} /></Show>
    <Show when={props.active}><span ref={cursor} class="continuation-cursor" aria-hidden="true"><Icon svg={circleDashedSvg} size={14} /></span></Show>
  </div></Show>;
}
function Transient(props: { id: string; format: string; text: string }) { let handle: BlockEditorHandle | null = null; createEffect(() => handle?.replace(textPacket(props.format, props.text))); return <BlockEditor id={`transient-${props.id}`} bytes={textPacket(props.format, props.text)} editable={false} bind={(value) => { handle = value; }} />; }
