import * as stylex from "@stylexjs/stylex";
import { For, onCleanup } from "solid-js";
import { describeError, showSystemToast } from "../ui/toast";
import type { ThreadSession } from "./session";
import { threadStyles } from "./thread.stylex";
import type { SourceSlice } from "./types";

export function SourceTags(props: { session: ThreadSession; block: string; sources: SourceSlice[] }) {
  const region = stylex.attrs(threadStyles.sourceRegion), tags = stylex.attrs(threadStyles.sourceTags), tag = stylex.attrs(threadStyles.sourceTag);
  const visible = () => {
    const payload = props.session.payloads().get(props.block); if (!payload) return [];
    return props.sources.flatMap((source, index) => { const bytes = payload.alternatives?.get(index); return bytes && sameBytes(bytes, payload.bytes) ? [] : [{ source, index, bytes }]; });
  };
  onCleanup(() => props.session.preview(props.block, null));
  function clear() { props.session.preview(props.block, null); }
  async function resolve(index: number) {
    try { const bytes = await props.session.resolveSource(props.block, index), payload = props.session.payloads().get(props.block); if (payload && !sameBytes(bytes, payload.bytes)) props.session.preview(props.block, bytes); }
    catch (error) { showSystemToast({ title: "Source load failed", detail: describeError(error) }); }
  }
  async function apply(index: number, known?: Uint8Array) {
    try { const bytes = known ?? await props.session.resolveSource(props.block, index), payload = props.session.payloads().get(props.block); if (!payload || sameBytes(bytes, payload.bytes)) return; await props.session.applySource(props.block, index, bytes); }
    catch (error) { showSystemToast({ title: "Source application failed", detail: describeError(error) }); }
  }
  return <div class={`${region.class ?? ""} source-region`} style={region.style} onPointerLeave={clear}>
    <div class={`${tags.class ?? ""} source-tags`} style={tags.style}><For each={visible()}>{(item) => <button class={`${tag.class ?? ""} source-tag`} style={tag.style} type="button" title={label(item.source, false)} disabled={props.session.locked()} onPointerEnter={() => void resolve(item.index)} onFocus={() => void resolve(item.index)} onBlur={clear} onClick={() => void apply(item.index, item.bytes)}>{label(item.source, true)}</button>}</For></div>
  </div>;
}
function sameBytes(left: Uint8Array, right: Uint8Array) { return left.byteLength === right.byteLength && left.every((value, index) => value === right[index]); }
function label(source: SourceSlice, short: boolean) { const packet = short && source.packet.length > 12 ? `${source.packet.slice(0, 9)}…` : source.packet; return `${packet}${source.from === undefined && source.to === undefined ? "" : ` ${source.from ?? 0}–${source.to ?? "end"}`}`; }
