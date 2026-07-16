import * as stylex from "@stylexjs/stylex";
import arrowsCounterClockwiseSvg from "@phosphor-icons/core/assets/regular/arrows-counter-clockwise.svg";
import databaseSvg from "@phosphor-icons/core/assets/duotone/database-duotone.svg";
import plusSvg from "@phosphor-icons/core/assets/duotone/plus-duotone.svg";
import { animate, utils, type JSAnimation } from "animejs";
import { createEffect, onCleanup, Show } from "solid-js";
import { duration, ease, motion } from "../styles/motion";
import type { StoreRef, ThreadManifest, ThreadSummary } from "../thread/types";
import { IconButton } from "../ui/IconButton";
import { Icon } from "./Icon";
import { NavSelect, type NavOption } from "./NavSelect";
import { ThreadIdentity } from "./ThreadIdentity";
import { shellStyles } from "./shell.stylex";

type SaveStatus = "clean" | "dirty" | "saving";
export function TopBar(props: { stores: StoreRef[]; store: StoreRef | null; threads: ThreadSummary[]; thread: ThreadManifest | null; identifier: string; status: SaveStatus; canNew: boolean; onStore(path: string): void; onThread(id: string): void; onIdentifier(value: string): void; onNew(): void }) {
  let spinner!: HTMLSpanElement, spin: JSAnimation | null = null, fade: JSAnimation | null = null;
  createEffect(() => {
    const status = props.status, active = status === "dirty" || status === "saving"; fade?.cancel(); if (!spinner) return;
    if (active && !spin) spin = animate(spinner, { rotate: "-1turn", duration: duration(motion.spinner), loop: true, ease: ease.linear });
    if (!active && spin) { spin.cancel(); spin = null; utils.set(spinner, { rotate: 0 }); }
    fade = animate(spinner, { opacity: status === "clean" ? 0 : 1, duration: duration(motion.reveal), ease: ease.standard });
  });
  onCleanup(() => { spin?.cancel(); fade?.cancel(); });
  const stores = (): NavOption[] => props.stores.map((store) => ({ value: store.path, label: store.name || store.path }));
  const top = stylex.attrs(shellStyles.top), breadcrumb = stylex.attrs(shellStyles.breadcrumb), controls = stylex.attrs(shellStyles.controls);
  return <header class={`${top.class ?? ""} top-zone`} style={top.style}>
    <div class={`${breadcrumb.class ?? ""} breadcrumb-row`} style={breadcrumb.style}>
      <NavSelect options={stores()} value={props.store?.path ?? null} onChange={(value) => value && props.onStore(value)} placeholder="store" leadingIcon={databaseSvg} />
      <Show when={props.store}><span class="breadcrumb-sep">/</span><ThreadIdentity thread={props.thread} threads={props.threads} identifier={props.identifier} onThread={props.onThread} onIdentifier={props.onIdentifier} /></Show>
    </div>
    <div class={`${controls.class ?? ""} top-controls`} style={controls.style}>
      <Show when={props.thread}><span ref={spinner} class="save-spinner" data-status={props.status} title={props.status}><Icon svg={arrowsCounterClockwiseSvg} size={16} /></span></Show>
      <Show when={props.store}><IconButton class="nav-square-button" size="md" raised type="button" title="New thread" disabled={!props.canNew} onClick={props.onNew}><Icon svg={plusSvg} size={18} /></IconButton></Show>
    </div>
  </header>;
}
