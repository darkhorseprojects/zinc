import dotsSixVerticalSvg from "@phosphor-icons/core/assets/regular/dots-six-vertical.svg";
import plusSvg from "@phosphor-icons/core/assets/regular/plus.svg";
import * as stylex from "@stylexjs/stylex";
import { animate, utils, type JSAnimation } from "animejs";
import { createEffect, onCleanup } from "solid-js";
import { Icon } from "../shell/Icon";
import { duration, ease, motion } from "../styles/motion";
import { IconButton } from "../ui/IconButton";
import { describeError, showSystemToast } from "../ui/toast";
import type { ThreadSession } from "./session";
import { threadStyles } from "./thread.stylex";

export function ThreadGutter(props: { canvas: HTMLElement; session: ThreadSession; active: string | null; onFork(id: string): void; onDrag(event: PointerEvent, block: string): void }) {
  let add!: HTMLButtonElement, handle!: HTMLButtonElement, movement: JSAnimation | null = null, reveal: JSAnimation | null = null;
  const gutter = stylex.attrs(threadStyles.gutter), addStyle = stylex.attrs(threadStyles.gutterButton, threadStyles.gutterNew), handleStyle = stylex.attrs(threadStyles.gutterButton, threadStyles.gutterHandle);
  createEffect(() => {
    const active = props.active; movement?.cancel(); reveal?.cancel();
    if (!active) { reveal = animate([add, handle], { opacity: 0, duration: duration(motion.fast), ease: ease.standard }); return; }
    const row = props.canvas.querySelector<HTMLElement>(`[data-block-id="${CSS.escape(active)}"]`); if (!row) return;
    const anchor = row.querySelector<HTMLElement>("[data-gutter-anchor]"); if (!anchor) return;
    const canvas = props.canvas.getBoundingClientRect(), rect = anchor.getBoundingClientRect(), top = rect.top - canvas.top + 3;
    const members = props.session.manifest().forkPoints.flatMap((point) => point.block === active ? point.members : []).filter((member) => member.id !== props.session.id);
    add.style.setProperty("--fork-offset", `${members.length * 28}px`);
    movement = animate([add, handle], { translateY: top, duration: duration(motion.normal), ease: ease.spatial });
    reveal = animate([add, handle], { opacity: 1, duration: duration(motion.reveal), ease: ease.standard });
  });
  onCleanup(() => { movement?.cancel(); reveal?.cancel(); });
  async function createFork() {
    const block = props.active; if (!block || props.session.locked()) return;
    try { const created = await props.session.fork(block); props.onFork(created.id); }
    catch (error) { showSystemToast({ title: "Fork failed", detail: describeError(error) }); }
  }
  return <div class={`${gutter.class ?? ""} thread-gutter`} style={gutter.style} aria-label="Block controls">
    <IconButton ref={add} class={`${addStyle.class ?? ""} gutter-button gutter-new-fork`} style={addStyle.style} type="button" title="Fork from here" disabled={props.session.locked() || !props.active} onClick={() => void createFork()}><Icon svg={plusSvg} size={13} /></IconButton>
    <IconButton ref={handle} class={`${handleStyle.class ?? ""} gutter-button gutter-handle`} style={handleStyle.style} type="button" title="Move block" disabled={props.session.locked() || !props.active} onPointerDown={(event) => props.active && props.onDrag(event, props.active)}><Icon svg={dotsSixVerticalSvg} size={15} /></IconButton>
  </div>;
}
