import { createWindowVirtualizer, defaultRangeExtractor } from "@tanstack/solid-virtual";
import { createEffect, createSignal, For, onCleanup, onMount } from "solid-js";
import type { ZincClient } from "../client";
import { Output } from "../completion/Output";
import type { ThreadSession } from "./session";
import { ThreadBlockRow } from "./ThreadBlockRow";

export function ThreadView(props: { client: ZincClient; session: ThreadSession; onThread(id: string): void; onFork(id: string): void }) {
  let canvas!: HTMLDivElement; const [scrollMargin, setScrollMargin] = createSignal(0);
  const virtualizer = createWindowVirtualizer<HTMLDivElement>({
    get count() { return props.session.blocks().length; },
    estimateSize: () => 96,
    overscan: 6,
    getItemKey: (index) => props.session.blocks()[index]?.id ?? index,
    get scrollMargin() { return scrollMargin(); },
    rangeExtractor: (range) => { const indexes = new Set(defaultRangeExtractor(range)), pinned = props.session.pinned(), blocks = props.session.blocks(); blocks.forEach((block, index) => { if (pinned.has(block.id)) indexes.add(index); }); return [...indexes].sort((a, b) => a - b); },
  });
  onMount(() => { const measure = () => setScrollMargin(canvas.getBoundingClientRect().top + window.scrollY); measure(); window.addEventListener("resize", measure); onCleanup(() => window.removeEventListener("resize", measure)); });
  createEffect(() => { const values = virtualizer.getVirtualItems(), blocks = props.session.blocks(); props.session.request(values.flatMap((item) => blocks[item.index] ? [blocks[item.index].id] : [])); });
  return <div class="thread-view">
    <div ref={canvas} class="thread-virtual-canvas" style={{ height: `${virtualizer.getTotalSize()}px` }}>
      <For each={virtualizer.getVirtualItems()}>{(item) => { const block = () => props.session.blocks()[item.index], previous = () => props.session.blocks()[item.index - 1]; return <div data-index={item.index} ref={(element) => virtualizer.measureElement(element)} class="thread-virtual-row" style={{ transform: `translateY(${item.start - scrollMargin()}px)` }}><ThreadBlockRow client={props.client} session={props.session} block={block()} divider={Boolean(previous() && side(previous()!.role) !== side(block().role))} onThread={props.onThread} onFork={props.onFork} /></div>; }}</For>
    </div>
    <Output reasoning={props.session.output().reasoning} response={props.session.output().response} active={props.session.output().active} />
    <div class="thread-end-anchor" aria-hidden="true" />
  </div>;
}
function side(role: "user" | "agent" | "system") { return role === "user" ? "user" : "other"; }
