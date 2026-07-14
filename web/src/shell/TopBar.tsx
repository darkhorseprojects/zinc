import arrowsCounterClockwiseSvg from "@phosphor-icons/core/assets/regular/arrows-counter-clockwise.svg?raw";
import databaseSvg from "@phosphor-icons/core/assets/duotone/database-duotone.svg?raw";
import plusSvg from "@phosphor-icons/core/assets/duotone/plus-duotone.svg?raw";
import { animate, utils, type JSAnimation } from "animejs";
import { createEffect, createSignal, onCleanup, Show } from "solid-js";
import type { StoreRef, ThreadManifest, ThreadSummary } from "../thread/types";
import { IconButton } from "../ui/Chrome";
import { Icon } from "./Icon";
import { NavSelect, type NavOption } from "./NavSelect";

export function TopBar(props: { stores: StoreRef[]; store: StoreRef | null; threads: ThreadSummary[]; thread: ThreadManifest | null; identifier: string; dirty: boolean; saving: boolean; canNew: boolean; onStore(path: string): void; onThread(id: string): void; onIdentifier(value: string): void; onNew(): void }) {
  const [editing, setEditing] = createSignal(false); let input!: HTMLInputElement, spinner!: HTMLSpanElement, spin: JSAnimation | null = null, fade: JSAnimation | null = null;
  createEffect(() => { const active = props.dirty || props.saving; fade?.cancel(); if (!spinner) return; if (active) { if (!spin) spin = animate(spinner, { rotate: "-1turn", duration: 850, loop: true, ease: "linear" }); fade = animate(spinner, { opacity: 1, duration: 120, ease: "outQuad" }); } else fade = animate(spinner, { opacity: 0, duration: 120, ease: "outQuad", onComplete: () => { spin?.cancel(); spin = null; utils.set(spinner, { rotate: 0 }); } }); });
  onCleanup(() => { spin?.cancel(); fade?.cancel(); });
  const stores = (): NavOption[] => props.stores.map((store) => ({ value: store.path, label: store.name || store.path }));
  const threads = (): NavOption[] => props.threads.map((thread) => ({ value: thread.id, label: thread.id, identifier: thread.identifier }));
  function beginEdit() { if (!props.thread) return; setEditing(true); queueMicrotask(() => { input.value = props.identifier; input.focus(); input.select(); }); }
  function finish(save: boolean) { if (!editing()) return; if (save) props.onIdentifier(input.value); setEditing(false); }
  return <header class="top-zone"><div class="breadcrumb-row"><NavSelect options={stores()} value={props.store?.path ?? null} onChange={(value) => value && props.onStore(value)} placeholder="store" leadingIcon={databaseSvg} /><Show when={props.store}><span class="breadcrumb-sep">/</span><Show when={editing()} fallback={<div onDblClick={beginEdit}><NavSelect options={threads()} value={props.thread?.id ?? null} onChange={(value) => value && props.onThread(value)} placeholder="thread" /></div>}><input ref={input} class="identifier-input" aria-label="Thread identifier" onBlur={() => finish(true)} onKeyDown={(event) => { if (event.key === "Enter") finish(true); else if (event.key === "Escape") finish(false); }} /></Show></Show></div><div class="top-controls"><Show when={props.thread}><span ref={spinner} class="save-spinner"><Icon svg={arrowsCounterClockwiseSvg} size={16} /></span></Show><Show when={props.store}><IconButton class="nav-square-button" size="md" type="button" title="New thread" disabled={!props.canNew} onClick={props.onNew}><Icon svg={plusSvg} size={18} /></IconButton></Show></div></header>;
}
