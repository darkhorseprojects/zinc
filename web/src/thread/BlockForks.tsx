import gitForkSvg from "@phosphor-icons/core/assets/regular/git-fork.svg";
import * as stylex from "@stylexjs/stylex";
import { For, onCleanup } from "solid-js";
import type { ZincClient } from "../client";
import { Icon } from "../shell/Icon";
import { IconButton } from "../ui/IconButton";
import { parseIdentifier, tagColor } from "./identifier";
import type { ThreadSession } from "./session";
import { threadStyles } from "./thread.stylex";

export function BlockForks(props: { client: ZincClient; session: ThreadSession; block: string; onThread(id: string): void; onPreview(bytes: Uint8Array | null): void }) {
  let previewRequest = 0; const forks = stylex.attrs(threadStyles.forks);
  onCleanup(() => { previewRequest++; props.onPreview(null); });
  const members = () => {
    const seen = new Set<string>();
    return props.session.manifest().forkPoints.filter((point) => point.block === props.block).flatMap((point) => point.members).filter((member) => member.id !== props.session.id && !seen.has(member.id) && seen.add(member.id));
  };
  async function preview(thread: string) {
    const token = ++previewRequest;
    try {
      const manifest = await props.client.manifest(props.session.store, thread), anchor = manifest.blocks.findIndex((block) => block.id === props.block);
      if (anchor < 0) return clear();
      const descriptors = manifest.blocks.slice(anchor, anchor + 4), payloads = await props.client.readBlocks(props.session.store, thread, manifest.revision, descriptors.map((block) => block.id));
      if (token !== previewRequest) return;
      const current = props.session.payloads().get(props.block)?.bytes, alternative = payloads.find((payload) => !current || !sameBytes(payload.bytes, current));
      props.onPreview(alternative?.bytes ?? null);
    } catch { if (token === previewRequest) props.onPreview(null); }
  }
  function clear() { previewRequest++; props.onPreview(null); }
  return <div class={`${forks.class ?? ""} block-forks`} style={forks.style} onPointerLeave={clear}>
    <For each={members()}>{(member) => { const identity = parseIdentifier(member.identifier), color = tagColor(identity.tags[0] ?? member.id); return <IconButton type="button" class="gutter-button gutter-fork" data-color={color} title={identity.title || member.title} onPointerEnter={() => void preview(member.id)} onFocus={() => void preview(member.id)} onBlur={clear} onClick={() => props.onThread(member.id)}><Icon svg={gitForkSvg} size={14} /></IconButton>; }}</For>
  </div>;
}
function sameBytes(left: Uint8Array, right: Uint8Array) { return left.byteLength === right.byteLength && left.every((value, index) => value === right[index]); }
