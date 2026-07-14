import { diffWordsWithSpace } from "diff";
import { animate, type JSAnimation } from "animejs";
import { createSignal, For, onCleanup, Show } from "solid-js";
import type { ZincClient } from "../client";
import { decodeBlock, encodeBlock } from "../editor/codec";
import type { ThreadSession } from "./session";
import type { SourceSlice } from "./types";

export function SourceTags(props: { client: ZincClient; session: ThreadSession; block: string; sources: SourceSlice[] }) {
  const [preview, setPreview] = createSignal<{ current: string; source: string } | null>(null); let request = 0, overlay!: HTMLPreElement, animation: JSAnimation | null = null;
  onCleanup(() => { request++; animation?.cancel(); });
  async function show(source: SourceSlice) {
    const token = ++request, currentBytes = props.session.dirty().get(props.block)?.bytes ?? props.session.payloads().get(props.block)?.bytes; if (!currentBytes) return;
    const bytes = await props.client.readSource(props.session.store, source); if (token !== request) return;
    setPreview({ current: plain(currentBytes), source: plain(bytes) }); queueMicrotask(() => { animation?.cancel(); if (overlay) animation = animate(overlay, { opacity: [0, 1], translateY: [4, 0], duration: 160, ease: "outQuad" }); });
  }
  function clear() { request++; animation?.cancel(); setPreview(null); }
  return <div class="source-region" onPointerLeave={clear}>
    <div class="source-tags"><For each={props.sources}>{(source, index) => <button class="source-tag" type="button" title={label(source, false)} onPointerEnter={() => void show(source)} onFocus={() => void show(source)} onClick={() => void props.session.applySource(props.block, index())}>{label(source, true)}</button>}</For></div>
    <Show when={preview()} keyed>{(value) => <pre ref={overlay} class="alternative-preview" aria-label="Source difference"><For each={diffWordsWithSpace(value.current, value.source)}>{(change) => <span class={change.added ? "diff-added" : change.removed ? "diff-removed" : "diff-same"}>{change.value}</span>}</For></pre>}</Show>
  </div>;
}
function plain(bytes: Uint8Array) { try { const decoded = decodeBlock(bytes); const packet = JSON.parse(new TextDecoder().decode(encodeBlock(decoded.format, decoded.document))); return typeof packet.text === "string" ? packet.text : JSON.stringify(packet, null, 2); } catch { return new TextDecoder().decode(bytes); } }
function label(source: SourceSlice, short: boolean) { const packet = short && source.packet.length > 12 ? `${source.packet.slice(0, 9)}…` : source.packet; return `${packet}${source.from === undefined && source.to === undefined ? "" : ` ${source.from ?? 0}–${source.to ?? "end"}`}`; }
