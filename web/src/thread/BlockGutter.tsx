import dotsSixVerticalSvg from "@phosphor-icons/core/assets/regular/dots-six-vertical.svg?raw";
import gitForkSvg from "@phosphor-icons/core/assets/regular/git-fork.svg?raw";
import plusSvg from "@phosphor-icons/core/assets/regular/plus.svg?raw";
import { For } from "solid-js";
import { Icon } from "../shell/Icon";
import { IconButton } from "../ui/Chrome";
import { parseIdentifier, tagColor } from "./identifier";
import type { ThreadSession } from "./session";

export function BlockGutter(props: { session: ThreadSession; block: string; onThread(id: string): void; onFork(id: string): void }) {
  const members = () => {
    const seen = new Set<string>(); return props.session.manifest().forkPoints.filter((point) => point.block === props.block).flatMap((point) => point.members).filter((member) => member.id !== props.session.id && !seen.has(member.id) && seen.add(member.id));
  };
  async function createFork() { const created = await props.session.fork(props.block); props.onFork(created.id); }
  function drag(event: PointerEvent) {
    event.preventDefault(); const start = props.session.blocks().findIndex((block) => block.id === props.block); if (start < 0) return;
    const move = (pointer: PointerEvent) => { const target = document.elementFromPoint(pointer.clientX, pointer.clientY)?.closest<HTMLElement>("[data-block-id]")?.dataset.blockId; if (!target || target === props.block) return; const order = props.session.blocks().map((block) => block.id), from = order.indexOf(props.block), to = order.indexOf(target); if (from < 0 || to < 0) return; order.splice(from, 1); order.splice(to, 0, props.block); props.session.reorder(order); };
    const end = () => { document.removeEventListener("pointermove", move); document.removeEventListener("pointerup", end); document.removeEventListener("pointercancel", end); };
    document.addEventListener("pointermove", move); document.addEventListener("pointerup", end, { once: true }); document.addEventListener("pointercancel", end, { once: true });
  }
  return <div class="block-gutter" aria-label="Block controls">
    <IconButton type="button" class="gutter-button gutter-new-fork" title="Fork from here" onClick={() => void createFork()}><Icon svg={plusSvg} size={13} /></IconButton>
    <For each={members()}>{(member) => { const identity = parseIdentifier(member.identifier), color = tagColor(identity.tags[0] ?? member.id); return <IconButton type="button" class="gutter-button gutter-fork" data-color={color} title={identity.title || member.id} onClick={() => props.onThread(member.id)}><Icon svg={gitForkSvg} size={14} /></IconButton>; }}</For>
    <IconButton type="button" class="gutter-button gutter-handle" title="Move block" onPointerDown={drag}><Icon svg={dotsSixVerticalSvg} size={15} /></IconButton>
    <span class="gutter-rule" aria-hidden="true" />
  </div>;
}
