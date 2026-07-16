import { createWindowVirtualizer, defaultRangeExtractor } from "@tanstack/solid-virtual";
import { animate, utils, type JSAnimation } from "animejs";
import { createEffect, createSignal, For, onCleanup, onMount, Show } from "solid-js";
import type { ZincClient } from "../client";
import { Output } from "../completion/Output";
import { duration, ease, motion } from "../styles/motion";
import type { ThreadSession } from "./session";
import { ThreadBlockRow } from "./ThreadBlockRow";
import { ThreadGutter } from "./ThreadGutter";

type DragState = { source: string; target: string; height: number; rows: Array<{ id: string; top: number; bottom: number }> };

export function ThreadView(props: { client: ZincClient; session: ThreadSession; onThread(id: string): void; onFork(id: string): void }) {
  let canvas!: HTMLDivElement, dragAnimation: JSAnimation | null = null; const [scrollMargin, setScrollMargin] = createSignal(0), [ready, setReady] = createSignal(false), [active, setActive] = createSignal<string | null>(null), [drag, setDrag] = createSignal<DragState | null>(null);
  const shifted = new Set<HTMLElement>();
  const virtualizer = createWindowVirtualizer<HTMLDivElement>({
    get count() { return props.session.blocks().length; },
    estimateSize: () => 96,
    overscan: 6,
    getItemKey: (index) => props.session.blocks()[index]?.id ?? index,
    get scrollMargin() { return scrollMargin(); },
    rangeExtractor: (range) => {
      const indexes = new Set(defaultRangeExtractor(range)), pinned = props.session.pinned(), blocks = props.session.blocks(), moving = drag();
      blocks.forEach((block, index) => { if (pinned.has(block.id)) indexes.add(index); });
      if (moving) { const from = blocks.findIndex((block) => block.id === moving.source), to = blocks.findIndex((block) => block.id === moving.target); for (let index = Math.min(from, to); index <= Math.max(from, to); index++) if (index >= 0) indexes.add(index); }
      return [...indexes].sort((a, b) => a - b);
    },
  });
  onMount(() => {
    setReady(true);
    const measure = () => setScrollMargin(canvas.getBoundingClientRect().top + window.scrollY); measure(); window.addEventListener("resize", measure);
    onCleanup(() => { window.removeEventListener("resize", measure); dragAnimation?.cancel(); });
  });
  createEffect(() => { const values = virtualizer.getVirtualItems(), blocks = props.session.blocks(), ids = values.flatMap((item) => blocks[item.index] ? [blocks[item.index].id] : []); props.session.retain(ids); props.session.request(ids); });

  function beginDrag(event: PointerEvent, source: string) {
    if (props.session.locked()) return;
    const control = event.currentTarget as HTMLElement, row = canvas.querySelector<HTMLElement>(`[data-row-id="${CSS.escape(source)}"]`); if (!row) return;
    const startX = event.clientX, startY = event.clientY, rows = [...canvas.querySelectorAll<HTMLElement>("[data-row-id]")].map((element) => { const rect = element.getBoundingClientRect(); return { id: element.dataset.rowId!, top: rect.top, bottom: rect.bottom }; }).sort((left, right) => left.top - right.top);
    let started = false; control.setPointerCapture(event.pointerId); setActive(source);
    const move = (pointer: PointerEvent) => {
      if (!started && Math.hypot(pointer.clientX - startX, pointer.clientY - startY) < 4) return;
      if (!started) { started = true; pointer.preventDefault(); setDrag({ source, target: source, height: row.getBoundingClientRect().height, rows }); }
      const moving = drag(); if (!moving) return;
      const target = moving.rows.find((entry) => pointer.clientY < (entry.top + entry.bottom) / 2)?.id ?? moving.rows.at(-1)?.id;
      if (!target || target === moving.target) return;
      setDrag({ ...moving, target }); queueMicrotask(applyDragOffsets);
    };
    const finish = (commit: boolean) => {
      control.removeEventListener("pointermove", move); control.removeEventListener("pointerup", up); control.removeEventListener("pointercancel", cancel); if (control.hasPointerCapture(event.pointerId)) control.releasePointerCapture(event.pointerId);
      const moving = drag();
      if (commit && moving && moving.source !== moving.target) {
        const order = props.session.blocks().map((block) => block.id), from = order.indexOf(moving.source), to = order.indexOf(moving.target);
        if (from >= 0 && to >= 0) { order.splice(from, 1); order.splice(to, 0, moving.source); props.session.reorder(order); queueMicrotask(() => clearOffsets(false)); } else clearOffsets(true);
      } else clearOffsets(true);
      setDrag(null);
    };
    const up = () => finish(started), cancel = () => finish(false);
    control.addEventListener("pointermove", move); control.addEventListener("pointerup", up, { once: true }); control.addEventListener("pointercancel", cancel, { once: true });
  }

  function applyDragOffsets() {
    const moving = drag(); if (!moving) return;
    const blocks = props.session.blocks(), from = blocks.findIndex((block) => block.id === moving.source), to = blocks.findIndex((block) => block.id === moving.target);
    if (from < 0 || to < 0) return;
    const sourceRow = canvas.querySelector<HTMLElement>(`[data-row-id="${CSS.escape(moving.source)}"]`), targetRow = canvas.querySelector<HTMLElement>(`[data-row-id="${CSS.escape(moving.target)}"]`); if (!sourceRow || !targetRow) return;
    const sourceRect = sourceRow.getBoundingClientRect(), targetRect = targetRow.getBoundingClientRect(), desired = new Map<HTMLElement, number>();
    for (let index = Math.min(from, to); index <= Math.max(from, to); index++) {
      const block = blocks[index], row = block && canvas.querySelector<HTMLElement>(`[data-row-id="${CSS.escape(block.id)}"]`), article = row?.querySelector<HTMLElement>(".thread-block-row"); if (!article) continue;
      desired.set(article, index === from ? (to > from ? targetRect.bottom - sourceRect.bottom : targetRect.top - sourceRect.top) : to > from ? -moving.height : moving.height);
    }
    dragAnimation?.cancel(); const targets = new Set([...shifted, ...desired.keys()]); shifted.clear(); desired.forEach((_offset, element) => shifted.add(element));
    dragAnimation = animate([...targets], { translateY: ((element: HTMLElement) => desired.get(element) ?? 0) as any, duration: duration(motion.reorder), ease: ease.spatial });
  }
  function clearOffsets(animated: boolean) {
    dragAnimation?.cancel(); const elements = [...shifted]; shifted.clear();
    if (animated) dragAnimation = animate(elements, { translateY: 0, duration: duration(motion.normal), ease: ease.spatial });
    else utils.set(elements, { translateY: 0 });
  }

  return <div class="thread-view" data-dragging={drag() ? "true" : undefined} onPointerLeave={(event) => { if (!drag() && !(event.relatedTarget instanceof Element && event.relatedTarget.closest(".thread-gutter"))) setActive(null); }}>
    <div ref={canvas} class="thread-virtual-canvas" style={{ height: `${virtualizer.getTotalSize()}px` }}>
      <For each={virtualizer.getVirtualItems()}>{(item) => { const block = () => props.session.blocks()[item.index], previous = () => props.session.blocks()[item.index - 1]; return <div ref={(element) => { element.dataset.index = String(item.index); virtualizer.measureElement(element); }} data-row-id={block().id} class="thread-virtual-row" style={{ transform: `translateY(${item.start - scrollMargin()}px)` }}><ThreadBlockRow client={props.client} session={props.session} block={block()} divider={Boolean(previous() && side(previous()!.role) !== side(block().role))} onThread={props.onThread} onActive={setActive} /></div>; }}</For>
      <Show when={ready()}><ThreadGutter canvas={canvas} session={props.session} active={active()} onFork={props.onFork} onDrag={beginDrag} /></Show>
    </div>
    <Output reasoning={props.session.output().reasoning} response={props.session.output().response} active={props.session.output().active} />
    <div class="thread-end-anchor" aria-hidden="true" />
  </div>;
}
function side(role: "user" | "agent" | "system") { return role === "user" ? "user" : "other"; }
